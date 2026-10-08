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

    test('parallel function calls without ids get distinct ids', () async {
      final adapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'name': 'search',
                      'args': {'q': 'a'},
                    },
                  },
                  {
                    'functionCall': {
                      'name': 'search',
                      'args': {'q': 'b'},
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
        UserMessage.text('search twice'),
      ], modelConfig: ModelConfig(model: 'gemini-test'));

      final ids = result.functionCalls.map((call) => call.id).toList();
      expect(ids.toSet(), hasLength(2));
      expect(ids.every((id) => id.contains('-')), isTrue);
      expect(result.functionCalls.map((call) => jsonDecode(call.arguments)), [
        {'q': 'a'},
        {'q': 'b'},
      ]);
    });

    test('preserves explicit provider ids when another call has no id', () async {
      final adapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'name': 'search',
                      'args': {'q': 'a'},
                    },
                  },
                  {
                    'functionCall': {
                      'id': 'search',
                      'name': 'search',
                      'args': {'q': 'b'},
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
        UserMessage.text('search twice'),
      ], modelConfig: ModelConfig(model: 'gemini-test'));

      expect(result.functionCalls, hasLength(2));
      expect(result.functionCalls.last.id, 'search');
      expect(result.functionCalls.first.id, isNot('search'));
    });

    test(
      'streaming assigns distinct synthetic ids across chunks without ids',
      () async {
        Map<String, dynamic> chunk(String q) => {
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'name': 'search',
                      'args': {'q': q},
                    },
                  },
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        };

        final adapter = _StreamCaptureAdapter([
          '${jsonEncode(chunk('a'))}\n',
          '${jsonEncode(chunk('b'))}\n',
        ]);
        final client = GeminiClient(
          apiKey: 'test-key',
          client: Dio()..httpClientAdapter = adapter,
        );

        final stream = await client.stream(
          [UserMessage.text('search')],
          modelConfig: ModelConfig(model: 'gemini-test'),
        );
        final ids = <String>[];
        await for (final event in stream) {
          final message = event.modelMessage;
          if (message == null || message.functionCalls.isEmpty) continue;
          ids.add(message.functionCalls.single.id);
        }

        expect(ids.toSet(), hasLength(2));
      },
    );

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

    test(
      'required toolChoice wraps mode under functionCallingConfig',
      () async {
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

        await client.generate(
          [UserMessage.text('use a tool')],
          tools: [
            Tool(
              name: 'Glob',
              description: 'Find files',
              parameters: const {
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            ),
          ],
          toolChoice: ToolChoice(
            mode: ToolChoiceMode.required,
            allowedFunctionNames: const ['Glob'],
          ),
          modelConfig: ModelConfig(model: 'gemini-test'),
        );

        final body = adapter.bodies.single as Map<String, dynamic>;
        expect(body['toolConfig'], {
          'functionCallingConfig': {
            'mode': 'ANY',
            'allowedFunctionNames': ['Glob'],
          },
        });
      },
    );
  });
}

class _StreamCaptureAdapter implements HttpClientAdapter {
  final List<String> chunks;

  _StreamCaptureAdapter(this.chunks);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream.fromIterable(chunks.map(utf8.encode)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
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
