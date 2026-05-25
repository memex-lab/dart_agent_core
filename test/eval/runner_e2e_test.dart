// ignore_for_file: unused_element_parameter
import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';
import 'package:test/test.dart';

import '_helpers.dart';

// ─── Minimal harness: no real LLM, just decides outcome from task input ─────

class _StubEnvironment implements EvalEnvironment {
  final Map<String, int> prepares = {};
  final Map<String, int> disposes = {};

  @override
  Future<EvalContext> prepare({
    required Trial trial,
    required EvalTask task,
  }) async {
    prepares[trial.taskId] = (prepares[trial.taskId] ?? 0) + 1;
    return EvalContext(
      clock: const SystemEvalClock(),
      llmClient: FakeLLMClient([textReply('unused')]),
      controller: AgentController(),
    );
  }

  @override
  Future<void> dispose(EvalContext context) async {
    disposes['*'] = (disposes['*'] ?? 0) + 1;
    context.controller.close();
  }
}

/// Harness that always succeeds with whatever outcome the task input dictates.
/// `task.input['outcome_value']` is copied into outcome.environmentState.
class _StubHarnessFactory implements AgentHarnessFactory {
  final Duration runDelay;
  _StubHarnessFactory({this.runDelay = Duration.zero});

  @override
  Future<AgentHarnessSession> create({
    required EvalTask task,
    required Trial trial,
    required EvalContext context,
  }) async {
    return _StubSession(task: task, runDelay: runDelay);
  }
}

class _StubSession implements AgentHarnessSession {
  final EvalTask task;
  final Duration runDelay;
  _StubSession({required this.task, required this.runDelay});

  @override
  Future<({Transcript transcript, Outcome outcome})> run() async {
    if (runDelay > Duration.zero) {
      await Future.delayed(runDelay);
    }
    if (task.input['throw'] == true) {
      throw StateError('boom');
    }
    if (task.input['hang'] == true) {
      // Cause a timeout in tests that set a small task timeout.
      await Future.delayed(const Duration(seconds: 30));
    }
    return (
      transcript: emptyTranscript(),
      outcome: Outcome(
        environmentState: {'value': task.input['outcome_value']},
      ),
    );
  }

  @override
  Future<void> dispose() async {}
}

class _ExpectsValueGrader extends CodeGrader {
  final Object? expected;
  final String taskId;
  _ExpectsValueGrader({required this.expected, required this.taskId});

  @override
  String get name => 'expects_value';
  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final actual = outcome.environmentState['value'];
    return [
      Assertion(
        description: 'value matches expected for $taskId',
        passed: actual == expected,
        actual: '$actual',
        expected: '$expected',
      ),
    ];
  }
}

class _Task implements EvalTask {
  @override
  final String id;
  @override
  final List<Grader> graders;
  @override
  final ReferenceSolution? referenceSolution = null;
  @override
  final int trialsPerRun;
  @override
  final Map<String, String> metadata;
  @override
  final Map<String, dynamic> input;
  @override
  final String description = '';
  @override
  final Duration? timeout;

  _Task({
    required this.id,
    required this.input,
    required this.graders,
    this.trialsPerRun = 1,
    this.metadata = const {},
    this.timeout,
  });
}

class _RecordingExporter implements TraceExporter {
  final List<String> events = [];

  @override
  Future<void> onTrialStart(Trial trial, EvalTask task) async {
    events.add('trial_start:${trial.taskId}#${trial.trialIndex}');
  }

  @override
  Future<void> onLLMCall({
    required Trial trial,
    required List<LLMMessage> requestMessages,
    required ModelConfig modelConfig,
    required ModelMessage? response,
    required Duration duration,
    Object? error,
  }) async {
    events.add('llm:${trial.taskId}');
  }

  @override
  Future<void> onToolCall({
    required Trial trial,
    required ToolCallRecord record,
  }) async {
    events.add('tool:${trial.taskId}:${record.toolName}');
  }

  @override
  Future<void> onTrialEnd({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required List<Score> scores,
  }) async {
    events.add('trial_end:${trial.taskId}#${trial.trialIndex}');
  }

  @override
  Future<void> onRunEnd({
    required String runName,
    required String suiteName,
    required Map<String, double> aggregateScores,
  }) async {
    events.add('run_end:$runName:${aggregateScores['task_pass_rate']}');
  }

  @override
  Future<void> dispose() async {
    events.add('dispose');
  }
}

