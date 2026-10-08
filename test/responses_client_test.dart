import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('ResponsesClient', () {
    test(
      'derives previous_response_id and only sends later messages',
      () async {
        final adapter = _CaptureAdapter([
          (_) => _jsonResponse({
            'id': 'resp_2',
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': 'follow-up'},
                ],
              },
            ],
          }),
        ]);
        final client = ResponsesClient(
          apiKey: 'test-key',
          client: Dio()..httpClientAdapter = adapter,
        );

        final result = await client.generate(
          [
            UserMessage.text('first'),
            ModelMessage(
              model: 'gpt-test',
              textOutput: 'ack',
              responseId: 'resp_1',
              stopReason: 'completed',
            ),
            UserMessage.text('second'),
          ],
          tools: [
            Tool(
              name: 'get_weather',
              description: 'Weather',
              parameters: {
                'type': 'object',
                'properties': {
                  'city': {'type': 'string'},
                },
              },
            ),
          ],
          modelConfig: ModelConfig(model: 'gpt-test'),
        );

        expect(result.textOutput, 'follow-up');
        expect(result.responseId, 'resp_2');
        final body = adapter.bodies.single as Map<String, dynamic>;
        expect(body['previous_response_id'], 'resp_1');
        final input = body['input'] as List;
        expect(input, hasLength(1));
        expect(input.single['role'], 'user');
        expect(input.single['content'].single['text'], 'second');
        expect(body.containsKey('tools'), isTrue);
        expect(body['tools'], hasLength(1));
        expect(body['tools'][0]['name'], 'get_weather');
      },
    );

    test('autoPreviousResponseId false sends full history', () async {
      final adapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'id': 'resp_full',
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'ok'},
              ],
            },
          ],
        }),
      ]);
      final client = ResponsesClient(
        apiKey: 'test-key',
        autoPreviousResponseId: false,
        client: Dio()..httpClientAdapter = adapter,
      );

      await client.generate([
        UserMessage.text('first'),
        ModelMessage(
          model: 'gpt-test',
          textOutput: 'ack',
          responseId: 'resp_1',
          stopReason: 'completed',
        ),
        UserMessage.text('second'),
      ], modelConfig: ModelConfig(model: 'gpt-test'));

      final body = adapter.bodies.single as Map<String, dynamic>;
      expect(body.containsKey('previous_response_id'), isFalse);
      expect(body['input'], hasLength(3));
    });

    test(
      'drops orphan previous_response_id when history is not anchored locally',
      () async {
        final adapter = _CaptureAdapter([
          (_) => _jsonResponse({
            'id': 'resp_2',
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': 'ok'},
                ],
              },
            ],
          }),
        ]);
        final client = ResponsesClient(
          apiKey: 'test-key',
          client: Dio()..httpClientAdapter = adapter,
        );

        await client.generate(
          [
            UserMessage.text('first'),
            ModelMessage(
              model: 'gpt-test',
              textOutput: 'ack',
              responseId: 'resp_local',
              stopReason: 'completed',
            ),
            UserMessage.text('second'),
          ],
          modelConfig: ModelConfig(
            model: 'gpt-test',
            extra: {'previous_response_id': 'resp_orphan'},
          ),
        );

        final body = adapter.bodies.single as Map<String, dynamic>;
        expect(body.containsKey('previous_response_id'), isFalse);
        expect(body['input'], hasLength(3));
      },
    );

    test(
      'keeps explicit previous_response_id when only new user input is sent',
      () async {
        final adapter = _CaptureAdapter([
          (_) => _jsonResponse({
            'id': 'resp_2',
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': 'ok'},
                ],
              },
            ],
          }),
        ]);
        final client = ResponsesClient(
          apiKey: 'test-key',
          client: Dio()..httpClientAdapter = adapter,
        );

        await client.generate(
          [UserMessage.text('follow up')],
          modelConfig: ModelConfig(
            model: 'gpt-test',
            extra: {'previous_response_id': 'resp_server'},
          ),
        );

        final body = adapter.bodies.single as Map<String, dynamic>;
        expect(body['previous_response_id'], 'resp_server');
        expect(body['input'], hasLength(1));
      },
    );

    test(
      'keeps explicit previous_response_id for incremental assistant input',
      () async {
        final adapter = _CaptureAdapter([
          (_) => _jsonResponse({
            'id': 'resp_2',
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': 'ok'},
                ],
              },
            ],
          }),
        ]);
        final client = ResponsesClient(
          apiKey: 'test-key',
          client: Dio()..httpClientAdapter = adapter,
        );

        await client.generate(
          [
            ModelMessage(
              model: 'gpt-test',
              textOutput: 'new assistant turn',
              stopReason: 'completed',
            ),
            UserMessage.text('follow up'),
          ],
          modelConfig: ModelConfig(
            model: 'gpt-test',
            extra: {'previous_response_id': 'resp_server'},
          ),
        );

        final body = adapter.bodies.single as Map<String, dynamic>;
        expect(body['previous_response_id'], 'resp_server');
        expect(body['input'], hasLength(2));
      },
    );

    test(
      'encodes DocumentPart as input_file with data-URI file_data',
      () async {
        final adapter = _CaptureAdapter([
          (_) => _jsonResponse({
            'id': 'resp_doc',
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': 'summarized'},
                ],
              },
            ],
          }),
        ]);
        final client = ResponsesClient(
          apiKey: 'test-key',
          client: Dio()..httpClientAdapter = adapter,
        );

        await client.generate([
          UserMessage([DocumentPart('JVBERi0xLjQ=', 'application/pdf')]),
        ], modelConfig: ModelConfig(model: 'gpt-test'));

        final body = adapter.bodies.single as Map<String, dynamic>;
        final content =
            (body['input'][0] as Map<String, dynamic>)['content'] as List;
        expect(content[0]['type'], 'input_file');
        expect(content[0]['filename'], 'document.pdf');
        expect(
          content[0]['file_data'],
          'data:application/pdf;base64,JVBERi0xLjQ=',
        );
      },
    );

    test('throws on unsupported user content parts', () async {
      final adapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'id': 'resp_x',
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'ok'},
              ],
            },
          ],
        }),
      ]);
      final client = ResponsesClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        client.generate(
          [UserMessage([VideoPart('abc', 'video/mp4')])],
          modelConfig: ModelConfig(model: 'gpt-test'),
        ),
        throwsA(
          predicate(
            (e) =>
                e is Exception &&
                e.toString().contains('Unsupported content type'),
          ),
        ),
      );
      expect(adapter.bodies, isEmpty);
    });

    test('checkResponseId returns true on 200 and false on 404', () async {
      final adapter = _CaptureAdapter([
        (options) {
          expect(options.uri.path, endsWith('/responses/resp_ok'));
          return _jsonResponse({'id': 'resp_ok'});
        },
        (_) => ResponseBody.fromString(
          '{"error":"not found"}',
          404,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      ]);
      final client = ResponsesClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      expect(await client.checkResponseId('resp_ok'), isTrue);
      expect(await client.checkResponseId('resp_missing'), isFalse);
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
