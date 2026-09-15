import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  final modelConfig = ModelConfig(model: 'test-model');

  final isCancelDioException = isA<DioException>().having(
    CancelToken.isCancel,
    'CancelToken.isCancel',
    isTrue,
  );

  group('LLM clients do not retry cancelled Dio requests', () {
    test('OpenAI generate: zero retries, cancel DioException', () async {
      final adapter = _CancelAdapter();
      final client = OpenAIClient(
        apiKey: 'k',
        client: Dio()..httpClientAdapter = adapter,
        maxRetries: 3,
        initialRetryDelayMs: 200,
      );

      final sw = Stopwatch()..start();
      await expectLater(
        client.generate([UserMessage.text('hi')], modelConfig: modelConfig),
        throwsA(isCancelDioException),
      );
      sw.stop();

      expect(adapter.fetches, 1);
      expect(sw.elapsedMilliseconds, lessThan(150));
    });

    test('OpenAI stream: zero retries, cancel DioException', () async {
      final adapter = _CancelAdapter();
      final client = OpenAIClient(
        apiKey: 'k',
        client: Dio()..httpClientAdapter = adapter,
        maxRetries: 3,
        initialRetryDelayMs: 200,
      );

      final stream = await client.stream([
        UserMessage.text('hi'),
      ], modelConfig: modelConfig);

      final sw = Stopwatch()..start();
      await expectLater(stream.first, throwsA(isCancelDioException));
      sw.stop();

      expect(adapter.fetches, 1);
      expect(sw.elapsedMilliseconds, lessThan(150));
    });

    test('Responses generate: zero retries, cancel DioException', () async {
      final adapter = _CancelAdapter();
      final client = ResponsesClient(
        apiKey: 'k',
        client: Dio()..httpClientAdapter = adapter,
        maxRetries: 3,
        initialRetryDelayMs: 200,
      );

      final sw = Stopwatch()..start();
      await expectLater(
        client.generate([UserMessage.text('hi')], modelConfig: modelConfig),
        throwsA(isCancelDioException),
      );
      sw.stop();

      expect(adapter.fetches, 1);
      expect(sw.elapsedMilliseconds, lessThan(150));
    });

    test('Gemini generate: zero retries, cancel DioException', () async {
      final adapter = _CancelAdapter();
      final client = GeminiClient(
        apiKey: 'k',
        client: Dio()..httpClientAdapter = adapter,
        maxRetries: 3,
        initialRetryDelayMs: 200,
      );

      final sw = Stopwatch()..start();
      await expectLater(
        client.generate([UserMessage.text('hi')], modelConfig: modelConfig),
        throwsA(isCancelDioException),
      );
      sw.stop();

      expect(adapter.fetches, 1);
      expect(sw.elapsedMilliseconds, lessThan(150));
    });

    test(
      'Claude generate: zero retries and rethrows unwrapped cancel DioException',
      () async {
        final adapter = _CancelAdapter();
        final client = ClaudeClient(
          apiKey: 'k',
          client: Dio()..httpClientAdapter = adapter,
          maxRetries: 3,
          initialRetryDelayMs: 200,
        );

        final sw = Stopwatch()..start();
        await expectLater(
          client.generate([UserMessage.text('hi')], modelConfig: modelConfig),
          throwsA(isCancelDioException),
        );
        sw.stop();

        expect(adapter.fetches, 1);
        expect(sw.elapsedMilliseconds, lessThan(150));
      },
    );

    test(
      'Claude stream: zero retries and rethrows unwrapped cancel DioException',
      () async {
        final adapter = _CancelAdapter();
        final client = ClaudeClient(
          apiKey: 'k',
          client: Dio()..httpClientAdapter = adapter,
          maxRetries: 3,
          initialRetryDelayMs: 200,
        );

        final sw = Stopwatch()..start();
        await expectLater(
          client.stream([UserMessage.text('hi')], modelConfig: modelConfig),
          throwsA(isCancelDioException),
        );
        sw.stop();

        expect(adapter.fetches, 1);
        expect(sw.elapsedMilliseconds, lessThan(150));
      },
    );

    test(
      'Bedrock generate: zero retries and rethrows unwrapped cancel DioException',
      () async {
        final adapter = _CancelAdapter();
        final client = BedrockClaudeClient(
          region: 'us-east-1',
          accessKeyId: 'AKIATEST',
          secretAccessKey: 'secret-test',
          client: Dio()..httpClientAdapter = adapter,
          maxRetries: 3,
          initialRetryDelayMs: 200,
        );

        final sw = Stopwatch()..start();
        await expectLater(
          client.generate([UserMessage.text('hi')], modelConfig: modelConfig),
          throwsA(isCancelDioException),
        );
        sw.stop();

        expect(adapter.fetches, 1);
        expect(sw.elapsedMilliseconds, lessThan(150));
      },
    );
  });

  test(
    'StatefulAgent maps Claude cancel DioException to cancelled, not unknown',
    () async {
      final adapter = _CancelAdapter();
      final client = ClaudeClient(
        apiKey: 'k',
        client: Dio()..httpClientAdapter = adapter,
        maxRetries: 3,
        initialRetryDelayMs: 50,
      );
      final agent = StatefulAgent(
        name: 'cancel-agent',
        client: client,
        modelConfig: modelConfig,
        state: AgentState.empty(),
        withGeneralPrinciples: false,
        disableSubAgents: true,
      );

      await expectLater(
        agent.run([UserMessage.text('hi')], useStream: false),
        throwsA(
          isA<AgentException>().having(
            (e) => e.code,
            'code',
            AgentExceptionCode.cancelled,
          ),
        ),
      );
      expect(adapter.fetches, 1);
    },
  );
}

class _CancelAdapter implements HttpClientAdapter {
  int fetches = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetches++;
    throw DioException.requestCancelled(
      requestOptions: options,
      reason: 'test cancel',
    );
  }

  @override
  void close({bool force = false}) {}
}
