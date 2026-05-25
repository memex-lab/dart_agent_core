import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';

/// Per-trial workspace for the card agent demo. Layout:
///
/// ```
/// <tmp>/
///   cards/<fact_id>.yaml      # written by save_timeline_card
///   declined.txt              # written by decline (if any)
/// ```
class CardAgentEnvironment implements EvalEnvironment {
  final LLMClient Function() liveClientFactory;
  final RecordingStore? recordingStore;
  final bool replayOnly;
  final RateLimitGate rateLimitGate;

  CardAgentEnvironment({
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
      'eval_card_${trial.taskId}_${trial.trialIndex}_',
    );

    final salt = trial.cacheSalt;
    final LLMClient llm;
    if (replayOnly) {
      if (recordingStore == null) {
        throw StateError('replayOnly mode requires a RecordingStore.');
      }
      llm = ReplayLLMClient(
        store: recordingStore!,
        strictReplay: true,
        rateLimitGate: rateLimitGate,
        trialSalt: salt,
      );
    } else if (recordingStore != null) {
      llm = RecordingLLMClient(
        inner: liveClientFactory(),
        store: recordingStore!,
        rateLimitGate: rateLimitGate,
        trialSalt: salt,
      );
    } else {
      llm = liveClientFactory();
    }

    return EvalContext(
      workspaceDir: dir,
      clock: const SystemEvalClock(),
      llmClient: llm,
      controller: AgentController(),
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
