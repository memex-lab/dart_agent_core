// ignore_for_file: unused_element_parameter
import 'dart:io';

import 'package:dart_agent_core/eval.dart';
import 'package:test/test.dart';

import '_helpers.dart';

class _StubTask implements EvalTask {
  @override
  final String id;
  @override
  final List<Grader> graders;
  @override
  final ReferenceSolution? referenceSolution = null;
  @override
  final int trialsPerRun;
  @override
  final Map<String, String> metadata = const {};
  @override
  final Map<String, dynamic> input = const {};
  @override
  final String description = '';
  @override
  final Duration? timeout = null;

  _StubTask({required this.id, required this.graders, this.trialsPerRun = 10});
}

class _Noop extends CodeGrader {
  @override
  String get name => 'noop';
  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async => const [Assertion(description: 'always', passed: true)];
}

EvalSuite _suite(SuiteKind kind, List<String> taskIds) => EvalSuite(
  name: 'suite_x',
  agentName: 'agent_x',  kind: kind,
  tasks: [
    for (final id in taskIds) _StubTask(id: id, graders: [_Noop()]),
  ],
);

EvalRunReport _runOf({
  required String name,
  required SuiteKind kind,
  required List<String> taskIds,
  required Map<String, double> taskPassRates,
  required DateTime startedAt,
  int trialsPerTask = 10,
}) {
  final trials = <TrialResult>[];
  for (final id in taskIds) {
    final pr = taskPassRates[id] ?? 0.0;
    final passing = (pr * trialsPerTask).round();
    for (var i = 0; i < trialsPerTask; i++) {
      trials.add(
        makeTrialResult(
          runName: name,
          suiteName: 'suite_x',
          taskId: id,
          trialIndex: i,
          scores: [i < passing ? okScore('noop') : failScore('noop')],
          startedAt: startedAt,
        ),
      );
    }
  }
  return EvalRunReport(
    runName: name,
    suite: _suite(kind, taskIds),
    trials: trials,
    startedAt: startedAt,
    endedAt: startedAt.add(const Duration(seconds: 1)),
  );
}

void main() {
  group('SuiteHealthAnalyzer', () {
    late Directory tmp;
    late FileReportStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('health_');
      store = FileReportStore(tmp);
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('throws when no runs are persisted for the suite', () async {
      final analyzer = SuiteHealthAnalyzer(store);
      await expectLater(
        analyzer.analyze(suiteName: 'suite_x'),
        throwsStateError,
      );
    });

    test(
      'flags graduation candidates after N consecutive runs at mature pass rate',
      () async {
        // Persist 5 runs where task "easy" stays at 1.0 and task "hard" at 0.5.
        const consecRuns = 5;
        for (var i = 0; i < consecRuns; i++) {
          final r = _runOf(
            name: 'r$i',
            kind: SuiteKind.capability,
            taskIds: const ['easy', 'hard'],
            taskPassRates: const {'easy': 1.0, 'hard': 0.5},
            startedAt: DateTime(2025, 1, 1).add(Duration(days: i)),
          );
          await store.save(r);
        }
        final analyzer = SuiteHealthAnalyzer(
          store,
          thresholds: const SaturationThresholds(
            matureTaskPassRate: 0.95,
            consecutiveRunsForGraduation: 5,
            minTrialsForBrokenJudgment: 10,
            saturatedSuiteRatio: 0.9,
          ),
        );
        final report = await analyzer.analyze(suiteName: 'suite_x');
        expect(report.analyzedRunCount, 5);
        expect(
          report.graduationCandidates.map((g) => g.taskId),
          containsAll(['easy']),
        );
        expect(
          report.graduationCandidates.map((g) => g.taskId),
          isNot(contains('hard')),
        );
        // Difficulty histogram populated.
        expect(report.difficultyHistogram, isNotEmpty);
      },
    );

    test(
      'detects broken-task candidates: mostly-failing across runs above min',
      () async {
        for (var i = 0; i < 3; i++) {
          await store.save(
            _runOf(
              name: 'r$i',
              kind: SuiteKind.capability,
              taskIds: const ['broken'],
              taskPassRates: const {'broken': 0.0},
              startedAt: DateTime(2025, 1, 1).add(Duration(days: i)),
              trialsPerTask: 10,
            ),
          );
        }
        final analyzer = SuiteHealthAnalyzer(
          store,
          thresholds: const SaturationThresholds(
            brokenTaskPassRate: 0.0,
            minTrialsForBrokenJudgment: 10,
          ),
        );
        final report = await analyzer.analyze(suiteName: 'suite_x');
        expect(report.brokenTaskCandidates, hasLength(1));
        expect(report.brokenTaskCandidates.first.taskId, 'broken');
        expect(report.brokenTaskCandidates.first.passRate, 0.0);
      },
    );

    test('currentlySaturated reflects latest run only', () async {
      // Older run: 1 mature out of 2.
      await store.save(
        _runOf(
          name: 'old',
          kind: SuiteKind.capability,
          taskIds: const ['a', 'b'],
          taskPassRates: const {'a': 1.0, 'b': 0.0},
          startedAt: DateTime(2024),
        ),
      );
      // Newer run: 2/2 mature → saturated.
      await store.save(
        _runOf(
          name: 'new',
          kind: SuiteKind.capability,
          taskIds: const ['a', 'b'],
          taskPassRates: const {'a': 1.0, 'b': 1.0},
          startedAt: DateTime(2026),
        ),
      );
      final analyzer = SuiteHealthAnalyzer(store);
      final report = await analyzer.analyze(suiteName: 'suite_x');
      expect(report.currentSaturationRatio, 1.0);
      expect(report.currentlySaturated, isTrue);
    });

    test(
      'computeSaturationStatus on a single run mirrors EvalRunReport.saturationStatus',
      () async {
        final r = _runOf(
          name: 'r',
          kind: SuiteKind.capability,
          taskIds: const ['a', 'b'],
          taskPassRates: const {'a': 1.0, 'b': 0.0},
          startedAt: DateTime(2025),
        );
        const analyzer = SuiteHealthAnalyzer(_NullStore());
        final sat = analyzer.computeSaturationStatus(r);
        expect(sat.matureTasks, contains('a'));
        expect(sat.saturatedTaskRatio, closeTo(0.5, 1e-9));
      },
    );
  });
}

/// Stub store for the synchronous `computeSaturationStatus` test which
/// doesn't touch persisted state.
class _NullStore implements ReportStore {
  const _NullStore();

  @override
  Future<PersistedRunReport?> load(String runName) async => null;
  @override
  Future<List<RunIndexEntry>> listRecent({
    required String suiteName,
    int limit = 10,
  }) async => const [];
  @override
  Future<List<PersistedRunReport>> loadRecent({
    required String suiteName,
    int limit = 10,
  }) async => const [];
  @override
  Future<List<String>> listRunNames({String? suiteFilter, int? limit}) async =>
      const [];
  @override
  Future<void> save(EvalRunReport report) async {}
}
