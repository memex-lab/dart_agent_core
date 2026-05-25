import '../../core/llm_client.dart';
import 'grader.dart';

/// Convenience base for LLM-as-judge graders.
///
/// Subclasses provide [judgeClient] (an LLM client to use as judge) and
/// [rubric] (a prompt template). The rubric should include an explicit
/// "Unknown" escape hatch (Anthropic Step 5) so the grader can return
/// `Score(value: null)` instead of fabricating a score.
abstract class ModelGrader implements Grader {
  @override
  GraderKind get kind => GraderKind.model;

  /// LLM client used for judging.
  LLMClient get judgeClient;

  /// Rubric prompt template. Must include an "Unknown" escape hatch.
  String get rubric;
}
