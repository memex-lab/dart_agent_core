import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../core/eval_run_report.dart';
import '../core/eval_suite.dart';
import '../core/outcome.dart';
import '../core/transcript.dart';
import '../core/trial.dart';
import '../core/trial_result.dart';
import '../graders/score.dart';

final _logger = Logger('ReportStore');

/// 当从持久化 store 加载历史 run 时返回的"快照"。
/// trials 完整保留，但 [suite] 字段是 [SuiteSnapshot]——历史 run 中的真实
/// EvalSuite 实例（含 grader / referenceSolution 等运行时对象）已经不可
/// 重建。跨 run 分析（saturation / graduation / diff）只读元数据，够用。
class PersistedRunReport {
  final String runName;
  final SuiteSnapshot suite;
  final List<TrialResult> trials;
  final DateTime startedAt;
  final DateTime endedAt;

  const PersistedRunReport({
    required this.runName,
    required this.suite,
    required this.trials,
    required this.startedAt,
    required this.endedAt,
  });

  Duration get duration => endedAt.difference(startedAt);

  Map<String, List<TrialResult>> trialsByTask() {
    final out = <String, List<TrialResult>>{};
    for (final t in trials) {
      out.putIfAbsent(t.trial.taskId, () => []).add(t);
    }
    return out;
  }
}

/// Suite 元数据的不可执行快照。只保留分析需要的字段。
class SuiteSnapshot {
  final String name;
  final SuiteKind kind;
  final List<String> taskIds;
  final double taskPassThreshold;
  final bool requireReferenceSolution;

  const SuiteSnapshot({
    required this.name,
    required this.kind,
    required this.taskIds,
    required this.taskPassThreshold,
    required this.requireReferenceSolution,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': kind.name,
    'taskIds': taskIds,
    'taskPassThreshold': taskPassThreshold,
    'requireReferenceSolution': requireReferenceSolution,
  };

  factory SuiteSnapshot.fromJson(Map<String, dynamic> json) {
    return SuiteSnapshot(
      name: json['name'] as String,
      kind: SuiteKind.values.firstWhere((k) => k.name == json['kind']),
      taskIds: ((json['taskIds'] as List?) ?? const []).cast<String>(),
      taskPassThreshold: (json['taskPassThreshold'] as num?)?.toDouble() ?? 1.0,
      requireReferenceSolution:
          json['requireReferenceSolution'] as bool? ?? false,
    );
  }

  factory SuiteSnapshot.from(EvalSuite suite) => SuiteSnapshot(
    name: suite.name,
    kind: suite.kind,
    taskIds: suite.tasks.map((t) => t.id).toList(),
    taskPassThreshold: suite.taskPassThreshold,
    requireReferenceSolution: suite.requireReferenceSolution,
  );
}

/// 索引文件中一行的轻量元数据。
class RunIndexEntry {
  final String runName;
  final String suiteName;
  final SuiteKind suiteKind;
  final DateTime startedAt;
  final DateTime endedAt;
  final double taskPassRate;
  final double trialPassRate;
  final int numTrials;

  const RunIndexEntry({
    required this.runName,
    required this.suiteName,
    required this.suiteKind,
    required this.startedAt,
    required this.endedAt,
    required this.taskPassRate,
    required this.trialPassRate,
    required this.numTrials,
  });

  Map<String, dynamic> toJson() => {
    'runName': runName,
    'suiteName': suiteName,
    'suiteKind': suiteKind.name,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
    'taskPassRate': taskPassRate,
    'trialPassRate': trialPassRate,
    'numTrials': numTrials,
  };

  factory RunIndexEntry.fromJson(Map<String, dynamic> json) {
    return RunIndexEntry(
      runName: json['runName'] as String,
      suiteName: json['suiteName'] as String,
      suiteKind: SuiteKind.values.firstWhere(
        (k) => k.name == json['suiteKind'],
      ),
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: DateTime.parse(json['endedAt'] as String),
      taskPassRate: (json['taskPassRate'] as num).toDouble(),
      trialPassRate: (json['trialPassRate'] as num).toDouble(),
      numTrials: json['numTrials'] as int,
    );
  }
}

/// 持久化历史 run report。append-only。
abstract class ReportStore {
  Future<void> save(EvalRunReport report);

  Future<PersistedRunReport?> load(String runName);

  /// 列出某 suite 最近 N 次的索引条目（轻量），按时间倒序。
  Future<List<RunIndexEntry>> listRecent({
    required String suiteName,
    int limit = 10,
  });

