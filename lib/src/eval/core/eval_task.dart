import '../graders/grader.dart';
import 'reference_solution.dart';

/// Anthropic: a task is a single test with defined inputs and success
/// criteria. Implementations are pure data — they do not run the agent.
///
/// Note on what's intentionally **not** here:
///   - There is no `successCriteria` map. The success contract lives
///     entirely inside [graders]; a description-only mirror of it on
///     the task would drift from the actual graders. If you want a
///     human-readable summary of what a task tests, use [description]
///     plus [metadata].
///   - There is no `expectedBehavior` enum (`positive` / `negative`).
///     Use [metadata]['failure_bucket'] or a similar tag to mark
///     positive vs negative tasks if you need to filter by it.
abstract class EvalTask {
  /// Stable id. **Immutable after creation.**
  ///
  /// If the task changes meaningfully (input, graders, reference
  /// solution), create a new task with a new id (convention:
  /// `card_001` → `card_001_v2`). Historical reports stay associated
  /// with the old id. See RFC §6.16 / §13.2.
  String get id;

  /// One-line human description.
  String get description;

  /// Input handed to the agent harness. Schema is application-defined.
  Map<String, dynamic> get input;

  /// Anthropic Step 2: a known working solution that passes all graders.
  /// Strongly recommended — proves the task is solvable and graders are
  /// configured correctly. May be required by the parent suite.
  ReferenceSolution? get referenceSolution => null;

  /// Free-form labels for filtering and bucketing. Conventional keys:
  /// `failure_bucket`, `fixture`, `difficulty`, `language`, `expected`.
  Map<String, String> get metadata => const {};

  /// Graders attached to this task. At least one is required.
  List<Grader> get graders;

  /// Anthropic non-determinism: how many trials to run per dataset run.
  /// Defaults to 1. Set ≥3 for tasks where stability matters (pass^k).
  int get trialsPerRun => 1;

  /// Optional per-task timeout. Falls back to the runner default if null.
  Duration? get timeout => null;
}
