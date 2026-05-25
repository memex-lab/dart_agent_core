import '../core/eval_run_report.dart';
import '../reporting/report_store.dart';
import 'saturation_status.dart';
import 'suite_health_report.dart';

/// 跨多次 run 分析 suite 健康度。Anthropic Step 7 / 8 的工具支撑。
class SuiteHealthAnalyzer {
  final ReportStore store;
  final SaturationThresholds thresholds;

  const SuiteHealthAnalyzer(
    this.store, {
    this.thresholds = const SaturationThresholds(),
  });

  /// 检测当前 [report] 单次 run 的饱和度。
  SaturationStatus computeSaturationStatus(EvalRunReport report) {
    final byTask = report.trialsByTask();
    final mature = <String>[];
    final stragglers = <String>[];

    for (final entry in byTask.entries) {
      final passes = entry.value.where((tr) => tr.allGradersPassed).length;
      final total = entry.value.length;
      final passRate = total == 0 ? 0.0 : passes / total;
      if (passRate >= thresholds.matureTaskPassRate) {
        mature.add(entry.key);
      } else if (passRate <= thresholds.brokenTaskPassRate &&
          total >= thresholds.minTrialsForBrokenJudgment) {
        stragglers.add(entry.key);
      }
    }

    final ratio = byTask.isEmpty ? 0.0 : mature.length / byTask.length;
    return SaturationStatus(
      saturatedTaskRatio: ratio,
      suiteSaturated: ratio >= thresholds.saturatedSuiteRatio,
      matureTasks: mature,
      stragglerTasks: stragglers,
    );
  }
}

extension SuiteHealthAnalyzerOps on SuiteHealthAnalyzer {
  /// 跨多 run 分析。从 [store] 拉最近 [recentRunCount] 次 run 计算
  /// graduation/broken 候选 + 难度分布。
  Future<SuiteHealthReport> analyze({
    required String suiteName,
    int recentRunCount = 10,
  }) async {
    final runs = await store.loadRecent(
      suiteName: suiteName,
      limit: recentRunCount,
    );
    if (runs.isEmpty) {
      throw StateError(
        'No persisted runs found for suite "$suiteName". '
        'Save at least one EvalRunReport to the store before analyzing.',
      );
    }

    // 时间倒序保证 runs[0] 是最新的。
    runs.sort((a, b) => b.startedAt.compareTo(a.startedAt));

    // 收集每个 task 在每次 run 的通过率。
    // taskId -> [{run, passRate, trialsCount, passedCount}, ...]
    final perTaskPerRun = <String, List<_TaskRunStat>>{};
    for (final run in runs) {
      final byTask = run.trialsByTask();
      for (final entry in byTask.entries) {
        final passes = entry.value.where((tr) => tr.allGradersPassed).length;
        final total = entry.value.length;
        perTaskPerRun
            .putIfAbsent(entry.key, () => [])
            .add(
              _TaskRunStat(
                runName: run.runName,
                startedAt: run.startedAt,
                passes: passes,
                trials: total,
              ),
            );
      }
    }

    final graduates = <GraduationCandidate>[];
    final brokens = <BrokenTaskCandidate>[];
    final histogram = <String, int>{};

    for (final entry in perTaskPerRun.entries) {
      final stats = entry.value
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

      // 跨 run 平均通过率 → 难度分布
      final allTrials = stats.fold<int>(0, (a, b) => a + b.trials);
      final allPasses = stats.fold<int>(0, (a, b) => a + b.passes);
      final overallPassRate = allTrials == 0 ? 0.0 : allPasses / allTrials;
      final bucket = _bucketFor(overallPassRate);
      histogram[bucket] = (histogram[bucket] ?? 0) + 1;

      // 毕业判定：连续多次 run 都达到 mature 阈值
      var consecutiveMature = 0;
      for (final s in stats) {
        if (s.trials == 0) break;
        if (s.passes / s.trials >= thresholds.matureTaskPassRate) {
          consecutiveMature++;
        } else {
          break;
        }
      }
      if (consecutiveMature >= thresholds.consecutiveRunsForGraduation) {
        graduates.add(
          GraduationCandidate(
            taskId: entry.key,
            recentMeanPassRate: overallPassRate,
            consecutiveMatureRuns: consecutiveMature,
            contributingRuns: stats
                .take(consecutiveMature)
                .map((s) => s.runName)
                .toList(),
          ),
        );
      }

      // 破损候选：跨 run 几乎全失败
      if (allTrials >= thresholds.minTrialsForBrokenJudgment &&
          overallPassRate <= thresholds.brokenTaskPassRate) {
        brokens.add(
          BrokenTaskCandidate(
            taskId: entry.key,
            totalTrials: allTrials,
            passedTrials: allPasses,
            contributingRuns: stats.map((s) => s.runName).toList(),
          ),
        );
      }
    }

    // 当前饱和度（基于最新一次 run）
    final newest = runs.first;
    final newestSat = _computeSaturationFor(newest);

    return SuiteHealthReport(
      suiteName: suiteName,
      suiteKind: newest.suite.kind,
      analyzedRunCount: runs.length,
      thresholds: thresholds,
      graduationCandidates: graduates,
      brokenTaskCandidates: brokens,
      currentSaturationRatio: newestSat.saturatedTaskRatio,
      currentlySaturated: newestSat.suiteSaturated,
      difficultyHistogram: histogram,
    );
  }

  SaturationStatus _computeSaturationFor(PersistedRunReport report) {
    final byTask = report.trialsByTask();
    final mature = <String>[];
    final stragglers = <String>[];
    for (final entry in byTask.entries) {
      final passes = entry.value.where((tr) => tr.allGradersPassed).length;
      final total = entry.value.length;
      final passRate = total == 0 ? 0.0 : passes / total;
      if (passRate >= thresholds.matureTaskPassRate) {
        mature.add(entry.key);
      } else if (passRate <= thresholds.brokenTaskPassRate &&
          total >= thresholds.minTrialsForBrokenJudgment) {
        stragglers.add(entry.key);
      }
    }
    final ratio = byTask.isEmpty ? 0.0 : mature.length / byTask.length;
    return SaturationStatus(
      saturatedTaskRatio: ratio,
      suiteSaturated: ratio >= thresholds.saturatedSuiteRatio,
      matureTasks: mature,
      stragglerTasks: stragglers,
    );
  }
}

class _TaskRunStat {
  final String runName;
  final DateTime startedAt;
  final int passes;
  final int trials;
  const _TaskRunStat({
    required this.runName,
    required this.startedAt,
    required this.passes,
    required this.trials,
  });
}

String _bucketFor(double passRate) {
  if (passRate < 0.2) return '[0.0, 0.2)';
  if (passRate < 0.4) return '[0.2, 0.4)';
  if (passRate < 0.6) return '[0.4, 0.6)';
  if (passRate < 0.8) return '[0.6, 0.8)';
  if (passRate < 0.95) return '[0.8, 0.95)';
  return '[0.95, 1.0]';
}
