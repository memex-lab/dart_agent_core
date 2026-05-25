import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';

/// EvalEnvironment for the calculator demo.
///
/// Each trial gets its own temp directory. The trial's
/// [submit_answer] / [decline] tools write into that directory; the
/// graders read from it via [Outcome.environmentState].
///
/// LLM client is built fresh per-trial so that recorder/replayer wrapping
/// — if any — is per-trial isolated.
class CalculatorEvalEnvironment implements EvalEnvironment {
  /// How to build the upstream (live) LLM client. The runner may wrap it
  /// with RecordingLLMClient or replace it with ReplayLLMClient depending
  /// on run mode.
  final LLMClient Function() liveClientFactory;

  /// Optional record / replay store; if non-null we wrap [liveClientFactory]
  /// with RecordingLLMClient and the runner can read recordings later.
  final RecordingStore? recordingStore;

  /// Force replay mode (don't even create live client; raise on miss).
  final bool replayOnly;

  /// Optional rate gate forwarded to the LLM clients.
  final RateLimitGate rateLimitGate;

  /// `_recordingStore` for replay (when liveClientFactory is null and store
  /// is set). If [replayOnly] is true and store is set, we use it for replay.
  CalculatorEvalEnvironment({
    required this.liveClientFactory,
    this.recordingStore,
    this.replayOnly = false,
    RateLimitGate? rateLimitGate,
  }) : rateLimitGate = rateLimitGate ?? const NoopRateLimitGate();

  @override
  Future<EvalContext> prepare({
    required Trial trial,
    required EvalTask task,
  }) async {
    final dir = await Directory.systemTemp.createTemp(
      'eval_demo_${trial.taskId}_${trial.trialIndex}_',
    );

    final salt = trial.cacheSalt;
    final LLMClient llmClient;
    if (replayOnly) {
      if (recordingStore == null) {
        throw StateError(
          'replayOnly mode requires a RecordingStore for replay.',
        );
      }
      llmClient = ReplayLLMClient(
        store: recordingStore!,
        strictReplay: true,
        rateLimitGate: rateLimitGate,
        trialSalt: salt,
      );
    } else if (recordingStore != null) {
      llmClient = RecordingLLMClient(
        inner: liveClientFactory(),
        store: recordingStore!,
        rateLimitGate: rateLimitGate,
        trialSalt: salt,
      );
    } else {
      llmClient = liveClientFactory();
    }

    final controller = AgentController();

    return EvalContext(
      workspaceDir: dir,
      clock: const SystemEvalClock(),
      llmClient: llmClient,
      controller: controller,
      servicesMap: const {},
      metadata: {'fixture_path': dir.path},
    );
  }

  @override
  Future<void> dispose(EvalContext context) async {
    final dir = context.workspaceDir;
    if (dir != null && await dir.exists()) {
      await dir.delete(recursive: true);
    }
    context.controller.close();
  }
}
