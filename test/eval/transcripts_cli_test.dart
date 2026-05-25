import 'dart:async';
import 'dart:convert';
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
  final int trialsPerRun = 1;
  @override
  final Map<String, String> metadata = const {};
  @override
  final Map<String, dynamic> input = const {};
  @override
  final String description = '';
  @override
  final Duration? timeout = null;
  _StubTask({required this.id, required this.graders});
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

EvalSuite _suite(List<String> ids) => EvalSuite(
  name: 's',
  agentName: 'agent_x',  kind: SuiteKind.mixed,
  tasks: [
    for (final id in ids) _StubTask(id: id, graders: [_NoopGrader()]),
  ],
);

EvalRunReport _run({
  required String name,
  required Map<String, double> taskPassRates,
  int trialsPerTask = 2,
  DateTime? startedAt,
}) {
  final ids = taskPassRates.keys.toList();
  final trials = <TrialResult>[];
  for (final id in ids) {
    final pr = taskPassRates[id]!;
    final passing = (pr * trialsPerTask).round();
    for (var i = 0; i < trialsPerTask; i++) {
      trials.add(
        makeTrialResult(
          runName: name,
          suiteName: 's',
          taskId: id,
          trialIndex: i,
          scores: [i < passing ? okScore('noop') : failScore('noop')],
        ),
      );
    }
  }
  final s = startedAt ?? DateTime(2025);
  return EvalRunReport(
    runName: name,
    suite: _suite(ids),
    trials: trials,
    startedAt: s,
    endedAt: s.add(const Duration(seconds: 1)),
  );
}

/// Run the transcript viewer with stdout/stderr captured. Returns the
/// (stdout, stderr, exitCode) tuple.
Future<({String out, String err, int code})> _runViewer(
  List<String> args,
) async {
  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  final code = await runZonedTranscriptViewer(
    args,
    onStdout: (s) => stdoutBuffer.write(s),
    onStderr: (s) => stderrBuffer.write(s),
  );
  return (
    out: stdoutBuffer.toString(),
    err: stderrBuffer.toString(),
    code: code,
  );
}

/// We don't want stdout to actually print during tests; the viewer prints
/// to the global stdout. We capture by overriding. The viewer uses
/// dart:io stdout/stderr directly so we use IOOverrides.
Future<int> runZonedTranscriptViewer(
  List<String> args, {
  required void Function(String) onStdout,
  required void Function(String) onStderr,
}) async {
  return IOOverrides.runZoned<Future<int>>(
    () => runTranscriptViewer(args),
    stdout: () => _CapturingStdout(onStdout),
    stderr: () => _CapturingStdout(onStderr),
  );
}

/// Minimal Stdout wrapper that delegates writes to a callback.
class _CapturingStdout implements Stdout {
  final void Function(String) sink;
  _CapturingStdout(this.sink);

  @override
  void writeln([Object? object = '']) => sink('${object ?? ''}\n');

  @override
  void write(Object? object) => sink('${object ?? ''}');

  @override
  void writeAll(Iterable objects, [String separator = '']) {
    sink(objects.map((e) => '$e').join(separator));
  }

  @override
  void writeCharCode(int charCode) => sink(String.fromCharCode(charCode));

  @override
  Future close() async {}
  @override
  Future get done => Future.value();
  @override
  Future flush() async {}

  @override
  Encoding encoding = utf8;
  @override
  bool get hasTerminal => false;
  @override
  IOSink get nonBlocking => throw UnimplementedError();
  @override
  bool get supportsAnsiEscapes => false;
  @override
  int get terminalColumns => 80;
  @override
  int get terminalLines => 24;
  @override
  void add(List<int> data) => sink(utf8.decode(data));
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future addStream(Stream<List<int>> stream) async {}
  Future<dynamic> any(bool Function(int) test) => throw UnimplementedError();
  Stream<List<int>> asBroadcastStream({
    void Function(StreamSubscription<List<int>>)? onListen,
    void Function(StreamSubscription<List<int>>)? onCancel,
  }) => throw UnimplementedError();
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('runTranscriptViewer', () {
    late Directory tmp;
    late FileReportStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('viewer_');
      store = FileReportStore(tmp);

      // Persist two runs so list / show / diff / export all have data.
      await store.save(
        _run(
          name: 'main',
          taskPassRates: const {'task_x': 1.0, 'task_y': 0.5},
          startedAt: DateTime(2024),
        ),
      );
      await store.save(
        _run(
          name: 'pr',
          taskPassRates: const {'task_x': 0.0, 'task_y': 1.0},
          startedAt: DateTime(2026),
        ),
      );
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('list (no filter) prints all run names newest-first', () async {
      final r = await _runViewer(['list', '--store', tmp.path]);
      expect(r.code, 0);
      // Most recent (`pr`) first.
      final lines = r.out.trim().split('\n');
      expect(lines, containsAllInOrder(['pr', 'main']));
    });

    test(
      'show prints scores, outcome, transcript metrics for a trial',
      () async {
        final r = await _runViewer([
          'show',
          '--store',
          tmp.path,
          '--trial',
          'main/task_x#0',
        ]);
        expect(r.code, 0);
        expect(r.out, contains('Trial: main / task_x #0'));
        expect(r.out, contains('Status: passed'));
        expect(r.out, contains('Scores'));
        expect(r.out, contains('Outcome'));
        expect(r.out, contains('Transcript metrics'));
      },
    );

    test('show with --format json emits parseable JSON', () async {
      final r = await _runViewer([
        'show',
        '--store',
        tmp.path,
        '--trial',
        'main/task_x#0',
        '--format',
        'json',
      ]);
      expect(r.code, 0);
      final j = jsonDecode(r.out.trim()) as Map<String, dynamic>;
      expect(j['trial'], isA<Map>());
      expect(j['scores'], isA<List>());
    });

    test('diff prints both runs side-by-side for a task', () async {
      final r = await _runViewer([
        'diff',
        '--store',
        tmp.path,
        '--task',
        'task_x',
        '--runs',
        'main,pr',
      ]);
      expect(r.code, 0);
      expect(r.out, contains('main'));
      expect(r.out, contains('pr'));
      expect(r.out, contains('PASS'));
      expect(r.out, contains('FAIL'));
    });

    test('export markdown contains task ids and per-trial scores', () async {
      final r = await _runViewer([
        'export',
        '--store',
        tmp.path,
        '--run',
        'main',
      ]);
      expect(r.code, 0);
      expect(r.out, contains('# Run `main`'));
      expect(r.out, contains('task_x'));
      expect(r.out, contains('task_y'));
    });

    test('unknown command exits with code 2', () async {
      final r = await _runViewer(['bogus']);
      expect(r.code, 2);
      expect(r.err, contains('unknown command'));
    });
  });
}
