/// Saturation 评估的阈值和分桶决议。Anthropic Step 7：当 capability suite
/// 上 task 普遍接近 100% 通过时，应当把它们"毕业"到 regression suite，
/// 并往 capability suite 里补更难的 task。
class SaturationThresholds {
  /// pass@1 ≥ 该阈值视为"已成熟"。
  final double matureTaskPassRate;

  /// 连续多少次 dataset run 都达到 [matureTaskPassRate] 才算"建议毕业"。
  final int consecutiveRunsForGraduation;

  /// pass@1 ≤ 该阈值视为"几乎不能解"——往往是任务定义有 bug。
  final double brokenTaskPassRate;

  /// 在多少 trial 上都低于 [brokenTaskPassRate] 才算"破损候选"。
  final int minTrialsForBrokenJudgment;

  /// suite 中 mature task 占比 ≥ 该阈值视为"已饱和"。
  final double saturatedSuiteRatio;

  const SaturationThresholds({
    this.matureTaskPassRate = 0.95,
    this.consecutiveRunsForGraduation = 5,
    this.brokenTaskPassRate = 0.0,
    this.minTrialsForBrokenJudgment = 10,
    this.saturatedSuiteRatio = 0.9,
  });
}

/// 当一个 task 在最近 N 次 run 都达到成熟通过率，建议毕业到 regression suite。
class GraduationCandidate {
  final String taskId;
  final double recentMeanPassRate;
  final int consecutiveMatureRuns;
  final List<String> contributingRuns;

  const GraduationCandidate({
    required this.taskId,
    required this.recentMeanPassRate,
    required this.consecutiveMatureRuns,
    required this.contributingRuns,
  });

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'recentMeanPassRate': recentMeanPassRate,
    'consecutiveMatureRuns': consecutiveMatureRuns,
    'contributingRuns': contributingRuns,
  };
}

/// 跨多次 run 都几乎全失败的任务——通常是任务定义/grader 配置有 bug，
/// 而不是 agent 真的不会做（Anthropic Step 2 显式提醒）。
class BrokenTaskCandidate {
  final String taskId;
  final int totalTrials;
  final int passedTrials;
  final List<String> contributingRuns;

  const BrokenTaskCandidate({
    required this.taskId,
    required this.totalTrials,
    required this.passedTrials,
    required this.contributingRuns,
  });

  double get passRate => totalTrials == 0 ? 0.0 : passedTrials / totalTrials;

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'totalTrials': totalTrials,
    'passedTrials': passedTrials,
    'passRate': passRate,
    'contributingRuns': contributingRuns,
  };
}

/// 在单次 run 视角下评估 suite 的健康度（饱和率 + 候选清单的当下值）。
class SaturationStatus {
  /// 当前 run 中 pass@1 ≥ matureTaskPassRate 的任务数 / 总任务数。
  final double saturatedTaskRatio;

  /// 是否整个 suite 已"饱和"。
  final bool suiteSaturated;

  /// 在当前 run 中表现良好的任务（pass@1 ≥ 阈值）。仅基于当次数据，
  /// 真正的"是否建议毕业"需要 [SuiteHealthAnalyzer] 跨多 run 判断。
  final List<String> matureTasks;

  /// 在当前 run 中表现极差的任务。
  final List<String> stragglerTasks;

  const SaturationStatus({
    required this.saturatedTaskRatio,
    required this.suiteSaturated,
    required this.matureTasks,
    required this.stragglerTasks,
  });

  Map<String, dynamic> toJson() => {
    'saturatedTaskRatio': saturatedTaskRatio,
    'suiteSaturated': suiteSaturated,
    'matureTasks': matureTasks,
    'stragglerTasks': stragglerTasks,
  };
}
