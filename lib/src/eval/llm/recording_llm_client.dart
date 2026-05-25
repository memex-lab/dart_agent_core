import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../../core/tool.dart';
import 'llm_request_hash.dart';
import 'rate_limit_gate.dart';
import 'recording_store.dart';

final _logger = Logger('RecordingLLMClient');

/// Wraps an inner [LLMClient] and records every successful
/// (request, response) pair into a [RecordingStore]. Reads still go
/// through the inner client; the store is a write target only.
///
/// If a [RateLimitGate] is provided, every real upstream call awaits
/// the gate first. This is the wiring point for RFC §6.15 (concurrency
/// vs rate-limit decoupling).
///
/// **Per-trial salt**: when [trialSalt] is non-null, every recorded
/// hash includes it. This preserves non-determinism across trials —
/// trial #0 and trial #1 of the same task receive different cache
/// keys, so the cache stores N different responses (one per trial)
/// instead of overwriting to one. Construct one client per trial via
/// [withTrialSalt] from inside [EvalEnvironment.prepare]. Leave it
/// null for one-off requests (judges, ad-hoc analysis) where caching
/// across trials is the desired behavior.
class RecordingLLMClient implements LLMClient {
  final LLMClient inner;
  final RecordingStore store;
  final LLMRequestHash hasher;
  final RateLimitGate rateLimitGate;
  final String? trialSalt;

  RecordingLLMClient({
    required this.inner,
    required this.store,
    LLMRequestHash? hasher,
    RateLimitGate? rateLimitGate,
    this.trialSalt,
  }) : hasher = hasher ?? const Sha256LLMRequestHash(),
       rateLimitGate = rateLimitGate ?? const NoopRateLimitGate();

  /// Returns a copy of this client bound to [salt]. Convenience for
  /// per-trial wrapping inside an environment's `prepare()`.
  RecordingLLMClient withTrialSalt(String salt) => RecordingLLMClient(
    inner: inner,
    store: store,
    hasher: hasher,
    rateLimitGate: rateLimitGate,
    trialSalt: salt,
  );

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    await rateLimitGate.acquire(estimatedTokens: modelConfig.maxTokens ?? 0);
    final response = await inner.generate(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
      cancelToken: cancelToken,
    );
    final hash = hasher.compute(
      messages: messages,
      tools: tools,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
      trialSalt: trialSalt,
    );
    try {
      await store.put(hash, response);
    } catch (e, st) {
      _logger.warning('failed to record response for $hash', e, st);
    }
    return response;
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    await rateLimitGate.acquire(estimatedTokens: modelConfig.maxTokens ?? 0);
    // NOTE: stream recording is deferred. Streamed runs that need
    // replay should use generate() in eval mode.
    return inner.stream(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
      cancelToken: cancelToken,
    );
  }
}
