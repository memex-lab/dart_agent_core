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

        final result = await client.generate([
          UserMessage.text('first'),
          ModelMessage(
            model: 'gpt-test',
            textOutput: 'ack',
            responseId: 'resp_1',
            stopReason: 'completed',
          ),
          UserMessage.text('second'),
        ], modelConfig: ModelConfig(model: 'gpt-test'));

        expect(result.textOutput, 'follow-up');
        expect(result.responseId, 'resp_2');
        final body = adapter.bodies.single as Map<String, dynamic>;
        expect(body['previous_response_id'], 'resp_1');
        final input = body['input'] as List;
        expect(input, hasLength(1));
        expect(input.single['role'], 'user');
        expect(input.single['content'].single['text'], 'second');
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
