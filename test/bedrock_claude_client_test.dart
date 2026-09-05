import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('BedrockClaudeClient', () {
    test(
      'signs the request and maps Anthropic body plus tool_result is_error',
      () async {
        final adapter = _CaptureAdapter([
          (options) {
            expect(options.uri.host, 'bedrock-runtime.us-east-1.amazonaws.com');
            expect(options.uri.path, contains('anthropic.claude-test'));
            expect(options.headers['Authorization'], isNotNull);
            expect(
              options.headers['Authorization'].toString(),
              contains('AWS4-HMAC-SHA256'),
            );
            expect(options.headers['X-Amz-Date'], isNotNull);
            return _jsonResponse({
              'content': [
                {'type': 'text', 'text': 'hello from bedrock'},
              ],
              'stop_reason': 'end_turn',
              'usage': {'input_tokens': 4, 'output_tokens': 6},
            });
          },
        ]);
        final client = BedrockClaudeClient(
          region: 'us-east-1',
          accessKeyId: 'AKIATEST',
          secretAccessKey: 'secret-test',
          client: Dio()..httpClientAdapter = adapter,
        );

        final result = await client.generate([
          UserMessage.text('hi'),
          ModelMessage(
            model: 'anthropic.claude-test',
            functionCalls: [
              FunctionCall(id: 'toolu_1', name: 'lookup', arguments: '{}'),
            ],
          ),
          FunctionExecutionResultMessage(
            results: [
              FunctionExecutionResult(
                id: 'toolu_1',
                name: 'lookup',
                arguments: '{}',
                content: [TextPart('missing')],
                isError: true,
              ),
            ],
          ),
        ], modelConfig: ModelConfig(model: 'anthropic.claude-test'));

        expect(result.textOutput, 'hello from bedrock');
        expect(result.stopReason, 'end_turn');
        expect(result.usage?.promptTokens, 4);
        expect(result.usage?.completionTokens, 6);

        final body = adapter.bodies.single as Map<String, dynamic>;
        expect(body['anthropic_version'], 'bedrock-2023-05-31');
        final messages = body['messages'] as List;
        final toolResult = (messages.last['content'] as List).single;
        expect(toolResult['type'], 'tool_result');
        expect(toolResult['tool_use_id'], 'toolu_1');
        expect(toolResult['is_error'], isTrue);
      },
    );
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
