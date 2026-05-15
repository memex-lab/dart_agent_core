import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('OpenAIClient', () {
    test('round-trips explicit empty reasoning_content', () async {
      final adapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'ok'},
              'finish_reason': 'stop',
            },
          ],
          'usage': {
            'prompt_tokens': 1,
            'completion_tokens': 1,
            'total_tokens': 2,
          },
        }),
      ]);
      final client = OpenAIClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      await client.generate([
        UserMessage.text('hi'),
        ModelMessage(
          model: 'deepseek-v4-pro',
          thought: '',
          functionCalls: [
            FunctionCall(id: 'call_1', name: 'lookup', arguments: '{}'),
          ],
        ),
      ], modelConfig: ModelConfig(model: 'deepseek-v4-pro'));

      final request = adapter.requests.single as Map<String, dynamic>;
      final assistantMessage = request['messages'][1] as Map<String, dynamic>;
      expect(assistantMessage, containsPair('reasoning_content', ''));
    });

    test(
      'adds DeepSeek V4 empty reasoning_content for legacy tool-call turns',
      () async {
        final adapter = _CaptureAdapter([
          (_) => _jsonResponse({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': 1,
              'completion_tokens': 1,
              'total_tokens': 2,
            },
          }),
        ]);
        final client = OpenAIClient(
          apiKey: 'test-key',
          client: Dio()..httpClientAdapter = adapter,
        );

        await client.generate([
          UserMessage.text('hi'),
          ModelMessage(
            model: 'deepseek-v4-pro',
            functionCalls: [
              FunctionCall(id: 'call_1', name: 'lookup', arguments: '{}'),
            ],
          ),
        ], modelConfig: ModelConfig(model: 'deepseek-v4-pro'));

        final request = adapter.requests.single as Map<String, dynamic>;
        final assistantMessage = request['messages'][1] as Map<String, dynamic>;
        expect(assistantMessage, containsPair('reasoning_content', ''));
      },
    );
  });
}

class _CaptureAdapter implements HttpClientAdapter {
  final List<ResponseBody Function(RequestOptions)> responses;
  final List<Object?> requests = [];

  _CaptureAdapter(this.responses);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.data);
    return responses.removeAt(0)(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Map<String, dynamic> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}
