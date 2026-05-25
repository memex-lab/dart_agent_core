import 'dart:async';
import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// Captures every POST hit on `/api/public/ingestion`. Drives [Dio] via a
/// custom [HttpClientAdapter] so no actual network IO happens.
class _CapturingAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> bodies = [];
  final List<int> responseCodes;
  int callIndex = 0;

  _CapturingAdapter({this.responseCodes = const [200]});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    expect(options.uri.path.endsWith('/api/public/ingestion'), isTrue);
    expect(options.headers['Authorization'], startsWith('Basic '));

    final raw = options.data is String
        ? options.data as String
        : jsonEncode(options.data);
    bodies.add(jsonDecode(raw) as Map<String, dynamic>);

    final code = responseCodes[callIndex.clamp(0, responseCodes.length - 1)];
    callIndex++;
    return ResponseBody.fromString(
      '{"successes":[],"errors":[]}',
      code,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
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
      expect(cfg.ingestionUrl, 'https://lf.example.com/api/public/ingestion');
    });
  });

  group('LangfuseTraceExporter', () {
    test(
      'emits trace-create / generation-create / span-create / score-create',
      () async {
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

        // Collect every event across batches
        final events = adapter.bodies
            .expand<Map<String, dynamic>>(
              (b) => (b['batch'] as List).cast<Map<String, dynamic>>(),
            )
            .toList();
        final byType = <String, List<Map<String, dynamic>>>{};
        for (final e in events) {
          byType.putIfAbsent(e['type'] as String, () => []).add(e);
        }

        // 2 trace-create (start + end-merge), 1 gen, 1 span, 2 numeric scores
        expect(byType['trace-create'], hasLength(2));
        expect(byType['generation-create'], hasLength(1));
        expect(byType['span-create'], hasLength(1));
        expect(byType['score-create'], hasLength(2));

        // Trace ids match between start + end (server-side merge).
        final traceIds = byType['trace-create']!
            .map((e) => (e['body'] as Map)['id'])
            .toSet();
        expect(traceIds, hasLength(1));

        final gen =
            byType['generation-create']!.single['body'] as Map<String, dynamic>;
        expect(gen['model'], 'gpt-fake');
        expect(gen['traceId'], traceIds.single);
        expect(gen['usage']['total'], 15);
        expect((gen['modelParameters'] as Map)['temperature'], 0.5);

        final span =
            byType['span-create']!.single['body'] as Map<String, dynamic>;
        expect(span['name'], 'tool.add');
        expect(span['traceId'], traceIds.single);

        // Scores: correct dataType + traceId, null score skipped.
        for (final s in byType['score-create']!) {
          final body = s['body'] as Map<String, dynamic>;
          expect(body['dataType'], 'NUMERIC');
          expect(body['traceId'], traceIds.single);
          expect(body['environment'], 'test');
        }
        final scoreNames = byType['score-create']!
            .map((e) => (e['body'] as Map)['name'])
            .toSet();
        expect(scoreNames, {'correctness', 'citation'});
      },
    );

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

      final events = adapter.bodies
          .expand<Map<String, dynamic>>(
            (b) => (b['batch'] as List).cast<Map<String, dynamic>>(),
          )
          .toList();
      final traces = events.where((e) => e['type'] == 'trace-create').toList();
      final scores = events.where((e) => e['type'] == 'score-create').toList();
      expect(traces, hasLength(1));
      expect((traces.single['body'] as Map)['name'], 'run-summary:suite_a');
      expect((traces.single['body'] as Map)['userId'], 'pr-42');
      expect(scores, hasLength(2));
      final summaryTraceId = (traces.single['body'] as Map)['id'];
      for (final s in scores) {
        expect((s['body'] as Map)['traceId'], summaryTraceId);
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
      expect(adapter.bodies, hasLength(1));
      expect((adapter.bodies.single['batch'] as List).length, 2);
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
      // 503 then 200 → adapter saw 2 calls
      expect(adapter.callIndex, 2);
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
      // Only the very first dispose flushed (which had nothing to flush).
      // Second batch should NOT have been sent.
      final batches = adapter.bodies;
      // There may have been one empty flush attempt; ensure no late
      // events leaked through.
      for (final b in batches) {
        final batch = b['batch'] as List;
        for (final e in batch) {
          final body = (e as Map)['body'] as Map;
          expect(body['userId'] != 'late', isTrue);
        }
      }
    });
  });
}
