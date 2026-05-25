import '../core/eval_context.dart';
import '../core/outcome.dart';
import '../core/reference_solution.dart';
import '../core/transcript.dart';
import '../core/trial.dart';
import 'grader.dart';
import 'score.dart';

/// 人工审阅队列。框架不拥有 UI，但提供一个抽象让应用层接到自己的审阅平台
/// （Langfuse Annotation Queue、自建 Web、Slack 工作流等）。
abstract class HumanReviewQueue {
  /// 将一个 trial 推到队列等待人工审阅。
  Future<void> enqueue({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    String? rubric,
    Map<String, dynamic> metadata = const {},
  });

  /// 拉取已有的人工评分。如果尚未评（或已被丢弃），返回 null。
  /// 实现应当是非阻塞的——eval runner 跑完一次后可以立即查队列状态，
  /// 没结果就标记为 `Score(value: null)` + `rationale: "pending human review"`。
  Future<Score?> fetchVerdict(Trial trial);
}

/// Anthropic Step 5 / 8: human graders are gold-standard for subjective
/// dimensions, used both for direct scoring and for calibrating LLM judges.
///
/// Concrete implementations connect to an application-provided
/// [HumanReviewQueue]. The default [grade] flow is:
/// 1. Push the trial to the queue (non-blocking).
/// 2. Poll for a verdict; if absent, return a pending `Score(value: null)`.
abstract class HumanGrader implements Grader {
  @override
  GraderKind get kind => GraderKind.human;

  /// Where to enqueue trials and where to read back human verdicts.
  HumanReviewQueue get queue;

  /// Optional rubric prompt shown to human reviewers in the UI.
  String? get rubric => null;

  @override
  double get passThreshold => 1.0;

  @override
  Future<Score> grade({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    await queue.enqueue(
      trial: trial,
      transcript: transcript,
      outcome: outcome,
      rubric: rubric,
    );
    final existing = await queue.fetchVerdict(trial);
    if (existing != null) return existing;
    return Score(
      graderName: name,
      value: null,
      passed: null,
      rationale: 'pending human review',
    );
  }
}
