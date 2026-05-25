import '../core/eval_suite.dart';
import 'saturation_status.dart';

/// 跨多次 run 的 suite 健康分析。
///
/// 用法：
/// ```dart
/// final analyzer = SuiteHealthAnalyzer(reportStore);
/// final report = await analyzer.analyze(
///   suiteName: 'card_agent_capability',
///   recentRunCount: 10,
/// );
/// for (final c in report.graduationCandidates) {
///   print('graduate ${c.taskId}: ${c.recentMeanPassRate}');
/// }
/// ```
class SuiteHealthReport {
  final String suiteName;
  final SuiteKind suiteKind;
  final int analyzedRunCount;
  final SaturationThresholds thresholds;

  /// 在最近 N 次 run 都达到 matureTaskPassRate 的任务。
  final List<GraduationCandidate> graduationCandidates;

  /// 跨多次 run 都几乎全失败的任务（任务/grader 可能有 bug）。
  final List<BrokenTaskCandidate> brokenTaskCandidates;

  /// 当前最近一次 run 的饱和率。
  final double currentSaturationRatio;

  /// 是否当前已饱和。
  final bool currentlySaturated;

  /// 任务难度分布柱状图。key: `0.0-0.2` / `0.2-0.4` / ... / `0.8-1.0`，
  /// value: 落入此通过率区间的任务数（基于跨 run 平均通过率）。
  final Map<String, int> difficultyHistogram;

  const SuiteHealthReport({
    required this.suiteName,
    required this.suiteKind,
    required this.analyzedRunCount,
    required this.thresholds,
    required this.graduationCandidates,
    required this.brokenTaskCandidates,
    required this.currentSaturationRatio,
    required this.currentlySaturated,
    required this.difficultyHistogram,
  });

  Map<String, dynamic> toJson() => {
    'suiteName': suiteName,
    'suiteKind': suiteKind.name,
    'analyzedRunCount': analyzedRunCount,
    'graduationCandidates': graduationCandidates
        .map((g) => g.toJson())
        .toList(),
    'brokenTaskCandidates': brokenTaskCandidates
        .map((b) => b.toJson())
        .toList(),
    'currentSaturationRatio': currentSaturationRatio,
    'currentlySaturated': currentlySaturated,
    'difficultyHistogram': difficultyHistogram,
  };
}
