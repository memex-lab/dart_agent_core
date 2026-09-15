import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('OpenAIClient DocumentPart', () {
    test(
      'encodes PDF as data-URI file_data with mime-derived filename',
      () async {
        final adapter = _CaptureAdapter([(_) => _openaiOk()]);
        final client = OpenAIClient(
          apiKey: 'test-key',
          client: Dio()..httpClientAdapter = adapter,
        );

        await client.generate([
          UserMessage([DocumentPart('JVBERi0xLjQ=', 'application/pdf')]),
        ], modelConfig: ModelConfig(model: 'gpt-test'));

        final body = _asJsonMap(adapter.requests.single);
        final content =
            (body['messages'][0] as Map<String, dynamic>)['content'] as List;
        expect(content[0]['type'], 'file');
        final file = content[0]['file'] as Map<String, dynamic>;
        expect(file['file_data'], 'data:application/pdf;base64,JVBERi0xLjQ=');
        expect(file['filename'], 'document.pdf');
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

Map<String, dynamic> _asJsonMap(Object? data) {
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return Map<String, dynamic>.from(data);
  return jsonDecode(data as String) as Map<String, dynamic>;
}

ResponseBody _openaiOk() {
  return ResponseBody.fromString(
    jsonEncode({
      'id': '1',
      'object': 'chat.completion',
      'choices': [
        {
          'index': 0,
          'message': {'role': 'assistant', 'content': 'ok'},
          'finish_reason': 'stop',
        },
      ],
      'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2},
    }),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}
