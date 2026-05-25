import '../core/eval_run_report.dart';
import '../core/eval_suite.dart';
import '../graders/score.dart';
import '../suite_health/suite_health_report.dart';

/// 生成一次 [EvalRunReport] 的 Markdown 总结。
String generateMarkdownReport(
  EvalRunReport report, {
  Map<String, String>? taskBucketMap,
  SuiteHealthReport? health,
  List<int> ksToReport = const [1, 3],
}) {
  final b = StringBuffer();
  final byTask = report.trialsByTask();

  b.writeln('# Eval Run: `${report.runName}`');
  b.writeln();
  b.writeln(
    '- Suite: **${report.suite.name}** '
    '(${_kindLabel(report.suite.kind)})',
  );
  b.writeln('- Started: ${report.startedAt.toIso8601String()}');
  b.writeln('- Duration: ${_formatDuration(report.duration)}');
  b.writeln('- Tasks: ${byTask.length} · Trials: ${report.trials.length}');
  b.writeln();

  // Top-line metrics
  b.writeln('## Top-line metrics');
  b.writeln();
  b.writeln('| Metric | Value |');
  b.writeln('|---|---|');
  b.writeln('| Task pass rate | ${_pct(report.taskPassRate)} |');
  b.writeln('| Trial pass rate | ${_pct(report.trialPassRate)} |');
  for (final entry in report.graderMeans.entries) {
    b.writeln(
      '| Grader mean: `${entry.key}` | ${entry.value.toStringAsFixed(3)} |',
    );
  }
  b.writeln();

  // pass@k / pass^k
  final passAtK = report.passAtKByTask(ks: ksToReport);
  final passCK = report.passCaretKByTask(ks: ksToReport);
  if (passAtK.isNotEmpty && ksToReport.isNotEmpty) {
    b.writeln('## pass@k / pass^k by task');
    b.writeln();
    final headers = [
      'Task',
      ...ksToReport.expand((k) => ['pass@$k', 'pass^$k']),
    ];
    b.writeln('| ${headers.join(' | ')} |');
    b.writeln('|${'---|' * headers.length}');
    for (final taskId in passAtK.keys) {
      final cells = <String>[
        '`$taskId`',
        for (final k in ksToReport) ...[
          _pct(passAtK[taskId]?[k] ?? 0),
          _pct(passCK[taskId]?[k] ?? 0),
        ],
      ];
      b.writeln('| ${cells.join(' | ')} |');
    }
    b.writeln();
  }

  // Bucket pass rates
  if (taskBucketMap != null) {
    final bucketRates = report.bucketPassRates(taskBucketMap);
    if (bucketRates.isNotEmpty) {
      b.writeln('## Pass rate by failure bucket');
      b.writeln();
      b.writeln('| Bucket | Pass rate |');
      b.writeln('|---|---|');
      for (final entry in bucketRates.entries) {
        b.writeln('| ${entry.key} | ${_pct(entry.value)} |');
      }
      b.writeln();
    }
  }

  // Failed trials
  final failed = report.trials.where((t) => !t.allGradersPassed).toList();
  if (failed.isNotEmpty) {
    b.writeln('## Failed trials (${failed.length})');
    b.writeln();
    for (final tr in failed) {
      b.writeln('### `${tr.trial.taskId}` · trial #${tr.trial.trialIndex}');
      b.writeln();
      for (final s in tr.scores) {
        b.writeln(_renderScore(s));
      }
      b.writeln();
    }
  }

  // Health
  if (health != null) {
    b.writeln('## Suite health');
    b.writeln();
    b.writeln(
      '- Saturation: ${_pct(health.currentSaturationRatio)} '
      '${health.currentlySaturated ? "⚠️ saturated" : ""}',
    );
    if (health.graduationCandidates.isNotEmpty) {
      b.writeln('- Graduation candidates:');
      for (final c in health.graduationCandidates) {
        b.writeln(
          '  - `${c.taskId}` (mean ${_pct(c.recentMeanPassRate)}, '
          '${c.consecutiveMatureRuns} consecutive mature runs)',
        );
      }
    }
    if (health.brokenTaskCandidates.isNotEmpty) {
      b.writeln('- Broken task candidates (likely task/grader bugs):');
      for (final c in health.brokenTaskCandidates) {
        b.writeln(
          '  - `${c.taskId}` (${c.passedTrials}/${c.totalTrials} '
          'passed = ${_pct(c.passRate)})',
        );
      }
    }
    b.writeln();
  }

  return b.toString();
}

String _renderScore(Score s) {
  final b = StringBuffer();
  final pass = s.passed == null
      ? '⚪ unknown'
      : (s.passed! ? '✅ passed' : '❌ failed');
  final value = s.value == null ? '—' : s.value!.toStringAsFixed(2);
  b.writeln('- **${s.graderName}** — $pass · score=$value');
  if (s.rationale != null && s.rationale!.isNotEmpty) {
    final indented = s.rationale!.split('\n').map((l) => '  $l').join('\n');
    b.writeln(indented);
  }
  if (s.assertions.isNotEmpty) {
    for (final a in s.assertions.where((a) => !a.passed)) {
      b.writeln(
        '  - ❌ ${a.description}'
        '${a.expected != null ? " · expected=`${a.expected}`" : ""}'
        '${a.actual != null ? " · actual=`${a.actual}`" : ""}',
      );
    }
  }
  return b.toString();
}

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

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

String _formatDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}h${d.inMinutes.remainder(60)}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m${d.inSeconds.remainder(60)}s';
  return '${d.inSeconds}s';
}

/// Convenience methods on [EvalRunReport] that render Markdown / diff output.
/// Implemented as extensions so the core `EvalRunReport` class doesn't have
/// to import the reporting layer.
extension EvalRunReportReporting on EvalRunReport {
  /// Render this run as a Markdown summary (PR comments, console output).
  String toMarkdownSummary({
    Map<String, String>? taskBucketMap,
    List<int> ksToReport = const [1, 3],
  }) {
    return generateMarkdownReport(
      this,
      taskBucketMap: taskBucketMap,
      ksToReport: ksToReport,
    );
  }
}
