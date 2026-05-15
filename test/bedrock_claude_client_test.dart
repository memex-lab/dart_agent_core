import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('BedrockClaudeClient', () {
    test(
      'legacy thought without content blocks is sent as thinking block',
      () async {
        final adapter = _CaptureAdapter([
          (_) => _jsonResponse({
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
            'stop_reason': 'end_turn',
            'usage': {'input_tokens': 1, 'output_tokens': 1},
          }),
        ]);
        final client = BedrockClaudeClient(
          region: 'us-east-1',
          accessKeyId: 'test-access-key',
          secretAccessKey: 'test-secret-key',
          client: Dio()..httpClientAdapter = adapter,
        );

        await client.generate([
          UserMessage.text('开始'),
          ModelMessage(
            model: 'claude-test',
            thought: '需要先读取文件',
            textOutput: '我会调用工具。',
            functionCalls: [
              FunctionCall(
                id: 'toolu_1',
                name: 'Read',
                arguments: '{"path":"a.md"}',
              ),
            ],
          ),
        ], modelConfig: ModelConfig(model: 'claude-test'));

        final request =
            jsonDecode(adapter.requests.single) as Map<String, dynamic>;
        final assistantMessage = request['messages'][1] as Map<String, dynamic>;
        expect(assistantMessage['content'], [
          {'type': 'thinking', 'thinking': '需要先读取文件'},
          {'type': 'text', 'text': '我会调用工具。'},
          {
            'type': 'tool_use',
            'id': 'toolu_1',
            'name': 'Read',
            'input': {'path': 'a.md'},
          },
        ]);
      },
    );
  });
}

class _CaptureAdapter implements HttpClientAdapter {
  final List<ResponseBody Function(RequestOptions)> responses;
  final List<String> requests = [];

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
    } else if (options.data is Stream<List<int>>) {
      await for (final chunk in options.data as Stream<List<int>>) {
        bytes.addAll(chunk);
      }
    } else if (options.data is List<int>) {
      bytes.addAll(options.data as List<int>);
    } else if (options.data != null) {
      bytes.addAll(utf8.encode(options.data.toString()));
    }

    requests.add(utf8.decode(bytes));
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
