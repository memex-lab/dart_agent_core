import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('ImagePart', () {
    test('base64 roundtrips through toJson/fromJson', () {
      final part = ImagePart('abc123', 'image/png', detail: 'high');
      final restored = ImagePart.fromJson(part.toJson());

      expect(restored.base64Data, 'abc123');
      expect(restored.mimeType, 'image/png');
      expect(restored.detail, 'high');
      expect(restored.url, isNull);
      expect(restored.openAiImageUrl, 'data:image/png;base64,abc123');
      expect(restored.claudeImageSource, {
        'type': 'base64',
        'media_type': 'image/png',
        'data': 'abc123',
      });
    });

    test('url roundtrips through toJson/fromJson', () {
      const href = 'https://example.com/photo.jpg';
      final part = ImagePart('', 'image/jpeg', url: href, detail: 'low');
      final restored = ImagePart.fromJson(part.toJson());

      expect(restored.hasUrl, isTrue);
      expect(restored.url, href);
      expect(restored.toJson().containsKey('base64Data'), isFalse);
      expect(restored.openAiImageUrl, href);
      expect(restored.claudeImageSource, {'type': 'url', 'url': href});
    });

    test('UserMessage with a url image roundtrips', () {
      final message = UserMessage([
        TextPart('see this'),
        ImagePart('', 'image/png', url: 'https://cdn.example/a.png'),
      ], timestamp: 1);
      final restored = UserMessage.fromJson(message.toJson());
      final image = restored.contents[1] as ImagePart;

      expect(image.url, 'https://cdn.example/a.png');
      expect(image.hasUrl, isTrue);
    });
  });

  group('OpenAIClient image_url', () {
    test('sends a hosted url without wrapping it as a data uri', () async {
      const href = 'https://example.com/cat.png';
      final adapter = _CaptureAdapter([(_) => _openaiOk()]);
      final client = OpenAIClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      await client.generate([
        UserMessage([ImagePart('', 'image/png', url: href)]),
      ], modelConfig: ModelConfig(model: 'gpt-test'));

      final body = _asJsonMap(adapter.requests.single);
      final content =
          (body['messages'][0] as Map<String, dynamic>)['content'] as List;
      expect(content[0]['type'], 'image_url');
      expect(content[0]['image_url']['url'], href);
    });

    test('still sends base64 as a data uri', () async {
      final adapter = _CaptureAdapter([(_) => _openaiOk()]);
      final client = OpenAIClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      await client.generate([
        UserMessage([ImagePart('abc', 'image/png')]),
      ], modelConfig: ModelConfig(model: 'gpt-test'));

      final body = _asJsonMap(adapter.requests.single);
      final content =
          (body['messages'][0] as Map<String, dynamic>)['content'] as List;
      expect(content[0]['image_url']['url'], 'data:image/png;base64,abc');
    });
  });

  group('ClaudeClient image url', () {
    test('sends Anthropic url source for hosted images', () async {
      const href = 'https://example.com/cat.png';
      final adapter = _CaptureAdapter([(_) => _claudeOk()]);
      final client = ClaudeClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      await client.generate([
        UserMessage([ImagePart('', 'image/png', url: href)]),
      ], modelConfig: ModelConfig(model: 'claude-test'));

      final body = _asJsonMap(adapter.requests.single);
      final content =
          (body['messages'][0] as Map<String, dynamic>)['content'] as List;
      expect(content[0]['source'], {'type': 'url', 'url': href});
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

ResponseBody _claudeOk() {
  return ResponseBody.fromString(
    jsonEncode({
      'content': [
        {'type': 'text', 'text': 'ok'},
      ],
      'stop_reason': 'end_turn',
      'usage': {'input_tokens': 1, 'output_tokens': 1},
    }),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}
