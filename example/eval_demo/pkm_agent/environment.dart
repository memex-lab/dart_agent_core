import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';

/// Per-trial workspace for the PKM agent demo. Layout:
///
/// ```
/// <tmp>/
///   PKM/
///     Projects/
///     Areas/
///     Resources/
///     Archives/
///   insights/<fact_id>.txt   # written by update_card_insight
///   skipped.txt              # written by skip_pkm_organization (if any)
/// ```
class PkmAgentEnvironment implements EvalEnvironment {
  final LLMClient Function() liveClientFactory;
  final RecordingStore? recordingStore;
  final bool replayOnly;
  final RateLimitGate rateLimitGate;

  PkmAgentEnvironment({
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
      'eval_pkm_${trial.taskId}_${trial.trialIndex}_',
    );
    // Pre-seed PARA roots so `ls_pkm` returns something useful.
    for (final bucket in ['Projects', 'Areas', 'Resources', 'Archives']) {
      Directory('${dir.path}/PKM/$bucket').createSync(recursive: true);
    }

    // Optional fixture files mounted at PKM/ — task input may carry a
    // map under `fixture_files`.
    final fixture = task.input['fixture_files'];
    if (fixture is Map) {
      fixture.forEach((relPath, content) {
        final f = File('${dir.path}/PKM/$relPath');
        f.parent.createSync(recursive: true);
        f.writeAsStringSync('$content');
      });
    }

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
