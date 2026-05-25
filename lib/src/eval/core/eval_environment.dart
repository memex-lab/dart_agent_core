import 'eval_context.dart';
import 'eval_task.dart';
import 'trial.dart';

/// Anthropic Step 4: each trial must run in an isolated, clean environment.
///
/// Applications implement this to set up workspaces, in-memory databases,
/// time, and any other per-trial resources. The runner calls [prepare]
/// before each trial and [dispose] after, regardless of outcome.
abstract class EvalEnvironment {
  /// Prepare a fresh context for one trial.
  Future<EvalContext> prepare({required Trial trial, required EvalTask task});

  /// Tear down. Called after the trial completes (success or failure).
  Future<void> dispose(EvalContext context);
}
