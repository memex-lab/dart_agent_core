import 'dart:convert';
import 'dart:io';

import '../core/eval_suite.dart';
import '../core/trial_result.dart';
import '../graders/score.dart';
import '../reporting/report_store.dart';

/// 命令行帮助文档。
const String transcriptViewerUsage = r'''
Usage: transcripts <command> [options]

Commands:
  list                          List recent runs.
    --suite NAME                Filter by suite.
    --limit N                   Max rows (default 20).

  show                          Show one trial.
    --trial RUN/TASK#INDEX      e.g. card_v3/card_001#0
    --format human|json         (default human)

  diff                          Compare same task across two runs.
    --task TASK_ID              Required.
    --runs RUN_A,RUN_B          Required.

  export                        Export run as one markdown blob.
    --run RUN_NAME              Required.
    --format markdown|json      (default markdown)

Common options:
  --store DIR                   Report store directory (default: ./reports)
''';

/// 命令行入口。`bin/transcripts.dart` 直接 `await runTranscriptViewer(args)`。
Future<int> runTranscriptViewer(List<String> args) async {
  if (args.isEmpty) {
    stdout.writeln(transcriptViewerUsage);
    return 0;
  }

  final cmd = args.first;
  final opts = _parseOptions(args.sublist(1));
  final store = FileReportStore(Directory(opts['store'] ?? './reports'));

  switch (cmd) {
    case 'list':
      return _cmdList(store, opts);
    case 'show':
      return _cmdShow(store, opts);
    case 'diff':
      return _cmdDiff(store, opts);
    case 'export':
      return _cmdExport(store, opts);
    case '-h':
    case '--help':
      stdout.writeln(transcriptViewerUsage);
      return 0;
    default:
      stderr.writeln('unknown command: $cmd');
      stdout.writeln(transcriptViewerUsage);
      return 2;
  }
}

Map<String, String> _parseOptions(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--')) {
      final key = a.substring(2);
      final value = (i + 1 < args.length && !args[i + 1].startsWith('--'))
          ? args[++i]
          : 'true';
      out[key] = value;
    }
  }
  return out;
}

Future<int> _cmdList(ReportStore store, Map<String, String> opts) async {
  final suite = opts['suite'];
  final limit = int.tryParse(opts['limit'] ?? '20') ?? 20;
  if (suite == null) {
    final names = await store.listRunNames(limit: limit);
    if (names.isEmpty) {
      stdout.writeln('No runs found.');
      return 0;
    }
    for (final n in names) {
      stdout.writeln(n);
    }
    return 0;
  }
  final entries = await store.listRecent(suiteName: suite, limit: limit);
  if (entries.isEmpty) {
    stdout.writeln('No runs found for suite "$suite".');
    return 0;
  }
  stdout.writeln(
    [
      'Run',
      'Suite',
      'Kind',
      'Started',
      'Tasks pass',
      'Trials pass',
      '#trials',
    ].join('\t'),
  );
  for (final e in entries) {
    stdout.writeln(
      [
        e.runName,
        e.suiteName,
        e.suiteKind.name,
        e.startedAt.toIso8601String(),
        '${(e.taskPassRate * 100).toStringAsFixed(1)}%',
        '${(e.trialPassRate * 100).toStringAsFixed(1)}%',
        e.numTrials,
      ].join('\t'),
    );
  }
  return 0;
}

Future<int> _cmdShow(ReportStore store, Map<String, String> opts) async {
  final spec = opts['trial'];
  if (spec == null) {
    stderr.writeln('--trial RUN/TASK#INDEX is required');
    return 2;
  }
  final parsed = _parseTrialSpec(spec);
  if (parsed == null) {
    stderr.writeln('invalid --trial: $spec (expected RUN/TASK#INDEX)');
    return 2;
  }

  final report = await store.load(parsed.runName);
  if (report == null) {
    stderr.writeln('run not found: ${parsed.runName}');
    return 1;
  }
  final tr = report.trials.firstWhere(
    (t) =>
        t.trial.taskId == parsed.taskId &&
        t.trial.trialIndex == parsed.trialIndex,
    orElse: () => throw StateError('trial not found in run'),
  );

  if ((opts['format'] ?? 'human') == 'json') {
    stdout.writeln(jsonEncode(tr.toJson()));
    return 0;
  }
  _renderTrialHuman(tr, report.suite.kind);
  return 0;
}

void _renderTrialHuman(TrialResult tr, SuiteKind kind) {
  final t = tr.trial;
  stdout.writeln('Trial: ${t.runName} / ${t.taskId} #${t.trialIndex}');
  stdout.writeln('Status: ${t.status.name}');
  stdout.writeln('Duration: ${t.duration}');
  stdout.writeln('All graders passed: ${tr.allGradersPassed}');
  if (t.failureReason != null) {
    stdout.writeln('Failure reason: ${t.failureReason}');
  }
  stdout.writeln();
  stdout.writeln('--- Scores ---');
  for (final s in tr.scores) {
    stdout.writeln(_scoreLine(s));
  }
  stdout.writeln();
  stdout.writeln('--- Outcome ---');
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert(tr.outcome.environmentState),
  );
  stdout.writeln();
  stdout.writeln('--- Transcript metrics ---');
  final m = tr.transcript.metrics;
  stdout.writeln(
    'turns=${m.nTurns} tools=${m.nToolCalls} tokens=${m.nTotalTokens}',
  );
  stdout.writeln();
  stdout.writeln('--- Messages ---');
  for (final msg in tr.transcript.messages) {
    final j = msg.toJson();
    final role = j['role'];
    final text = _previewText(j);
    stdout.writeln('[$role] $text');
  }
  stdout.writeln();
  stdout.writeln('--- Tool calls ---');
  for (final c in tr.transcript.toolCalls) {
    stdout.writeln(
      '${c.toolName}(${jsonEncode(c.arguments)})'
      '${c.isError ? " [ERROR]" : ""}',
    );
  }
}

