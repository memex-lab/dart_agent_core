import '../core/eval_context.dart';
import '../core/outcome.dart';
import '../core/reference_solution.dart';
import '../core/transcript.dart';
import '../core/trial.dart';
import 'score.dart';

/// Anthropic identifies three kinds of graders.
enum GraderKind { code, model, human }

/// A grader scores some aspect of an agent's performance for one trial.
///
/// Implementations should default to inspecting the [Outcome] rather than
/// the [Transcript] (Anthropic Step 5: grade what the agent produced, not
/// the path it took).
abstract class Grader {
  /// Stable name. Used as score key in reports.
  String get name;

  /// Anthropic kind: code / model / human.
  GraderKind get kind;

  /// If a [Score.value] meets or exceeds this threshold, [Score.passed] is
  /// `true`. Defaults to `1.0` (binary) but graders may override to support
  /// partial credit thresholds.
  double get passThreshold => 1.0;

  /// Compute a score for one trial.
  Future<Score> grade({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  });
}
