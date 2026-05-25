import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../../core/tool.dart';
import 'llm_request_hash.dart';
import 'rate_limit_gate.dart';
import 'recording_store.dart';

final _logger = Logger('ReplayLLMClient');

/// Thrown when a [ReplayLLMClient] cannot find a recorded response and
/// has no fallback configured (or [strictReplay] is true).
class RecordingNotFoundException implements Exception {
  final String hash;
  final String? requestSummary;

  RecordingNotFoundException(this.hash, {this.requestSummary});

  @override
  String toString() =>
      'No recording for hash=$hash. '
      'Re-record with `--mode record` if the prompt or tools changed.'
      '${requestSummary == null ? '' : '\nRequest summary: $requestSummary'}';
}

/// Replays from a [RecordingStore]; falls back to an inner client (or
/// throws) on miss.
///
/// CI default: pass `strictReplay: true` and no `fallback` so any cache
/// miss fails the build, forcing re-recording.
///
/// When a [fallback] is configured, every fallback (real upstream) call
/// awaits the [RateLimitGate] first.
///
/// **Per-trial salt**: must match what was used during recording (see
/// [RecordingLLMClient.trialSalt]). Use [withTrialSalt] to clone this
/// client per trial inside [EvalEnvironment.prepare] so each trial
/// looks up its own cache entry instead of collapsing onto one shared
/// response.
class ReplayLLMClient implements LLMClient {
  final RecordingStore store;
  final LLMClient? fallback;
  final LLMRequestHash hasher;
  final RateLimitGate rateLimitGate;
  final String? trialSalt;

  /// If true, throw on miss instead of falling back.
  final bool strictReplay;

  ReplayLLMClient({
    required this.store,
    this.fallback,
    this.strictReplay = true,
    LLMRequestHash? hasher,
    RateLimitGate? rateLimitGate,
    this.trialSalt,
  }) : hasher = hasher ?? const Sha256LLMRequestHash(),
       rateLimitGate = rateLimitGate ?? const NoopRateLimitGate();

  /// Returns a copy of this client bound to [salt]. Convenience for
  /// per-trial wrapping inside an environment's `prepare()`.
  ReplayLLMClient withTrialSalt(String salt) => ReplayLLMClient(
    store: store,
    fallback: fallback,
    strictReplay: strictReplay,
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
    final hash = hasher.compute(
      messages: messages,
      tools: tools,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
      trialSalt: trialSalt,
    );
    final cached = await store.get(hash);
    if (cached != null) return cached;

    _logger.fine('replay cache miss: $hash');
    if (fallback != null && !strictReplay) {
      await rateLimitGate.acquire(estimatedTokens: modelConfig.maxTokens ?? 0);
      return fallback!.generate(
        messages,
        tools: tools,
        toolChoice: toolChoice,
        modelConfig: modelConfig,
        jsonOutput: jsonOutput,
        cancelToken: cancelToken,
      );
    }
    throw RecordingNotFoundException(hash);
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
    // For replay we synthesize a one-chunk stream from the recorded message.
    final response = await generate(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
      cancelToken: cancelToken,
    );
    return Stream<StreamingMessage>.fromIterable([
      StreamingMessage(modelMessage: response),
    ]);
  }
}