void main() {
  group('EvalRunner end-to-end', () {
    test('runSuite: trials, graders, persisted report, jsonl traces, '
        'composite exporter, recording-store flush', () async {
      final tmp = await Directory.systemTemp.createTemp('e2e_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      final tracesFile = File('${tmp.path}/traces.jsonl');
      final reportsDir = Directory('${tmp.path}/reports')..createSync();
      final jsonlExporter = JsonlTraceExporter(tracesFile);
      final recordingExporter = _RecordingExporter();
      final reportStore = FileReportStore(reportsDir);
      final recordingStore = InMemoryRecordingStore();

      final suite = EvalSuite(
        name: 'e2e_suite',
        agentName: 'agent_x',
        kind: SuiteKind.mixed,
        tasks: [
          _Task(
            id: 'pos',
            input: {'outcome_value': 42},
            graders: [_ExpectsValueGrader(expected: 42, taskId: 'pos')],
            trialsPerRun: 2,
            metadata: const {'failure_bucket': 'simple'},
          ),
          _Task(
            id: 'neg',
            input: {'outcome_value': 'whatever'},
            graders: [_ExpectsValueGrader(expected: 999, taskId: 'neg')],
          ),
          _Task(
            id: 'errored',
            input: {'throw': true},
            graders: [_ExpectsValueGrader(expected: null, taskId: 'errored')],
          ),
        ],
      );

      final runner = EvalRunner(
        environment: _StubEnvironment(),
        harnessFactory: _StubHarnessFactory(),
        exporters: [jsonlExporter, recordingExporter],
        recordingStore: recordingStore,
        reportStore: reportStore,
      );

      final report = await runner.runSuite(
        runName: 'e2e_run_1',
        suite: suite,
        concurrency: 4,
      );

      // Trials = 2 + 1 + 1 = 4. Two pos pass, one neg fails, one errored.
      expect(report.trials, hasLength(4));

      // pos: 2 pass; neg: 0; errored: 0 (because trial.status=errored has
      // no scores from harness — but graders still run, and check value==null
      // which IS true after error → so errored task actually passes its grader.
      // Verify by direct inspection:
      final byTask = report.trialsByTask();
      expect(byTask['pos']!.every((t) => t.allGradersPassed), isTrue);
      expect(byTask['neg']!.every((t) => t.allGradersPassed), isFalse);
      expect(byTask['errored']!.first.trial.status, TrialStatus.errored);

      // Composite exporter delivered all phases to the recording exporter.
      expect(
        recordingExporter.events.where((e) => e.startsWith('trial_start:')),
        hasLength(4),
      );
      expect(
        recordingExporter.events.where((e) => e.startsWith('trial_end:')),
        hasLength(4),
      );
      expect(
        recordingExporter.events.where((e) => e.startsWith('run_end:')),
        hasLength(1),
      );
      expect(recordingExporter.events.last, 'dispose');

      // JSONL trace file produced rows for each trial start/end + run_end.
      final lines = await tracesFile.readAsLines();
      expect(lines.length, greaterThanOrEqualTo(4 + 4 + 1));
      final kinds = lines
          .map((l) => (jsonDecode(l) as Map)['kind'] as String)
          .toSet();
      expect(
        kinds.containsAll({'trial_start', 'trial_end', 'run_end'}),
        isTrue,
      );

      // Persisted report can be reloaded.
      final loaded = await reportStore.load('e2e_run_1');
      expect(loaded, isNotNull);
      expect(loaded!.trials, hasLength(4));

      // recordingStore.flush() was awaited inside runSuite (no exception).
      await recordingStore.flush();
    });

    test('per-task timeout marks the trial timedOut', () async {
      final suite = EvalSuite(
        name: 's',
        agentName: 'agent_x',
        kind: SuiteKind.mixed,
        tasks: [
          _Task(
            id: 'slow',
            input: {'hang': true},
            graders: [_ExpectsValueGrader(expected: null, taskId: 'slow')],
            timeout: const Duration(milliseconds: 100),
          ),
        ],
      );
      final runner = EvalRunner(
        environment: _StubEnvironment(),
        harnessFactory: _StubHarnessFactory(),
      );
      final report = await runner.runSuite(
        runName: 'timeout_run',
        suite: suite,
        concurrency: 1,
      );
      expect(report.trials.first.trial.status, TrialStatus.timedOut);
      expect(report.trials.first.trial.failureReason, contains('timed out'));
    });

    test(
      'runTask convenience executes a one-off task without persisting',
      () async {
        final tmp = await Directory.systemTemp.createTemp('runtask_');
        addTearDown(() async {
          if (await tmp.exists()) await tmp.delete(recursive: true);
        });
        final reportStore = FileReportStore(tmp);
        final runner = EvalRunner(
          environment: _StubEnvironment(),
          harnessFactory: _StubHarnessFactory(),
          reportStore: reportStore,
        );
        final task = _Task(
          id: 'one_off',
          input: {'outcome_value': 1},
          graders: [_ExpectsValueGrader(expected: 1, taskId: 'one_off')],
          trialsPerRun: 1,
        );
        final results = await runner.runTask(
          runName: 'one_off_run',
          task: task,
          agentName: 'stub_agent',
          trialsOverride: 3,
        );
        expect(results, hasLength(3));
        expect(results.every((r) => r.allGradersPassed), isTrue);
        // The run should NOT be persisted to the store.
        expect(await reportStore.load('one_off_run'), isNull);
      },
    );

    test('filter prunes tasks before scheduling', () async {
      final suite = EvalSuite(
        name: 's',
        agentName: 'agent_x',
        kind: SuiteKind.mixed,
        tasks: [
          _Task(
            id: 'a',
            input: {'outcome_value': 1},
            graders: [_ExpectsValueGrader(expected: 1, taskId: 'a')],
          ),
          _Task(
            id: 'b',
            input: {'outcome_value': 2},
            graders: [_ExpectsValueGrader(expected: 2, taskId: 'b')],
          ),
        ],
      );
      final runner = EvalRunner(
        environment: _StubEnvironment(),
        harnessFactory: _StubHarnessFactory(),
      );
      final report = await runner.runSuite(
        runName: 'filter_run',
        suite: suite,
        concurrency: 1,
        filter: (t) => t.id == 'a',
      );
      expect(report.trials, hasLength(1));
      expect(report.trials.first.trial.taskId, 'a');
    });

    test(
      'invalid suite (duplicate ids) throws StateError before running',
      () async {
        final suite = EvalSuite(
          name: 's',
          agentName: 'agent_x',
          kind: SuiteKind.mixed,
          tasks: [
            _Task(
              id: 'dup',
              input: const {},
              graders: [_ExpectsValueGrader(expected: 0, taskId: 'dup')],
            ),
            _Task(
              id: 'dup',
              input: const {},
              graders: [_ExpectsValueGrader(expected: 0, taskId: 'dup')],
            ),
          ],
        );
        final runner = EvalRunner(
          environment: _StubEnvironment(),
          harnessFactory: _StubHarnessFactory(),
        );
        await expectLater(
          runner.runSuite(runName: 'r', suite: suite),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('parseEvalRunArgs', () {
    test('parses the full flag set', () {
      final cfg = parseEvalRunArgs(
        [
          '--run-name',
          'demo',
          '--concurrency',
          '4',
          '--trials-override',
          '5',
          '--mode',
          'record',
          '--filter-agent',
          'card_agent,pkm_agent',
          '--filter-bucket',
          'tool_use',
          '--filter-task-id',
          'a,b,c',
          '--rpm',
          '60',
          '--tpm',
          '120000',
          '--recording-dir',
          '/tmp/rec',
          '--no-langfuse',
          '--langfuse-host',
          'https://lf.local',
        ],
        env: const {'LANGFUSE_HOST': 'env-host'},
      );
      expect(cfg.runName, 'demo');
      expect(cfg.concurrency, 4);
      expect(cfg.trialsOverride, 5);
      expect(cfg.mode, EvalRunMode.record);
      expect(cfg.filter.agents, {'card_agent', 'pkm_agent'});
      expect(cfg.filter.buckets, {'tool_use'});
      expect(cfg.filter.taskIds, {'a', 'b', 'c'});
      expect(cfg.rpm, 60);
      expect(cfg.tpm, 120000);
      expect(cfg.recordingDir, '/tmp/rec');
      expect(cfg.langfuseEnabled, isFalse);
      expect(cfg.langfuseHost, 'https://lf.local');
    });

    test('default run name has timestamp prefix when none provided', () {
      final cfg = parseEvalRunArgs(const []);
      expect(cfg.runName, startsWith('run_'));
      expect(cfg.mode, EvalRunMode.replay);
    });

    test(
      'TaskFilter agent filter is suite-level; bucket / id filters are task-level',
      () {
        final suite = EvalSuite(
          name: 's',
          agentName: 'stub_agent',
          kind: SuiteKind.mixed,
          tasks: [
            _Task(
              id: 't',
              input: const {},
              graders: const [],
              metadata: const {'failure_bucket': 'tool_use'},
            ),
          ],
        );
        final task = suite.tasks.single;

        // Agent filter is checked at the suite level.
        const matching = TaskFilter(agents: {'stub_agent'});
        expect(matching.matchesSuite(suite), isTrue);
        const nonMatching = TaskFilter(agents: {'other_agent'});
        expect(nonMatching.matchesSuite(suite), isFalse);

        // Bucket / taskId filters are task-level.
        const bucketHit = TaskFilter(buckets: {'tool_use'});
        expect(bucketHit.matchesTask(task), isTrue);
        const bucketMiss = TaskFilter(buckets: {'other_bucket'});
        expect(bucketMiss.matchesTask(task), isFalse);

        const idHit = TaskFilter(taskIds: {'t'});
        expect(idHit.matchesTask(task), isTrue);
        const idMiss = TaskFilter(taskIds: {'other'});
        expect(idMiss.matchesTask(task), isFalse);
      },
    );
  });
}