String _scoreLine(Score s) {
  final pass = s.passed == null ? '?' : (s.passed! ? '✓' : '✗');
  final value = s.value?.toStringAsFixed(2) ?? '—';
  final tail = s.rationale == null ? '' : ' — ${s.rationale}';
  return '$pass ${s.graderName} ($value)$tail';
}

String _previewText(Map<String, dynamic> j) {
  final c = j['content'];
  if (c is String) return c.length > 200 ? '${c.substring(0, 200)}…' : c;
  if (c is List) {
    final parts = c
        .map((p) {
          if (p is Map && p['type'] == 'text')
            return p['text']?.toString() ?? '';
          if (p is Map && p['text'] is String) return p['text'];
          return '<${(p as Map?)?['type'] ?? "?"}>';
        })
        .join(' ');
    return parts.length > 200 ? '${parts.substring(0, 200)}…' : parts;
  }
  return jsonEncode(c);
}

class _TrialSpec {
  final String runName;
  final String taskId;
  final int trialIndex;
  const _TrialSpec(this.runName, this.taskId, this.trialIndex);
}

_TrialSpec? _parseTrialSpec(String s) {
  final hashIdx = s.lastIndexOf('#');
  final slashIdx = s.indexOf('/');
  if (hashIdx <= 0 || slashIdx <= 0 || hashIdx <= slashIdx) return null;
  final runName = s.substring(0, slashIdx);
  final taskId = s.substring(slashIdx + 1, hashIdx);
  final idx = int.tryParse(s.substring(hashIdx + 1));
  if (idx == null) return null;
  return _TrialSpec(runName, taskId, idx);
}

Future<int> _cmdDiff(ReportStore store, Map<String, String> opts) async {
  final taskId = opts['task'];
  final runs = (opts['runs'] ?? '')
      .split(',')
      .where((s) => s.isNotEmpty)
      .toList();
  if (taskId == null || runs.length != 2) {
    stderr.writeln('--task TASK_ID and --runs RUN_A,RUN_B are required');
    return 2;
  }

  final reports = <PersistedRunReport>[];
  for (final r in runs) {
    final report = await store.load(r);
    if (report == null) {
      stderr.writeln('run not found: $r');
      return 1;
    }
    reports.add(report);
  }

  for (var i = 0; i < 2; i++) {
    final r = reports[i];
    stdout.writeln('=== ${r.runName} (${r.startedAt.toIso8601String()}) ===');
    final trials = r.trials.where((t) => t.trial.taskId == taskId).toList();
    if (trials.isEmpty) {
      stdout.writeln('  no trials for task $taskId');
      continue;
    }
    for (final t in trials) {
      stdout.writeln(
        '  trial #${t.trial.trialIndex}: '
        '${t.allGradersPassed ? "PASS" : "FAIL"} '
        '(scores=${t.scores.map((s) => "${s.graderName}=${s.value?.toStringAsFixed(2) ?? '?'}").join(", ")})',
      );
    }
    stdout.writeln();
  }
  return 0;
}

Future<int> _cmdExport(ReportStore store, Map<String, String> opts) async {
  final runName = opts['run'];
  if (runName == null) {
    stderr.writeln('--run RUN_NAME is required');
    return 2;
  }
  final report = await store.load(runName);
  if (report == null) {
    stderr.writeln('run not found: $runName');
    return 1;
  }
  final format = opts['format'] ?? 'markdown';
  if (format == 'json') {
    stdout.writeln(
      jsonEncode({
        'runName': report.runName,
        'suite': report.suite.toJson(),
        'startedAt': report.startedAt.toIso8601String(),
        'endedAt': report.endedAt.toIso8601String(),
        'trials': report.trials.map((t) => t.toJson()).toList(),
      }),
    );
    return 0;
  }
  stdout.writeln(_exportMarkdown(report));
  return 0;
}

String _exportMarkdown(PersistedRunReport report) {
  final b = StringBuffer();
  b.writeln('# Run `${report.runName}`');
  b.writeln();
  b.writeln('- Suite: ${report.suite.name} (${report.suite.kind.name})');
  b.writeln('- Started: ${report.startedAt.toIso8601String()}');
  b.writeln('- Trials: ${report.trials.length}');
  b.writeln();
  for (final t in report.trials) {
    b.writeln('## ${t.trial.taskId} #${t.trial.trialIndex}');
    b.writeln(
      '- Status: ${t.trial.status.name}'
      '${t.trial.failureReason == null ? '' : ' (${t.trial.failureReason})'}',
    );
    for (final s in t.scores) {
      b.writeln('- ${_scoreLine(s)}');
    }
    b.writeln();
    final m = t.transcript.metrics;
    b.writeln(
      'Metrics: turns=${m.nTurns} tools=${m.nToolCalls} tokens=${m.nTotalTokens}',
    );
    b.writeln();
  }
  return b.toString();
}
