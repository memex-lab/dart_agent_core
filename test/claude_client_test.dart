import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('ClaudeClient', () {
    test('保留并原样回传 Anthropic assistant content blocks', () async {
      final assistantContent = [
        {'type': 'thinking', 'thinking': '先分析需要读取文件', 'signature': 'sig-1'},
        {
          'type': 'tool_use',
          'id': 'toolu_1',
          'name': 'Read',
          'input': {'path': 'a.md'},
        },
        {'type': 'redacted_thinking', 'data': 'opaque-redacted-data'},
        {'type': 'thinking', 'thinking': '兼容服务可能没有 signature'},
        {
          'type': 'tool_use',
          'id': 'toolu_2',
          'name': 'Write',
          'input': {'path': 'b.md'},
        },
      ];
      final adapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'content': assistantContent,
          'stop_reason': 'tool_use',
          'usage': {'input_tokens': 10, 'output_tokens': 20},
        }),
        (_) => _jsonResponse({
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
          'stop_reason': 'end_turn',
          'usage': {'input_tokens': 1, 'output_tokens': 1},
        }),
      ]);
      final client = ClaudeClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      final modelMessage = await client.generate([
        UserMessage.text('开始'),
      ], modelConfig: ModelConfig(model: 'claude-test'));
      await client.generate([
        UserMessage.text('开始'),
        modelMessage,
        FunctionExecutionResultMessage(
          results: [
            FunctionExecutionResult(
              id: 'toolu_1',
              name: 'Read',
              isError: false,
              arguments: '{}',
              content: [TextPart('file content')],
            ),
          ],
        ),
      ], modelConfig: ModelConfig(model: 'claude-test'));

      expect(modelMessage.contentBlocks, equals(assistantContent));
      final secondRequest =
          jsonDecode(adapter.requests[1] as String) as Map<String, dynamic>;
      final assistantMessage =
          secondRequest['messages'][1] as Map<String, dynamic>;
      expect(assistantMessage['content'], equals(assistantContent));
    });

    test('tool_result 会带上 Anthropic 官方 is_error 字段', () async {
      final adapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
          'stop_reason': 'end_turn',
          'usage': {'input_tokens': 1, 'output_tokens': 1},
        }),
      ]);
      final client = ClaudeClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      await client.generate([
        FunctionExecutionResultMessage(
          results: [
            FunctionExecutionResult(
              id: 'toolu_error',
              name: 'Read',
              isError: true,
              arguments: '{}',
              content: [TextPart('权限不足')],
            ),
          ],
        ),
      ], modelConfig: ModelConfig(model: 'claude-test'));

      final request =
          jsonDecode(adapter.requests.single as String) as Map<String, dynamic>;
      final toolResult =
          (request['messages'][0] as Map<String, dynamic>)['content'][0]
              as Map<String, dynamic>;
      expect(toolResult['is_error'], isTrue);
    });

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
        final client = ClaudeClient(
          apiKey: 'test-key',
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
            jsonDecode(adapter.requests.single as String)
                as Map<String, dynamic>;
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

    test('stream 会产出完整有序 content blocks', () async {
      final adapter = _CaptureAdapter([
        (_) => _streamResponse([
          {
            'type': 'message_start',
            'message': {
              'usage': {'input_tokens': 1, 'output_tokens': 0},
            },
          },
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'thinking', 'thinking': ''},
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'thinking_delta', 'thinking': '先想'},
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'signature_delta', 'signature': 'sig'},
          },
          {'type': 'content_block_stop', 'index': 0},
          {
            'type': 'content_block_start',
            'index': 1,
            'content_block': {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'Read',
              'input': {},
            },
          },
          {
            'type': 'content_block_delta',
            'index': 1,
            'delta': {'type': 'input_json_delta', 'partial_json': '{"path"'},
          },
          {
            'type': 'content_block_delta',
            'index': 1,
            'delta': {'type': 'input_json_delta', 'partial_json': ':"a.md"}'},
          },
          {'type': 'content_block_stop', 'index': 1},
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
            'usage': {'output_tokens': 8},
          },
          {'type': 'message_stop'},
        ]),
      ]);
      final client = ClaudeClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      final stream = await client.stream([
        UserMessage.text('开始'),
      ], modelConfig: ModelConfig(model: 'claude-test'));
      final chunks = await stream.map((e) => e.modelMessage).toList();
      final blocks = chunks
          .whereType<ModelMessage>()
          .expand((message) => message.contentBlocks)
          .toList();

      expect(blocks, [
        {'type': 'thinking', 'thinking': '先想', 'signature': 'sig'},
        {
          'type': 'tool_use',
          'id': 'toolu_1',
          'name': 'Read',
          'input': {'path': 'a.md'},
        },
      ]);
    });

    test('stream 会把 Anthropic SSE error event 转成异常', () async {
      final adapter = _CaptureAdapter([
        (_) => _rawStreamResponse(
          'event: error\n'
          'data: {"type":"error","error":{"type":"overloaded_error","message":"过载"}}\n\n',
        ),
      ]);
      final client = ClaudeClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      final stream = await client.stream([
        UserMessage.text('开始'),
      ], modelConfig: ModelConfig(model: 'claude-test'));

      await expectLater(
        stream,
        emitsError(predicate((error) => error.toString().contains('过载'))),
      );
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

ResponseBody _streamResponse(List<Map<String, dynamic>> events) {
  final data = events.map((event) {
    return 'event: ${event['type']}\n'
        'data: ${jsonEncode(event)}\n\n';
  }).join();
  return _rawStreamResponse(data);
}

ResponseBody _rawStreamResponse(String data) {
  return ResponseBody.fromString(
    data,
    200,
    headers: {
      Headers.contentTypeHeader: ['text/event-stream'],
    },
  );
}
