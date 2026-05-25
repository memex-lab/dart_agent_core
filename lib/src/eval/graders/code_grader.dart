import '../core/eval_context.dart';
import '../core/outcome.dart';
import '../core/reference_solution.dart';
import '../core/transcript.dart';
import '../core/trial.dart';
import 'grader.dart';
import 'score.dart';

/// Convenience base for deterministic code-based graders.
///
/// Subclasses implement [computeAssertions] and the base composes them into
/// a [Score]. The default [passThreshold] is 1.0 (all assertions must pass).
abstract class CodeGrader implements Grader {
  @override
  GraderKind get kind => GraderKind.code;

  @override
  double get passThreshold => 1.0;

  /// Subclasses produce a list of pass/fail assertions.
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  });

  /// Subclasses may override to customize the rationale produced on
  /// failure; default joins all failed assertion descriptions.
  String? buildRationale(List<Assertion> assertions) {
    final failed = assertions.where((a) => !a.passed).toList();
    if (failed.isEmpty) return null;
    return failed.map((a) => '- ${a.description}').join('\n');
  }

  @override
  Future<Score> grade({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final assertions = await computeAssertions(
      trial: trial,
      transcript: transcript,
      outcome: outcome,
      context: context,
      referenceSolution: referenceSolution,
    );
    final passedCount = assertions.where((a) => a.passed).length;
    final value = assertions.isEmpty ? 0.0 : passedCount / assertions.length;
    return Score(
      graderName: name,
      value: value,
      passed: value >= passThreshold,
      assertions: assertions,
      rationale: buildRationale(assertions),
    );
  }
}