  /// 加载某 suite 最近 N 次完整快照，按时间倒序。
  Future<List<PersistedRunReport>> loadRecent({
    required String suiteName,
    int limit = 10,
  });

  Future<List<String>> listRunNames({String? suiteFilter, int? limit});
}

/// 文件系统实现。
///
/// 布局：
/// ```
/// rootDir/
///   index.jsonl         # 每行一个 run 索引
///   reports/
///     {safe_runName}.json
/// ```
class FileReportStore implements ReportStore {
  final Directory rootDir;
  final File indexFile;
  final Directory reportsDir;

  FileReportStore(this.rootDir)
    : indexFile = File('${rootDir.path}/index.jsonl'),
      reportsDir = Directory('${rootDir.path}/reports') {
    rootDir.createSync(recursive: true);
    reportsDir.createSync(recursive: true);
    if (!indexFile.existsSync()) indexFile.createSync();
  }

  static String _safeName(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');

  File _reportFile(String runName) =>
      File('${reportsDir.path}/${_safeName(runName)}.json');

  @override
  Future<void> save(EvalRunReport report) async {
    final entry = RunIndexEntry(
      runName: report.runName,
      suiteName: report.suite.name,
      suiteKind: report.suite.kind,
      startedAt: report.startedAt,
      endedAt: report.endedAt,
      taskPassRate: report.taskPassRate,
      trialPassRate: report.trialPassRate,
      numTrials: report.trials.length,
    );
    await indexFile.writeAsString(
      '${jsonEncode(entry.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );

    final body = {
      'runName': report.runName,
      'suite': SuiteSnapshot.from(report.suite).toJson(),
      'startedAt': report.startedAt.toIso8601String(),
      'endedAt': report.endedAt.toIso8601String(),
      'trials': report.trials.map((t) => t.toJson()).toList(),
    };
    await _reportFile(
      report.runName,
    ).writeAsString(jsonEncode(body), flush: true);
  }

  @override
  Future<PersistedRunReport?> load(String runName) async {
    final f = _reportFile(runName);
    if (!await f.exists()) return null;
    final body = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    return _decode(body);
  }

  @override
  Future<List<RunIndexEntry>> listRecent({
    required String suiteName,
    int limit = 10,
  }) async {
    final entries = await _readIndex();
    final filtered = entries.where((e) => e.suiteName == suiteName).toList();
    filtered.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return filtered.take(limit).toList();
  }

  @override
  Future<List<PersistedRunReport>> loadRecent({
    required String suiteName,
    int limit = 10,
  }) async {
    final indices = await listRecent(suiteName: suiteName, limit: limit);
    final out = <PersistedRunReport>[];
    for (final idx in indices) {
      final r = await load(idx.runName);
      if (r != null) out.add(r);
    }
    return out;
  }

  @override
  Future<List<String>> listRunNames({String? suiteFilter, int? limit}) async {
    final entries = await _readIndex();
    var filtered = suiteFilter == null
        ? entries
        : entries.where((e) => e.suiteName == suiteFilter).toList();
    filtered.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (limit != null) filtered = filtered.take(limit).toList();
    return filtered.map((e) => e.runName).toList();
  }

  TrialResult _trialResultFromJson(Map<String, dynamic> json) {
    return TrialResult(
      trial: Trial.fromJson(json['trial'] as Map<String, dynamic>),
      transcript: Transcript.fromJson(
        json['transcript'] as Map<String, dynamic>,
      ),
      outcome: Outcome.fromJson(json['outcome'] as Map<String, dynamic>),
      scores: ((json['scores'] as List?) ?? const [])
          .map((s) => Score.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }

  PersistedRunReport _decode(Map<String, dynamic> body) {
    return PersistedRunReport(
      runName: body['runName'] as String,
      suite: SuiteSnapshot.fromJson(body['suite'] as Map<String, dynamic>),
      startedAt: DateTime.parse(body['startedAt'] as String),
      endedAt: DateTime.parse(body['endedAt'] as String),
      trials: (body['trials'] as List)
          .map((t) => _trialResultFromJson(t as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<List<RunIndexEntry>> _readIndex() async {
    if (!await indexFile.exists()) return const [];
    final entries = <RunIndexEntry>[];
    final lines = await indexFile.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        entries.add(
          RunIndexEntry.fromJson(jsonDecode(line) as Map<String, dynamic>),
        );
      } catch (e, st) {
        _logger.warning('skipping malformed index line', e, st);
      }
    }
    return entries;
  }
}
