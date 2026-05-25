// ignore_for_file: unused_element_parameter
import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/eval.dart';
import 'package:test/test.dart';

class _StubGrader extends CodeGrader {
  @override
  final String name;
  final Map<String, dynamic> config;
  _StubGrader({required this.name, this.config = const {}});

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    return [Assertion(description: '$name with config $config', passed: true)];
  }
}

void _writeJson(File f, Map<String, dynamic> body) {
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(body));
}

Map<String, dynamic> _validTaskJson({
  String id = 't1',
  String agentName = 'agent_x',
  List<Map<String, dynamic>>? graders,
  Map<String, dynamic>? metadata,
}) {
  return {
    'id': id,
    'agent_name': agentName,
    'description': 'desc',
    'input': {'prompt': 'hi'},
    'metadata': ?metadata,
    'graders':
        graders ??
        [
          {
            'name': 'stub',
            'config': {'k': 'v'},
          },
        ],
  };
}

void main() {
  group('GraderRegistry', () {
    test('register + build round-trips with config', () {
      final reg = GraderRegistry();
      reg.register('stub', (cfg) => _StubGrader(name: 'stub', config: cfg));
      final g = reg.build('stub', const {'a': 1});
      expect(g.name, 'stub');
      expect((g as _StubGrader).config, {'a': 1});
    });

    test('build of unregistered name throws', () {
      final reg = GraderRegistry();
      expect(() => reg.build('missing', const {}), throwsA(isA<StateError>()));
    });

    test('contains() and registeredNames', () {
      final reg = GraderRegistry();
      reg.register('a', (_) => _StubGrader(name: 'a'));
      reg.register('b', (_) => _StubGrader(name: 'b'));
      expect(reg.contains('a'), isTrue);
      expect(reg.contains('zzz'), isFalse);
      expect(reg.registeredNames.toList(), ['a', 'b']);
    });

    test('register overwrites prior registration', () {
      final reg = GraderRegistry();
      reg.register('x', (_) => _StubGrader(name: 'x'));
      reg.register('x', (_) => _StubGrader(name: 'x_v2'));
      expect(reg.build('x', const {}).name, 'x_v2');
    });
  });

  group('loadEvalSuiteFromDir — happy path', () {
    late Directory tmp;
    late GraderRegistry reg;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('suite_loader_');
      reg = GraderRegistry()
        ..register('stub', (cfg) => _StubGrader(name: 'stub', config: cfg));
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test(
      'flat layout: tasks/*.json all become tasks in alphabetical order',
      () async {
        _writeJson(File('${tmp.path}/suite.json'), {
          'name': 's',
          'agent_name': 'agent_x',
          'kind': 'mixed',
        });
        _writeJson(
          File('${tmp.path}/tasks/b_task.json'),
          _validTaskJson(id: 'b'),
        );
        _writeJson(
          File('${tmp.path}/tasks/a_task.json'),
          _validTaskJson(id: 'a'),
        );

        final suite = loadEvalSuiteFromDir(tmp, graderRegistry: reg);
        expect(suite.name, 's');
        expect(suite.kind, SuiteKind.mixed);
        // Stable order = alphabetical by path.
        expect(suite.tasks.map((t) => t.id).toList(), ['a', 'b']);
        // suite.validate() should be clean.
        expect(suite.validate(), isEmpty);
      },
    );

    test('nested layout: positive/ + negative/ folders both load', () async {
      _writeJson(File('${tmp.path}/suite.json'), {
        'name': 'capability',
        'agent_name': 'agent_x',
        'kind': 'capability',
      });
      _writeJson(
        File('${tmp.path}/tasks/positive/p1.json'),
        _validTaskJson(id: 'p1'),
      );
      _writeJson(
        File('${tmp.path}/tasks/positive/p2.json'),
        _validTaskJson(id: 'p2'),
      );
      _writeJson(
        File('${tmp.path}/tasks/negative/n1.json'),
        _validTaskJson(id: 'n1'),
      );

      final suite = loadEvalSuiteFromDir(tmp, graderRegistry: reg);
      expect(suite.tasks.map((t) => t.id).toSet(), {'p1', 'p2', 'n1'});
    });

    test(
      'reference_solution + timeout_seconds + trials_per_run decode',
      () async {
        _writeJson(File('${tmp.path}/suite.json'), {
          'name': 's',
          'agent_name': 'agent_x',
          'kind': 'mixed',
          'requireReferenceSolution': true,
        });
        _writeJson(File('${tmp.path}/tasks/t.json'), {
          ..._validTaskJson(),
          'reference_solution': {
            'expected_outcome': {'k': 'v'},
            'source': 'manual',
          },
          'trials_per_run': 3,
          'timeout_seconds': 90,
        });

        final suite = loadEvalSuiteFromDir(tmp, graderRegistry: reg);
        final t = suite.tasks.single;
        expect(t.referenceSolution, isNotNull);
        expect(t.referenceSolution!.expectedOutcome, {'k': 'v'});
        expect(t.referenceSolution!.source, ReferenceSolutionSource.manual);
        expect(t.trialsPerRun, 3);
        expect(t.timeout, const Duration(seconds: 90));
        expect(suite.validate(), isEmpty);
      },
    );

    test('graders are resolved via the registry with their config', () async {
      _writeJson(File('${tmp.path}/suite.json'), {
        'name': 's',
        'agent_name': 'agent_x',
        'kind': 'mixed',
      });
      _writeJson(File('${tmp.path}/tasks/t.json'), {
        ..._validTaskJson(
          graders: [
            {
              'name': 'stub',
              'config': {'a': 1},
            },
            {
              'name': 'stub',
              'config': {'a': 2},
            },
          ],
        ),
      });
      final suite = loadEvalSuiteFromDir(tmp, graderRegistry: reg);
      final graders = suite.tasks.single.graders.cast<_StubGrader>();
      expect(graders, hasLength(2));
      expect(graders[0].config, {'a': 1});
      expect(graders[1].config, {'a': 2});
    });

    test('metadata strings are coerced from non-string values', () async {
      _writeJson(File('${tmp.path}/suite.json'), {
        'name': 's',
        'agent_name': 'agent_x',
        'kind': 'mixed',
      });
      _writeJson(
        File('${tmp.path}/tasks/t.json'),
        _validTaskJson(metadata: const {'difficulty': 1, 'tag': 'easy'}),
      );
      final suite = loadEvalSuiteFromDir(tmp, graderRegistry: reg);
      expect(suite.tasks.single.metadata['difficulty'], '1');
      expect(suite.tasks.single.metadata['tag'], 'easy');
    });
  });

  group('loadEvalSuiteFromDir — error paths', () {
    late Directory tmp;
    late GraderRegistry reg;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('suite_loader_err_');
      reg = GraderRegistry()
        ..register('stub', (_) => _StubGrader(name: 'stub'));
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('non-existent directory throws ArgumentError', () async {
      final missing = Directory('${tmp.path}/does_not_exist');
      expect(
        () => loadEvalSuiteFromDir(missing, graderRegistry: reg),
        throwsArgumentError,
      );
    });

    test('missing suite.json throws StateError', () async {
      Directory('${tmp.path}/tasks').createSync();
      _writeJson(File('${tmp.path}/tasks/t.json'), _validTaskJson());
      expect(
        () => loadEvalSuiteFromDir(tmp, graderRegistry: reg),
        throwsA(isA<StateError>()),
      );
    });

    test('invalid suite kind throws StateError', () async {
      _writeJson(File('${tmp.path}/suite.json'), {
        'name': 's',
        'agent_name': 'agent_x',
        'kind': 'totally_unknown',
      });
      _writeJson(File('${tmp.path}/tasks/t.json'), _validTaskJson());
      expect(
        () => loadEvalSuiteFromDir(tmp, graderRegistry: reg),
        throwsA(isA<StateError>()),
      );
    });

    test('missing agent_name throws StateError', () async {
      _writeJson(File('${tmp.path}/suite.json'), {
        'name': 's',
        'kind': 'mixed',
      });
      _writeJson(File('${tmp.path}/tasks/t.json'), _validTaskJson());
      expect(
        () => loadEvalSuiteFromDir(tmp, graderRegistry: reg),
        throwsA(isA<StateError>()),
      );
    });

    test('missing tasks/ directory throws StateError', () async {
      _writeJson(File('${tmp.path}/suite.json'), {
        'name': 's',
        'agent_name': 'agent_x',
        'kind': 'mixed',
      });
      expect(
        () => loadEvalSuiteFromDir(tmp, graderRegistry: reg),
        throwsA(isA<StateError>()),
      );
    });

    test('empty tasks/ directory throws StateError', () async {
      _writeJson(File('${tmp.path}/suite.json'), {
        'name': 's',
        'agent_name': 'agent_x',
        'kind': 'mixed',
      });
      Directory('${tmp.path}/tasks').createSync();
      expect(
        () => loadEvalSuiteFromDir(tmp, graderRegistry: reg),
        throwsA(isA<StateError>()),
      );
    });

    test('malformed task JSON includes file path in the error', () async {
      _writeJson(File('${tmp.path}/suite.json'), {
        'name': 's',
        'agent_name': 'agent_x',
        'kind': 'mixed',
      });
      File('${tmp.path}/tasks/broken.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{ this is not json');
      try {
        loadEvalSuiteFromDir(tmp, graderRegistry: reg);
        fail('expected throw');
      } on StateError catch (e) {
        expect(e.message, contains('broken.json'));
      }
    });

    test('reference to unregistered grader names known graders', () async {
      _writeJson(File('${tmp.path}/suite.json'), {
        'name': 's',
        'agent_name': 'agent_x',
        'kind': 'mixed',
      });
      _writeJson(File('${tmp.path}/tasks/t.json'), {
        ..._validTaskJson(
          graders: [
            {'name': 'does_not_exist'},
          ],
        ),
      });
      try {
        loadEvalSuiteFromDir(tmp, graderRegistry: reg);
        fail('expected throw');
      } on StateError catch (e) {
        expect(e.message, contains('does_not_exist'));
        expect(e.message, contains('stub'));
      }
    });

    test('missing required field "id" throws StateError', () async {
      _writeJson(File('${tmp.path}/suite.json'), {
        'name': 's',
        'agent_name': 'agent_x',
        'kind': 'mixed',
      });
      final body = _validTaskJson();
      body.remove('id');
      _writeJson(File('${tmp.path}/tasks/t.json'), body);
      expect(
        () => loadEvalSuiteFromDir(tmp, graderRegistry: reg),
        throwsA(isA<StateError>()),
      );
    });

    test('empty graders list throws StateError', () async {
      _writeJson(File('${tmp.path}/suite.json'), {
        'name': 's',
        'agent_name': 'agent_x',
        'kind': 'mixed',
      });
      _writeJson(
        File('${tmp.path}/tasks/t.json'),
        _validTaskJson(graders: const []),
      );
      expect(
        () => loadEvalSuiteFromDir(tmp, graderRegistry: reg),
        throwsA(isA<StateError>()),
      );
    });

    test('requireReferenceSolution=true + missing reference_solution → suite '
        'validation problem', () async {
      _writeJson(File('${tmp.path}/suite.json'), {
        'name': 's',
        'agent_name': 'agent_x',
        'kind': 'capability',
        'requireReferenceSolution': true,
      });
      _writeJson(File('${tmp.path}/tasks/t.json'), _validTaskJson());
      final suite = loadEvalSuiteFromDir(tmp, graderRegistry: reg);
      final problems = suite.validate();
      expect(
        problems.any((p) => p.contains('missing referenceSolution')),
        isTrue,
      );
    });
  });
}
