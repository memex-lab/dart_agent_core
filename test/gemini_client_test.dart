import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('GeminiClient', () {
    test('uses function name and optional id in functionResponse', () async {
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
          'usageMetadata': {
            'promptTokenCount': 1,
            'candidatesTokenCount': 1,
            'totalTokenCount': 2,
          },
        }),
      ]);
      final client = GeminiClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      await client.generate([
        UserMessage.text('run tool'),
        FunctionExecutionResultMessage(
          results: [
            FunctionExecutionResult(
              id: 'call_1',
              name: 'lookup',
              isError: false,
              arguments: '{}',
              content: [TextPart('result')],
            ),
          ],
        ),
      ], modelConfig: ModelConfig(model: 'gemini-test'));

      final request = adapter.requests.single as Map<String, dynamic>;
      final toolContent = request['contents'][1] as Map<String, dynamic>;
      final functionResponse =
          (toolContent['parts'][0] as Map<String, dynamic>)['functionResponse']
              as Map<String, dynamic>;
      expect(functionResponse['name'], 'lookup');
      expect(functionResponse['id'], 'call_1');
    });

    test('parses functionCall id separately from function name', () async {
      final adapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'id': 'call_1',
                      'name': 'lookup',
                      'args': {'q': 'x'},
                    },
                    'thoughtSignature': 'sig-1',
                  },
                ],
              },
              'finishReason': 'STOP',
            },
          ],
          'usageMetadata': {
            'promptTokenCount': 1,
            'candidatesTokenCount': 1,
            'totalTokenCount': 2,
          },
        }),
      ]);
      final client = GeminiClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      final response = await client.generate([
        UserMessage.text('run tool'),
      ], modelConfig: ModelConfig(model: 'gemini-test'));

      expect(response.functionCalls.single.id, 'call_1');
      expect(response.functionCalls.single.name, 'lookup');
      expect(response.thoughtSignature, 'sig-1');
    });
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
