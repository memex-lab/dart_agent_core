import '../core/eval_run_report.dart';
import '../core/eval_suite.dart';
import '../core/trial_result.dart';

/// 跨两个 [EvalRunReport] 的差分。
class EvalRunDiff {
  /// 当前 run（PR/staging）。
  final EvalRunReport current;

  /// 基线 run（main/production）。
  final EvalRunReport baseline;

  /// 在两个 run 中都存在但状态变化的任务。
  final List<TaskTransition> transitions;

  /// 仅在当前 run 中出现的 task id（新增）。
  final List<String> addedTaskIds;

  /// 仅在基线中出现的 task id（被移除/重命名）。
  final List<String> removedTaskIds;

  /// Top-line metric 变化。
  final Map<String, double> metricDeltas;

  const EvalRunDiff({
    required this.current,
    required this.baseline,
    required this.transitions,
    required this.addedTaskIds,
    required this.removedTaskIds,
    required this.metricDeltas,
  });

  /// 生成 PR comment 友好的 markdown。
  String toMarkdown() {
    final b = StringBuffer();
    b.writeln('# Eval diff: `${current.runName}` vs `${baseline.runName}`');
    b.writeln();
    b.writeln(
      '- Suite: **${current.suite.name}** (${_kindLabel(current.suite.kind)})',
    );
    b.writeln(
      '- Tasks: ${current.trialsByTask().length} '
      '(was ${baseline.trialsByTask().length})',
    );
    b.writeln();

    b.writeln('## Top-line metrics');
    b.writeln();
    b.writeln('| Metric | This run | Baseline | Δ |');
    b.writeln('|---|---|---|---|');
    for (final entry in metricDeltas.entries) {
      final deltaStr = _delta(entry.value);
      final marker =
          current.suite.kind == SuiteKind.regression &&
              entry.value < 0 &&
              entry.key.contains('pass_rate')
          ? ' 🚨'
          : '';
      b.writeln(
        '| ${entry.key} | '
        '${_metricCurrent(entry.key)} | '
        '${_metricBaseline(entry.key)} | '
        '$deltaStr$marker |',
      );
    }
    b.writeln();

    final regressed = transitions
        .where((t) => t.kind == TaskTransitionKind.regressed)
        .toList();
    if (regressed.isNotEmpty) {
      b.writeln('## 🚨 Regressed tasks (${regressed.length})');
      b.writeln();
      for (final t in regressed) {
        b.writeln(
          '- `${t.taskId}`: '
          'baseline ${_pct(t.baselinePassRate)} → '
          'current ${_pct(t.currentPassRate)}',
        );
      }
      b.writeln();
    }

    final improved = transitions
        .where((t) => t.kind == TaskTransitionKind.improved)
        .toList();
    if (improved.isNotEmpty) {
      b.writeln('## ⬆️ Improved tasks (${improved.length})');
      b.writeln();
      for (final t in improved) {
        b.writeln(
          '- `${t.taskId}`: '
          '${_pct(t.baselinePassRate)} → ${_pct(t.currentPassRate)}',
        );
      }
      b.writeln();
    }

    if (addedTaskIds.isNotEmpty) {
      b.writeln('## ➕ Added tasks');
      b.writeln();
      for (final id in addedTaskIds) {
        b.writeln('- `$id`');
      }
      b.writeln();
    }

    if (removedTaskIds.isNotEmpty) {
      b.writeln('## ➖ Removed tasks');
      b.writeln();
      for (final id in removedTaskIds) {
        b.writeln('- `$id`');
      }
      b.writeln();
    }

    return b.toString();
  }

  String _metricCurrent(String key) {
    switch (key) {
      case 'task_pass_rate':
        return _pct(current.taskPassRate);
      case 'trial_pass_rate':
        return _pct(current.trialPassRate);
      default:
        final mean = current.graderMeans[key.replaceFirst('grader_mean.', '')];
        return mean == null ? '—' : mean.toStringAsFixed(3);
    }
  }

