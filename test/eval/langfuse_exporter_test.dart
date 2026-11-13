import 'dart:async';
import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import '_helpers.dart';

class _Call {
  final String path;
  final Object? body;
  final String? ingestionVersion;

  _Call(this.path, this.body, this.ingestionVersion);
}

/// Captures Langfuse POSTs. Drives [Dio] via a custom [HttpClientAdapter]
/// so no actual network IO happens.
class _CapturingAdapter implements HttpClientAdapter {
  final List<_Call> calls = [];
  final List<int> responseCodes;
  int callIndex = 0;

  _CapturingAdapter({this.responseCodes = const [200]});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    final path = options.uri.path;
    expect(
      path.endsWith('/api/public/otel/v1/traces') ||
          path.endsWith('/api/public/scores'),
      isTrue,
      reason: path,
    );
    expect(options.headers['Authorization'], startsWith('Basic '));
    final headers = {
      for (final entry in options.headers.entries)
        entry.key.toLowerCase(): entry.value,
    };
    if (path.endsWith('/api/public/otel/v1/traces')) {
      expect(headers['x-langfuse-ingestion-version'], '4');
    }

    final raw = options.data is String
        ? options.data as String
        : jsonEncode(options.data);
    calls.add(
      _Call(
        path,
        jsonDecode(raw),
        headers['x-langfuse-ingestion-version']?.toString(),
      ),
    );

