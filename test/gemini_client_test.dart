import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('GeminiClient', () {
    test('generate 保留 Gemini functionCall 返回的 id', () async {
      final adapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'id': 'call_abc123',
                      'name': 'Glob',
                      'args': {'pattern': '*.dart'},
                    },
                  },
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        }),
      ]);
      final client = GeminiClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      final result = await client.generate([
        UserMessage.text('find files'),
      ], modelConfig: ModelConfig(model: 'gemini-test'));

      expect(result.functionCalls, hasLength(1));
      expect(result.functionCalls.single.id, 'call_abc123');
      expect(result.functionCalls.single.name, 'Glob');
      expect(jsonDecode(result.functionCalls.single.arguments), {
        'pattern': '*.dart',
      });
    });

    test('request body maps functionCall and functionResponse ids', () async {
      final adapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'ok'},
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        }),
      ]);
      final client = GeminiClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      await client.generate([
        ModelMessage(
          model: 'gemini-test',
          functionCalls: [
            FunctionCall(
              id: 'call_abc123',
              name: 'Glob',
              arguments: '{"pattern":"*.dart"}',
            ),
          ],
        ),
        FunctionExecutionResultMessage(
          results: [
            FunctionExecutionResult(
              id: 'call_abc123',
              name: 'Glob',
              isError: false,
              arguments: '{"pattern":"*.dart"}',
              content: [TextPart('["lib/main.dart"]')],
            ),
          ],
        ),
      ], modelConfig: ModelConfig(model: 'gemini-test'));

      final body = adapter.bodies.single as Map<String, dynamic>;
      final contents = body['contents'] as List;
      final functionCall =
          (contents[0]['parts'] as List).single['functionCall']
              as Map<String, dynamic>;
      final functionResponse =
          (contents[1]['parts'] as List).single['functionResponse']
              as Map<String, dynamic>;

      expect(contents[0]['role'], 'model');
      expect(contents[1]['role'], 'user');
      expect(functionCall['id'], 'call_abc123');
      expect(functionCall['name'], 'Glob');
      expect(functionCall['args'], {'pattern': '*.dart'});
      expect(functionResponse['id'], 'call_abc123');
      expect(functionResponse['name'], 'Glob');
      expect(functionResponse['response'], {'content': '["lib/main.dart"]'});
    });
  });
}

class _CaptureAdapter implements HttpClientAdapter {
  final List<ResponseBody Function(RequestOptions)> responses;
  final List<dynamic> bodies = [];

  _CaptureAdapter(this.responses);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    if (bytes.isNotEmpty) {
      bodies.add(jsonDecode(utf8.decode(bytes)));
    }
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