  String _metricBaseline(String key) {
    switch (key) {
      case 'task_pass_rate':
        return _pct(baseline.taskPassRate);
      case 'trial_pass_rate':
        return _pct(baseline.trialPassRate);
      default:
        final mean = baseline.graderMeans[key.replaceFirst('grader_mean.', '')];
        return mean == null ? '—' : mean.toStringAsFixed(3);
    }
  }
}

enum TaskTransitionKind { regressed, improved, unchanged }

class TaskTransition {
  final String taskId;
  final double currentPassRate;
  final double baselinePassRate;
  final TaskTransitionKind kind;

  const TaskTransition({
    required this.taskId,
    required this.currentPassRate,
    required this.baselinePassRate,
    required this.kind,
  });

  bool get regressed => kind == TaskTransitionKind.regressed;
  bool get improved => kind == TaskTransitionKind.improved;
  bool get unchanged => kind == TaskTransitionKind.unchanged;
}

/// 计算两份 run report 的 diff。
EvalRunDiff diffRunReports({
  required EvalRunReport current,
  required EvalRunReport baseline,
  double significanceThreshold = 0.05,
}) {
  final currByTask = current.trialsByTask();
  final baseByTask = baseline.trialsByTask();

  final shared = currByTask.keys.toSet().intersection(baseByTask.keys.toSet());
  final transitions = <TaskTransition>[];
  for (final id in shared) {
    final cur = _passRate(currByTask[id]!);
    final base = _passRate(baseByTask[id]!);
    final delta = cur - base;
    final t = delta.abs() < significanceThreshold
        ? TaskTransitionKind.unchanged
        : (delta > 0
              ? TaskTransitionKind.improved
              : TaskTransitionKind.regressed);
    transitions.add(
      TaskTransition(
        taskId: id,
        currentPassRate: cur,
        baselinePassRate: base,
        kind: t,
      ),
    );
  }

  final added = currByTask.keys.toSet().difference(baseByTask.keys.toSet());
  final removed = baseByTask.keys.toSet().difference(currByTask.keys.toSet());

  final deltas = <String, double>{
    'task_pass_rate': current.taskPassRate - baseline.taskPassRate,
    'trial_pass_rate': current.trialPassRate - baseline.trialPassRate,
  };
  for (final entry in current.graderMeans.entries) {
    final baseValue = baseline.graderMeans[entry.key];
    if (baseValue != null) {
      deltas['grader_mean.${entry.key}'] = entry.value - baseValue;
    }
  }

  return EvalRunDiff(
    current: current,
    baseline: baseline,
    transitions: transitions,
    addedTaskIds: added.toList()..sort(),
    removedTaskIds: removed.toList()..sort(),
    metricDeltas: deltas,
  );
}

double _passRate(List<TrialResult> trs) {
  if (trs.isEmpty) return 0.0;
  return trs.where((t) => t.allGradersPassed).length / trs.length;
}

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

String _delta(double v) {
  final pct = '${(v * 100).toStringAsFixed(1)}%';
  if (v > 0) return '+$pct ⬆';
  if (v < 0) return '$pct ⬇';
  return '0%';
}

String _kindLabel(SuiteKind kind) {
  switch (kind) {
    case SuiteKind.capability:
      return 'capability';
    case SuiteKind.regression:
      return 'regression';
    case SuiteKind.mixed:
      return 'mixed';
  }
}

/// Convenience: `current.diffWith(baseline)` reads more naturally than
/// `diffRunReports(current: current, baseline: baseline)`.
extension EvalRunReportDiff on EvalRunReport {
  EvalRunDiff diffWith(
    EvalRunReport baseline, {
    double significanceThreshold = 0.05,
  }) {
    return diffRunReports(
      current: this,
      baseline: baseline,
      significanceThreshold: significanceThreshold,
    );
  }
}
