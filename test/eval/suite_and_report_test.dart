// ignore_for_file: unused_element_parameter
import 'package:dart_agent_core/eval.dart';
import 'package:test/test.dart';

import '_helpers.dart';

class _StubTask implements EvalTask {
  @override
  final String id;
  @override
  final List<Grader> graders;
  @override
  final ReferenceSolution? referenceSolution;
  @override
  final int trialsPerRun;
  @override
  final Map<String, String> metadata;
  @override
  final Map<String, dynamic> input;
  @override
  final String description;
  @override
  final Duration? timeout;

  _StubTask({
    required this.id,
    this.graders = const [],
    this.referenceSolution,
    this.trialsPerRun = 1,
    this.metadata = const {},
    this.input = const {},
    this.description = '',
    this.timeout,
  });
}

class _NoopGrader extends CodeGrader {
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

void main() {
  group('EvalSuite.validate', () {
    test('detects duplicate task ids', () {
      final suite = EvalSuite(
        name: 's',
        agentName: 'agent_x',
        kind: SuiteKind.mixed,
        tasks: [
          _StubTask(id: 'a', graders: [_NoopGrader()]),
          _StubTask(id: 'a', graders: [_NoopGrader()]),
        ],
      );
      final problems = suite.validate();
      expect(problems.any((p) => p.contains('duplicate task id "a"')), isTrue);
    });

    test('detects task without graders', () {
      final suite = EvalSuite(
        name: 's',
        agentName: 'agent_x',
        kind: SuiteKind.mixed,
        tasks: [_StubTask(id: 'a', graders: const [])],
      );
      expect(suite.validate().any((p) => p.contains('no graders')), isTrue);
    });

    test('flags missing reference solution when required', () {
      final suite = EvalSuite(
        name: 's',
        agentName: 'agent_x',
        kind: SuiteKind.capability,
        requireReferenceSolution: true,
        tasks: [
          _StubTask(id: 'a', graders: [_NoopGrader()]),
        ],
      );
      expect(
        suite.validate().any((p) => p.contains('missing referenceSolution')),
        isTrue,
      );
    });

    test('detects trialsPerRun <= 0', () {
      final suite = EvalSuite(
        name: 's',
        agentName: 'agent_x',
        kind: SuiteKind.mixed,
        tasks: [
          _StubTask(id: 'a', graders: [_NoopGrader()], trialsPerRun: 0),
        ],
      );
      expect(
        suite.validate().any((p) => p.contains('trialsPerRun <= 0')),
        isTrue,
      );
    });

    test('valid suite has empty problem list', () {
      final suite = EvalSuite(
        name: 's',
        agentName: 'agent_x',
        kind: SuiteKind.mixed,
        tasks: [
          _StubTask(id: 'a', graders: [_NoopGrader()]),
        ],
      );
      expect(suite.validate(), isEmpty);
    });
  });

  group('EvalRunReport: top-line metrics', () {
    EvalSuite suiteOf(SuiteKind kind) => EvalSuite(
      name: 's',
      agentName: 'agent_x',
      kind: kind,
      tasks: [
        _StubTask(id: 'a', graders: [_NoopGrader()], trialsPerRun: 2),
        _StubTask(id: 'b', graders: [_NoopGrader()], trialsPerRun: 2),
      ],
    );

    test('trialPassRate: empirical pass count / total', () {
      final report = EvalRunReport(
        runName: 'r',
        suite: suiteOf(SuiteKind.mixed),
        trials: [
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'a',
            trialIndex: 0,
            scores: [okScore('noop')],
          ),
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'a',
            trialIndex: 1,
            scores: [failScore('noop')],
          ),
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'b',
            trialIndex: 0,
            scores: [okScore('noop')],
          ),
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'b',
            trialIndex: 1,
            scores: [okScore('noop')],
          ),
        ],
        startedAt: DateTime(2025),
        endedAt: DateTime(2025).add(const Duration(seconds: 1)),
      );
      expect(report.trialPassRate, 0.75);
    });

    test(
      'taskPassRate for capability suites: at least one trial passes per task',
      () {
        final report = EvalRunReport(
          runName: 'r',
          suite: suiteOf(SuiteKind.capability),
          trials: [
            // task a: 1 of 2 pass → counts as passed in capability suite
            makeTrialResult(
              runName: 'r',
              suiteName: 's',
              taskId: 'a',
              trialIndex: 0,
              scores: [okScore('noop')],
            ),
            makeTrialResult(
              runName: 'r',
              suiteName: 's',
              taskId: 'a',
              trialIndex: 1,
              scores: [failScore('noop')],
            ),
            // task b: 0 of 2 pass → fails
            makeTrialResult(
              runName: 'r',
              suiteName: 's',
              taskId: 'b',
              trialIndex: 0,
              scores: [failScore('noop')],
            ),
            makeTrialResult(
              runName: 'r',
              suiteName: 's',
              taskId: 'b',
              trialIndex: 1,
              scores: [failScore('noop')],
            ),
          ],
          startedAt: DateTime(2025),
          endedAt: DateTime(2025),
        );
        expect(report.taskPassRate, 0.5);
      },
    );

    test(
      'taskPassRate for regression suites: every trial must pass per task',
      () {
        final report = EvalRunReport(
          runName: 'r',
          suite: suiteOf(SuiteKind.regression),
          trials: [
            // task a: 1 of 2 pass → fails in regression suite
            makeTrialResult(
              runName: 'r',
              suiteName: 's',
              taskId: 'a',
              trialIndex: 0,
              scores: [okScore('noop')],
            ),
            makeTrialResult(
              runName: 'r',
              suiteName: 's',
              taskId: 'a',
              trialIndex: 1,
              scores: [failScore('noop')],
            ),
            // task b: 2 of 2 pass → passes
            makeTrialResult(
              runName: 'r',
              suiteName: 's',
              taskId: 'b',
              trialIndex: 0,
              scores: [okScore('noop')],
            ),
            makeTrialResult(
              runName: 'r',
              suiteName: 's',
              taskId: 'b',
              trialIndex: 1,
              scores: [okScore('noop')],
            ),
          ],
          startedAt: DateTime(2025),
          endedAt: DateTime(2025),
        );
        expect(report.taskPassRate, 0.5);
      },
    );

    test('graderMeans excludes null scores from averages', () {
      final report = EvalRunReport(
        runName: 'r',
        suite: suiteOf(SuiteKind.mixed),
        trials: [
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'a',
            trialIndex: 0,
            scores: [okScore('quality', value: 1.0), nullScore('judge')],
          ),
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'a',
            trialIndex: 1,
            scores: [okScore('quality', value: 0.5)],
          ),
        ],
        startedAt: DateTime(2025),
        endedAt: DateTime(2025),
      );
      expect(report.graderMeans['quality'], closeTo(0.75, 1e-9));
      expect(report.graderMeans.containsKey('judge'), isFalse);
    });

    test('passAtKByTask + passCaretKByTask compute per-task k-tables', () {
      final report = EvalRunReport(
        runName: 'r',
        suite: suiteOf(SuiteKind.mixed),
        trials: [
          // a: 1/2 pass
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'a',
            trialIndex: 0,
            scores: [okScore('noop')],
          ),
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'a',
            trialIndex: 1,
            scores: [failScore('noop')],
          ),
          // b: 2/2 pass
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'b',
            trialIndex: 0,
            scores: [okScore('noop')],
          ),
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'b',
            trialIndex: 1,
            scores: [okScore('noop')],
          ),
        ],
        startedAt: DateTime(2025),
        endedAt: DateTime(2025),
      );

      final passAt = report.passAtKByTask(ks: const [1, 2]);
      // task a: c=1, n=2 → pass@1 = 1 - C(1,1)/C(2,1) = 0.5; pass@2 = 1 - C(1,2)/C(2,2) = 1 - 0/1 = 1.0
      expect(passAt['a']![1], closeTo(0.5, 1e-9));
      expect(passAt['a']![2], closeTo(1.0, 1e-9));
      // task b: 2/2 → pass@1 = 1.0, pass@2 = 1.0
      expect(passAt['b']![1], closeTo(1.0, 1e-9));
      expect(passAt['b']![2], closeTo(1.0, 1e-9));

      final passCk = report.passCaretKByTask(ks: const [1, 2]);
      // task a: (0.5)^1=0.5; (0.5)^2=0.25
      expect(passCk['a']![1], closeTo(0.5, 1e-9));
      expect(passCk['a']![2], closeTo(0.25, 1e-9));
      // task b: (1.0)^k = 1.0
      expect(passCk['b']![1], 1.0);
      expect(passCk['b']![2], 1.0);
    });

    test('markdown marks metrics with insufficient samples', () {
      final report = EvalRunReport(
        runName: 'r',
        suite: suiteOf(SuiteKind.mixed),
        trials: [
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'a',
            trialIndex: 0,
            scores: [okScore('noop')],
          ),
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'a',
            trialIndex: 1,
            scores: [failScore('noop')],
          ),
        ],
        startedAt: DateTime(2025),
        endedAt: DateTime(2025),
      );

      final markdown = generateMarkdownReport(report, ksToReport: const [5]);

      expect(markdown, contains('| `a` | N/A | 3.1% ⚠️ |'));
      expect(markdown, contains('`pass^k` remains an empirical estimate'));
    });

    test('bucketPassRates groups by failure_bucket', () {
      final report = EvalRunReport(
        runName: 'r',
        suite: suiteOf(SuiteKind.mixed),
        trials: [
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'a',
            trialIndex: 0,
            scores: [okScore('noop')],
          ),
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'b',
            trialIndex: 0,
            scores: [failScore('noop')],
          ),
        ],
        startedAt: DateTime(2025),
        endedAt: DateTime(2025),
      );
      final rates = report.bucketPassRates({'a': 'easy', 'b': 'easy'});
      expect(rates['easy'], 0.5);
    });

    test('saturationStatus picks mature & straggler tasks via thresholds', () {
      // 5 mature + 1 straggler with min trials, both above min threshold
      final trials = <TrialResult>[
        // mature_a: 10/10 pass
        for (var i = 0; i < 10; i++)
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'mature_a',
            trialIndex: i,
            scores: [okScore('noop')],
          ),
        // straggler_a: 0/10 pass
        for (var i = 0; i < 10; i++)
          makeTrialResult(
            runName: 'r',
            suiteName: 's',
            taskId: 'straggler_a',
            trialIndex: i,
            scores: [failScore('noop')],
          ),
      ];
      final suite = EvalSuite(
        name: 's',
        agentName: 'agent_x',
        kind: SuiteKind.capability,
        tasks: [
          _StubTask(id: 'mature_a', graders: [_NoopGrader()], trialsPerRun: 10),
          _StubTask(
            id: 'straggler_a',
            graders: [_NoopGrader()],
            trialsPerRun: 10,
          ),
        ],
      );
      final report = EvalRunReport(
        runName: 'r',
        suite: suite,
        trials: trials,
        startedAt: DateTime(2025),
        endedAt: DateTime(2025),
      );
      final sat = report.saturationStatus(
        thresholds: const SaturationThresholds(
          matureTaskPassRate: 0.95,
          brokenTaskPassRate: 0.0,
          minTrialsForBrokenJudgment: 10,
          saturatedSuiteRatio: 0.9,
        ),
      );
      expect(sat.matureTasks, contains('mature_a'));
      expect(sat.stragglerTasks, contains('straggler_a'));
      expect(sat.saturatedTaskRatio, closeTo(0.5, 1e-9));
      expect(sat.suiteSaturated, isFalse); // 0.5 < 0.9
    });

    test('toMarkdownSummary produces non-empty markdown with key sections', () {
      final report = EvalRunReport(
        runName: 'demo',
        suite: EvalSuite(
          name: 's',
          agentName: 'agent_x',
          kind: SuiteKind.mixed,
          tasks: [
            _StubTask(id: 'a', graders: [_NoopGrader()]),
          ],
        ),
        trials: [
          makeTrialResult(
            runName: 'demo',
            suiteName: 's',
            taskId: 'a',
            trialIndex: 0,
            scores: [failScore('quality', value: 0.0, rationale: 'meh')],
          ),
        ],
        startedAt: DateTime(2025),
        endedAt: DateTime(2025).add(const Duration(seconds: 5)),
      );
      final md = report.toMarkdownSummary();
      expect(md, contains('# Eval Run: `demo`'));
      expect(md, contains('Top-line metrics'));
      expect(md, contains('Failed trials'));
      expect(md, contains('quality'));
    });
  });
}
