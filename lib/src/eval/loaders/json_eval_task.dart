import '../core/eval_task.dart';
import '../core/reference_solution.dart';
import '../graders/grader.dart';

/// Data-driven [EvalTask]. Constructed from a parsed JSON map plus a
/// list of graders already resolved by the loader.
///
/// Schema of one task file:
/// ```json
/// {
///   "id": "card_event_meeting",
///   "description": "Calendar-style input → 'event' template.",
///   "input": {
///     "prompt": "..."
///   },
///   "metadata": {
///     "failure_bucket": "template_event"
///   },
///   "trials_per_run": 2,
///   "timeout_seconds": 120,
///   "reference_solution": {
///     "expected_outcome": {"card_saved": true},
///     "source": "manual"
///   },
///   "graders": [
///     {"name": "card_saved", "config": {"fact_id": "fact_001",
///                                        "templates": ["event"]}},
///     {"name": "called_get_card_metadata"}
///   ]
/// }
/// ```
///
/// The `agent_name` lives in `suite.json`, not here — every task in a
/// suite shares the same target agent. See [EvalSuite].
class JsonEvalTask implements EvalTask {
  @override
  final String id;
  @override
  final String description;
  @override
  final Map<String, dynamic> input;
  @override
  final ReferenceSolution? referenceSolution;
  @override
  final Map<String, String> metadata;
  @override
  final List<Grader> graders;
  @override
  final int trialsPerRun;
  @override
  final Duration? timeout;

  JsonEvalTask({
    required this.id,
    required this.description,
    required this.input,
    required this.graders,
    this.referenceSolution,
    this.metadata = const {},
    this.trialsPerRun = 1,
    this.timeout,
  });
}
