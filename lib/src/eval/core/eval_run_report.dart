import '../core/eval_suite.dart';
import '../core/trial_result.dart';
import '../metrics/pass_at_k.dart';
import '../metrics/pass_caret_k.dart';
import '../suite_health/saturation_status.dart';

/// Aggregated outcome of one [EvalRunner.runSuite] invocation.
class EvalRunReport {
  final String runName;
  final EvalSuite suite;
  final List<TrialResult> trials;
  final DateTime startedAt;
  final DateTime endedAt;

  EvalRunReport({
    required this.runName,
    required this.suite,
    required this.trials,
    required this.startedAt,
    required this.endedAt,
  });

  Duration get duration => endedAt.difference(startedAt);

  /// Trials grouped by task id.
  Map<String, List<TrialResult>> trialsByTask() {
    final out = <String, List<TrialResult>>{};
    for (final t in trials) {
      out.putIfAbsent(t.trial.taskId, () => []).add(t);
    }
    return out;
  }

  /// pass@k for each task, computed from its actual trial count.
  /// Returns map of taskId -> {k -> pass@k}.
  Map<String, Map<int, double>> passAtKByTask({List<int> ks = const [1]}) {
    final byTask = trialsByTask();
    final out = <String, Map<int, double>>{};
    for (final entry in byTask.entries) {
      final passes = entry.value.map((tr) => tr.allGradersPassed).toList();
      out[entry.key] = {for (final k in ks) k: passAtK(passes, k)};
    }
    return out;
  }

  /// pass^k for each task.
  Map<String, Map<int, double>> passCaretKByTask({List<int> ks = const [1]}) {
    final byTask = trialsByTask();
    final out = <String, Map<int, double>>{};
    for (final entry in byTask.entries) {
      final passes = entry.value.map((tr) => tr.allGradersPassed).toList();
      out[entry.key] = {for (final k in ks) k: passCaretK(passes, k)};
    }
    return out;
  }

  /// Overall fraction of trials that passed.
  double get trialPassRate {
    if (trials.isEmpty) return 0.0;
    final passed = trials.where((t) => t.allGradersPassed).length;
    return passed / trials.length;
  }

  /// Overall task pass rate. Definition depends on suite kind:
  ///   - regression: task passes only if every trial passes (pass^N where N=trialsPerRun)
  ///   - capability: task passes if at least one trial passes (pass@N)
  ///   - mixed: same as regression
  double get taskPassRate {
    final byTask = trialsByTask();
    if (byTask.isEmpty) return 0.0;
    final passing = byTask.values.where((trs) {
      if (suite.kind == SuiteKind.capability) {
        return trs.any((t) => t.allGradersPassed);
      }
      return trs.every((t) => t.allGradersPassed);
    }).length;
    return passing / byTask.length;
  }

  /// Mean of each grader's score across all trials (null-valued scores
  /// are excluded). Useful for tracking title_quality, etc.
  Map<String, double> get graderMeans {
    final accum = <String, List<double>>{};
    for (final tr in trials) {
      for (final s in tr.scores) {
        if (s.value == null) continue;
        accum.putIfAbsent(s.graderName, () => []).add(s.value!);
      }
    }
    return {
      for (final e in accum.entries)
        e.key: e.value.reduce((a, b) => a + b) / e.value.length,
    };
  }

  /// Per-bucket pass rate using metadata['failure_bucket'] on the source
  /// task. The Runner attaches the bucket to each TrialResult via
  /// `Trial`'s `taskId` lookup.
  Map<String, double> bucketPassRates(Map<String, String> taskBucketMap) {
    final byBucket = <String, List<bool>>{};
    for (final tr in trials) {
      final b = taskBucketMap[tr.trial.taskId];
      if (b == null) continue;
      byBucket.putIfAbsent(b, () => []).add(tr.allGradersPassed);
    }
    return {
      for (final e in byBucket.entries)
        e.key: e.value.where((v) => v).length / e.value.length,
    };
  }

  /// Saturation snapshot for THIS run. See Anthropic Step 7. Capability
  /// suites that come back with a high `saturatedTaskRatio` are signaling
  /// that easy tasks should graduate to a regression suite and harder
  /// tasks should be added.
  ///
  /// This is a single-run computation; for cross-run analysis (graduation
  /// candidates that have been mature in N consecutive runs, broken-task
  /// detection across runs) use `SuiteHealthAnalyzer`.
  SaturationStatus saturationStatus({
    SaturationThresholds thresholds = const SaturationThresholds(),
  }) {
    final byTask = trialsByTask();
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