    final code = responseCodes[callIndex.clamp(0, responseCodes.length - 1)];
    callIndex++;
    return ResponseBody.fromString(
      '{}',
      code,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

List<Map<String, dynamic>> _spans(List<_Call> calls) {
  final spans = <Map<String, dynamic>>[];
  for (final call in calls) {
    if (!call.path.endsWith('/api/public/otel/v1/traces')) continue;
    final body = call.body as Map<String, dynamic>;
    final resourceSpans = body['resourceSpans'] as List;
    final scopeSpans = (resourceSpans.single as Map)['scopeSpans'] as List;
    spans.addAll(
      ((scopeSpans.single as Map)['spans'] as List)
          .cast<Map<String, dynamic>>(),
    );
  }
  return spans;
}

List<Map<String, dynamic>> _scores(List<_Call> calls) {
  final scores = <Map<String, dynamic>>[];
  for (final call in calls) {
    if (!call.path.endsWith('/api/public/scores')) continue;
    scores.addAll((call.body as List).cast<Map<String, dynamic>>());
  }
  return scores;
}

String? _attr(Map<String, dynamic> span, String key) {
  for (final attribute in span['attributes'] as List) {
    final item = attribute as Map;
    if (item['key'] == key) {
      final value = item['value'] as Map;
      return value['stringValue'] as String?;
    }
  }
  return null;
}

LangfuseConfig _testConfig({int flushAt = 50, Duration? interval}) =>
    LangfuseConfig(
      host: 'https://example.invalid',
      publicKey: 'pk-test',
      secretKey: 'sk-test',
      environment: 'test',
      flushAt: flushAt,
      flushInterval: interval ?? const Duration(milliseconds: 50),
      maxRetries: 2,
      requestTimeout: const Duration(seconds: 1),
    );

LangfuseTraceExporter _exporter(_CapturingAdapter adapter, LangfuseConfig cfg) {
  final dio = Dio(
    BaseOptions(
      headers: {
        'Content-Type': 'application/json',
        'Authorization':
            'Basic ${base64.encode(utf8.encode('${cfg.publicKey}:${cfg.secretKey}'))}',
      },
      validateStatus: (_) => true,
    ),
  );
  dio.httpClientAdapter = adapter;
  return LangfuseTraceExporter(cfg, client: LangfuseClient(cfg, dio: dio));
}

class _StubTask implements EvalTask {
  @override
  final String id;
  @override
  final String description;
  @override
  final Map<String, dynamic> input;
  @override
  final Map<String, String> metadata;
  @override
  final List<Grader> graders;
  @override
  final ReferenceSolution? referenceSolution;
  @override
  final int trialsPerRun;
  @override
  final Duration? timeout;

  _StubTask(this.id)
    : description = 'task $id',
      input = {'q': 'hello'},
      metadata = const {'failure_bucket': 'simple'},
      graders = const [],
      referenceSolution = null,
      trialsPerRun = 1,
      timeout = null;
}

void main() {
  group('LangfuseConfig', () {
    test('fromEnv requires publicKey + secretKey', () {
      expect(() => LangfuseConfig.fromEnv({}), throwsA(isA<StateError>()));
      final cfg = LangfuseConfig.fromEnv({
        'LANGFUSE_PUBLIC_KEY': 'pk',
        'LANGFUSE_SECRET_KEY': 'sk',
        'LANGFUSE_HOST': 'https://lf.example.com/',
      });
      expect(cfg.publicKey, 'pk');
      expect(cfg.secretKey, 'sk');
      expect(cfg.host, 'https://lf.example.com/');
      expect(
        cfg.otelTracesUrl,
        'https://lf.example.com/api/public/otel/v1/traces',
      );
      expect(cfg.scoresUrl, 'https://lf.example.com/api/public/scores');
    });
  });

  group('LangfuseTraceExporter', () {
    test('exports one root span, child spans, and numeric scores', () async {
      final adapter = _CapturingAdapter();
      final cfg = _testConfig(flushAt: 100); // never auto-flush by size
      final exporter = _exporter(adapter, cfg);

      final trial = makeTrial(
        runName: 'r1',
        suiteName: 'suite_a',
        taskId: 'task_x',
      );
      await exporter.onTrialStart(trial, _StubTask('task_x'));
      await exporter.onLLMCall(
        trial: trial,
        requestMessages: [SystemMessage('hi'), UserMessage.text('q')],
        modelConfig: ModelConfig(model: 'gpt-fake', temperature: 0.5),
        response: textReply('answer'),
        duration: const Duration(milliseconds: 120),
      );
      final tcStart = DateTime(2025, 1, 1);
      await exporter.onToolCall(
        trial: trial,
        record: ToolCallRecord(
          callId: 'c1',
          toolName: 'add',
          arguments: {'a': 1, 'b': 2},
          startedAt: tcStart,
          endedAt: tcStart.add(const Duration(milliseconds: 5)),
        ),
      );
      await exporter.onTrialEnd(
        trial: trial,
        transcript: emptyTranscript(),
        outcome: const Outcome(environmentState: {'answer': '3'}),
        scores: [
          okScore('correctness', value: 1.0),
          failScore('citation', value: 0.5, rationale: 'missing source'),
          nullScore('skipped'),
        ],
      );
      await exporter.dispose();

      final spans = _spans(adapter.calls);
      final roots = spans.where((s) => s['parentSpanId'] == null).toList();
      final generations = spans
          .where((s) => _attr(s, 'langfuse.observation.type') == 'generation')
          .toList();
      final tools = spans
          .where((s) => _attr(s, 'langfuse.observation.type') == 'tool')
          .toList();
      expect(roots, hasLength(1));
      expect(generations, hasLength(1));
      expect(tools, hasLength(1));

      final root = roots.single;
      final traceId = root['traceId'];
      expect(spans.map((s) => s['traceId']).toSet(), {traceId});
      expect(generations.single['parentSpanId'], root['spanId']);
      expect(tools.single['parentSpanId'], root['spanId']);
      expect(_attr(root, 'langfuse.user.id'), 'r1');
      expect(_attr(root, 'langfuse.session.id'), 'suite_a');
      final rootInput =
          jsonDecode(_attr(root, 'langfuse.observation.input')!) as Map;
      expect(rootInput['taskId'], 'task_x');
      final rootOutput =
          jsonDecode(_attr(root, 'langfuse.observation.output')!) as Map;
      expect((rootOutput['environmentState'] as Map)['answer'], '3');

      final gen = generations.single;
      expect(_attr(gen, 'langfuse.observation.model.name'), 'gpt-fake');
      final usage =
          jsonDecode(_attr(gen, 'langfuse.observation.usage_details')!) as Map;
      expect(usage['total'], 15);
      final parameters =
          jsonDecode(_attr(gen, 'langfuse.observation.model.parameters')!)
              as Map;
      expect(parameters['temperature'], 0.5);
      expect(
        _attr(gen, 'langfuse.trace.name'),
        _attr(root, 'langfuse.trace.name'),
      );

      expect(tools.single['name'], 'tool.add');

      final scores = _scores(adapter.calls);
      expect(scores, hasLength(2));
      for (final score in scores) {
        expect(score['dataType'], 'NUMERIC');
        expect(score['traceId'], traceId);
        expect(score['observationId'], root['spanId']);
        expect(score['environment'], 'test');
      }
      expect(scores.map((s) => s['name']).toSet(), {'correctness', 'citation'});
    });

    test('onRunEnd writes a summary trace + per-metric score', () async {
      final adapter = _CapturingAdapter();
      final cfg = _testConfig(flushAt: 100);
      final exporter = _exporter(adapter, cfg);

      await exporter.onRunEnd(
        runName: 'pr-42',
        suiteName: 'suite_a',
        aggregateScores: {'pass@1': 0.8, 'mean_correctness': 0.9},
      );
      await exporter.dispose();

      final spans = _spans(adapter.calls);
      final scores = _scores(adapter.calls);
      expect(spans, hasLength(1));
      expect(spans.single['name'], 'run-summary:suite_a');
      expect(_attr(spans.single, 'langfuse.user.id'), 'pr-42');
      expect(scores, hasLength(2));
      for (final score in scores) {
        expect(score['traceId'], spans.single['traceId']);
        expect(score['observationId'], spans.single['spanId']);
      }
    });

    test('flushAt triggers immediate flush', () async {
      final adapter = _CapturingAdapter();
      final cfg = _testConfig(flushAt: 2);
      final exporter = _exporter(adapter, cfg);

      // Each onToolCall enqueues exactly one event.
      final t = DateTime(2025);
      final trial = makeTrial(runName: 'r', suiteName: 's', taskId: 't');
      await exporter.onToolCall(
        trial: trial,
        record: ToolCallRecord(
          callId: 'c1',
          toolName: 'a',
          arguments: const {},
          startedAt: t,
          endedAt: t,
        ),
      );
      await exporter.onToolCall(
        trial: trial,
        record: ToolCallRecord(
          callId: 'c2',
          toolName: 'b',
          arguments: const {},
          startedAt: t,
          endedAt: t,
        ),
      );
      // After 2 events queued (== flushAt), flush is scheduled. Pump
      // microtasks so the unawaited flush runs.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(adapter.calls, hasLength(1));
      expect(_spans(adapter.calls), hasLength(2));
      await exporter.dispose();
    });

    test('5xx triggers retry with backoff, then succeeds', () async {
      final adapter = _CapturingAdapter(responseCodes: [503, 200]);
      final cfg = LangfuseConfig(
        host: 'https://example.invalid',
        publicKey: 'pk',
        secretKey: 'sk',
        flushAt: 100,
        flushInterval: const Duration(milliseconds: 20),
        maxRetries: 3,
        requestTimeout: const Duration(seconds: 1),
      );
      final exporter = _exporter(adapter, cfg);

      await exporter.onRunEnd(
        runName: 'r',
        suiteName: 's',
        aggregateScores: {'p1': 1.0},
      );
      await exporter.dispose();
      // 503 then 200 for the trace, then 200 for the score.
      expect(adapter.callIndex, 3);
      expect(
        adapter.calls.where(
          (c) => c.path.endsWith('/api/public/otel/v1/traces'),
        ),
        hasLength(2),
      );
    });

    test('4xx is fatal — no retry', () async {
      final adapter = _CapturingAdapter(responseCodes: [400, 200]);
      final cfg = LangfuseConfig(
        host: 'https://example.invalid',
        publicKey: 'pk',
        secretKey: 'sk',
        flushAt: 100,
        flushInterval: const Duration(milliseconds: 20),
        maxRetries: 3,
        requestTimeout: const Duration(seconds: 1),
      );
      final exporter = _exporter(adapter, cfg);

      await exporter.onRunEnd(
        runName: 'r',
        suiteName: 's',
        aggregateScores: {'p1': 1.0},
      );
      await exporter.dispose();
      expect(adapter.callIndex, 1); // no retry on 4xx
    });

    test('posts one score as a JSON array and accepts 202', () async {
      final adapter = _CapturingAdapter(responseCodes: [200, 202]);
      final cfg = _testConfig(flushAt: 100);
      final exporter = _exporter(adapter, cfg);

      await exporter.onRunEnd(
        runName: 'r',
        suiteName: 's',
        aggregateScores: {'pass@1': 1.0},
      );
      await exporter.dispose();

      final scoreCall = adapter.calls.singleWhere(
        (call) => call.path.endsWith('/api/public/scores'),
      );
      expect(scoreCall.body, isA<List<dynamic>>());
      expect(scoreCall.body, hasLength(1));
      expect(adapter.callIndex, 2);
    });

    test('shutdown is idempotent and silently drops further events', () async {
      final adapter = _CapturingAdapter();
      final exporter = _exporter(adapter, _testConfig(flushAt: 100));
      await exporter.dispose();
      // After dispose, events should be dropped without error.
      await exporter.onRunEnd(
        runName: 'late',
        suiteName: 's',
        aggregateScores: {'p1': 1.0},
      );
      await exporter.dispose();
      expect(adapter.calls, isEmpty);
    });
  });
}
