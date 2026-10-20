import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('ClaudeClient', () {
    group('cache usage accounting', () {
      final cases = <String, Map<String, int>>{
        'no cache fields': {},
        'cache write': {'cache_creation_input_tokens': 100000},
        'cache read': {'cache_read_input_tokens': 100000},
        'mixed read and write': {
          'cache_read_input_tokens': 100000,
          'cache_creation_input_tokens': 1000,
        },
      };

      for (final entry in cases.entries) {
        final cachedTokens = entry.value.values.fold(0, (a, b) => a + b);
        final inputTokens = 50 + cachedTokens;
        final usage = {'input_tokens': 50, 'output_tokens': 2, ...entry.value};

        test('generate counts all input tokens: ${entry.key}', () async {
          final adapter = _CaptureAdapter([
            (_) => _jsonResponse({
              'content': [
                {'type': 'text', 'text': 'ok'},
              ],
              'stop_reason': 'end_turn',
              'usage': {...usage, 'output_tokens': 20},
            }),
          ]);
          final client = ClaudeClient(
            apiKey: 'test-key',
            client: Dio()..httpClientAdapter = adapter,
          );
          final result = await client.generate([
            UserMessage.text('hello'),
          ], modelConfig: ModelConfig(model: 'claude-test'));

          expect(result.usage!.promptTokens, inputTokens);
          expect(result.usage!.completionTokens, 20);
          expect(result.usage!.totalTokens, inputTokens + 20);
          expect(result.usage!.cachedToken, cachedTokens);
          expect(result.usage!.originalUsage, {...usage, 'output_tokens': 20});
        });

        test('stream retains all input tokens: ${entry.key}', () async {
          final adapter = _CaptureAdapter([
            (_) => _streamResponse([
              {
                'type': 'message_start',
                'message': {'usage': usage},
              },
              {
                'type': 'message_delta',
                'delta': {'stop_reason': 'end_turn'},
                'usage': {'output_tokens': 20},
              },
              {'type': 'message_stop'},
            ]),
          ]);
          final client = ClaudeClient(
            apiKey: 'test-key',
            client: Dio()..httpClientAdapter = adapter,
          );
          final stream = await client.stream([
            UserMessage.text('hello'),
          ], modelConfig: ModelConfig(model: 'claude-test'));
          final usages = await stream
              .map((event) => event.modelMessage?.usage)
              .where((usage) => usage != null)
              .cast<ModelUsage>()
              .toList();

          expect(usages, hasLength(2));
          for (final actual in usages) {
            expect(actual.promptTokens, inputTokens);
            expect(actual.cachedToken, cachedTokens);
            expect(actual.totalTokens, inputTokens + actual.completionTokens);
          }
          expect(usages.first.completionTokens, 2);
          expect(usages.last.completionTokens, 20);
          expect(usages.first.originalUsage, usage);
          expect(usages.last.originalUsage, {...usage, 'output_tokens': 20});
        });
      }

      test(
        'stream replaces cumulative usage and preserves omitted fields',
        () async {
          final adapter = _CaptureAdapter([
            (_) => _streamResponse([
              {
                'type': 'message_start',
                'message': {
                  'usage': {
                    'input_tokens': 50,
                    'cache_read_input_tokens': 100000,
                    'cache_creation_input_tokens': 1000,
                    'output_tokens': 2,
                  },
                },
              },
              {
                'type': 'message_delta',
                'delta': {},
                'usage': {
                  'input_tokens': 60,
                  'cache_read_input_tokens': 110000,
                  'cache_creation_input_tokens': 2000,
                  'output_tokens': 10,
                },
              },
              {
                'type': 'message_delta',
                'delta': {},
                'usage': {
                  'input_tokens': 0,
                  'cache_read_input_tokens': null,
                  'output_tokens': 15,
                },
              },
              {
                'type': 'message_delta',
                'delta': {'stop_reason': 'end_turn'},
                'usage': {'output_tokens': 20},
              },
              {'type': 'message_stop'},
            ]),
          ]);
          final client = ClaudeClient(
            apiKey: 'test-key',
            client: Dio()..httpClientAdapter = adapter,
          );
          final stream = await client.stream([
            UserMessage.text('hello'),
          ], modelConfig: ModelConfig(model: 'claude-test'));
          final usages = await stream
              .map((event) => event.modelMessage?.usage)
              .where((usage) => usage != null)
              .cast<ModelUsage>()
              .toList();

          expect(usages.map((u) => u.promptTokens), [
            101050,
            112060,
            112000,
            112000,
          ]);
          expect(usages.map((u) => u.cachedToken), [
            101000,
            112000,
            112000,
            112000,
          ]);
          expect(usages.map((u) => u.completionTokens), [2, 10, 15, 20]);
          expect(usages.map((u) => u.totalTokens), [
            101052,
            112070,
            112015,
            112020,
          ]);
          // Each emitted usage retains its own snapshot as later deltas arrive.
          expect(usages.first.originalUsage['input_tokens'], 50);
          expect(usages.last.originalUsage, {
            'input_tokens': 0,
            'cache_read_input_tokens': 110000,
            'cache_creation_input_tokens': 2000,
            'output_tokens': 20,
          });
        },
      );
    });

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

    test('兼容服务没有 thinking signature 时仍会回传 thinking block', () async {
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
        ModelMessage(model: 'claude-compatible', thought: '先分析兼容服务输出'),
      ], modelConfig: ModelConfig(model: 'claude-test'));

      final request =
          jsonDecode(adapter.requests.single as String) as Map<String, dynamic>;
      final assistantContent =
          (request['messages'][0] as Map<String, dynamic>)['content'] as List;

      expect(assistantContent, [
        {'type': 'thinking', 'thinking': '先分析兼容服务输出'},
      ]);
    });

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

    test('ToolChoiceMode.none maps to tool_choice type none', () async {
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

      await client.generate(
        [UserMessage.text('do not use tools')],
        tools: [
          Tool(
            name: 'lookup',
            description: 'Look something up',
            parameters: const {
              'type': 'object',
              'properties': <String, dynamic>{},
            },
          ),
        ],
        toolChoice: ToolChoice(mode: ToolChoiceMode.none),
        modelConfig: ModelConfig(model: 'claude-test'),
      );

      final body =
          jsonDecode(adapter.requests.single as String) as Map<String, dynamic>;
      expect(body['tools'], isNotEmpty);
      expect(body['tool_choice'], {'type': 'none'});
    });

    group('automatic prompt caching', () {
      Future<Map<String, dynamic>> sendAndCaptureBody(
        ClaudeClient Function(Dio dio) build,
      ) async {
        final adapter = _CaptureAdapter([
          (_) => _jsonResponse({
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
            'stop_reason': 'end_turn',
            'usage': {'input_tokens': 1, 'output_tokens': 1},
          }),
        ]);
        final client = build(Dio()..httpClientAdapter = adapter);
        await client.generate([
          UserMessage.text('hello'),
        ], modelConfig: ModelConfig(model: 'claude-test'));
        return jsonDecode(adapter.requests.single as String)
            as Map<String, dynamic>;
      }

      test('Anthropic endpoint sends top-level cache_control', () async {
        final body = await sendAndCaptureBody(
          (dio) => ClaudeClient(apiKey: 'test-key', client: dio),
        );
        expect(body['cache_control'], {'type': 'ephemeral'});
      });

      test('third-party endpoint does not send cache_control', () async {
        final body = await sendAndCaptureBody(
          (dio) => ClaudeClient(
            apiKey: 'test-key',
            baseUrl: 'https://api.minimaxi.com/anthropic',
            client: dio,
          ),
        );
        expect(body.containsKey('cache_control'), isFalse);
      });

      test('enablePromptCaching overrides the endpoint default', () async {
        final disabled = await sendAndCaptureBody(
          (dio) => ClaudeClient(
            apiKey: 'test-key',
            enablePromptCaching: false,
            client: dio,
          ),
        );
        expect(disabled.containsKey('cache_control'), isFalse);

        final enabled = await sendAndCaptureBody(
          (dio) => ClaudeClient(
            apiKey: 'test-key',
            baseUrl: 'https://api.minimaxi.com/anthropic',
            enablePromptCaching: true,
            client: dio,
          ),
        );
        expect(enabled['cache_control'], {'type': 'ephemeral'});
      });
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
