import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:test/test.dart';

void main() {
  final config = ModelConfig(model: 'test-model');

  test('keeps content when usage is present on every chunk', () async {
    final chunks = <Map<String, dynamic>>[
      {
        'id': '1',
        'object': 'chat.completion.chunk',
        'choices': [
          {
            'index': 0,
            'delta': {'content': 'Hi'},
            'finish_reason': null,
          },
        ],
        'usage': {
          'prompt_tokens': 1,
          'completion_tokens': 1,
          'total_tokens': 2,
        },
      },
      {
        'id': '1',
        'choices': [
          {
            'index': 0,
            'delta': {'content': ' there'},
            'finish_reason': null,
          },
        ],
        'usage': {
          'prompt_tokens': 1,
          'completion_tokens': 2,
          'total_tokens': 3,
        },
      },
      {
        'id': '1',
        'choices': [
          {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
        ],
        'usage': {
          'prompt_tokens': 1,
          'completion_tokens': 2,
          'total_tokens': 3,
        },
      },
    ];

    final messages = await Stream<Map<String, dynamic>>.fromIterable(chunks)
        .transform(OpenAIResponseTransformer(config))
        .toList();

    expect(
      messages.where((m) => m.textOutput != null).map((m) => m.textOutput),
      ['Hi', ' there'],
    );
    expect(messages.any((m) => m.stopReason == 'stop'), isTrue);
  });

  test('still yields usage-only terminal chunks (OpenAI include_usage)', () async {
    final chunks = <Map<String, dynamic>>[
      {
        'choices': [
          {
            'index': 0,
            'delta': {'content': 'ok'},
            'finish_reason': null,
          },
        ],
      },
      {
        'choices': <dynamic>[],
        'usage': {
          'prompt_tokens': 4,
          'completion_tokens': 1,
          'total_tokens': 5,
        },
      },
    ];

    final messages = await Stream<Map<String, dynamic>>.fromIterable(chunks)
        .transform(OpenAIResponseTransformer(config))
        .toList();

    expect(messages.first.textOutput, 'ok');
    expect(messages.last.usage?.totalTokens, 5);
  });
}
