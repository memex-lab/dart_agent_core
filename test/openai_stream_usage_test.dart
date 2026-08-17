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

    final messages = await Stream<Map<String, dynamic>>.fromIterable(
      chunks,
    ).transform(OpenAIResponseTransformer(config)).toList();

    expect(
      messages.where((m) => m.textOutput != null).map((m) => m.textOutput),
      ['Hi', ' there'],
    );
    expect(messages.any((m) => m.stopReason == 'stop'), isTrue);
    expect(messages.last.usage?.totalTokens, 3);
  });

  test(
    'still yields usage-only terminal chunks (OpenAI include_usage)',
    () async {
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

      final messages = await Stream<Map<String, dynamic>>.fromIterable(
        chunks,
      ).transform(OpenAIResponseTransformer(config)).toList();

      expect(messages.first.textOutput, 'ok');
      expect(messages.last.usage?.totalTokens, 5);
    },
  );

  test('keeps content, finish reason, and usage from the same chunk', () async {
    final chunks = <Map<String, dynamic>>[
      {
        'choices': [
          {
            'index': 0,
            'delta': {'content': 'final answer'},
            'finish_reason': 'stop',
          },
        ],
        'usage': {
          'prompt_tokens': 4,
          'completion_tokens': 2,
          'total_tokens': 6,
        },
      },
    ];

    final messages = await Stream<Map<String, dynamic>>.fromIterable(
      chunks,
    ).transform(OpenAIResponseTransformer(config)).toList();

    expect(
      messages.where((m) => m.textOutput != null).single.textOutput,
      'final answer',
    );
    final terminal = messages.singleWhere((m) => m.stopReason == 'stop');
    expect(terminal.usage?.promptTokens, 4);
    expect(terminal.usage?.completionTokens, 2);
    expect(terminal.usage?.totalTokens, 6);
  });

  test('combines a pending finish reason with the final usage chunk', () async {
    final chunks = <Map<String, dynamic>>[
      {
        'choices': [
          {
            'index': 0,
            'delta': {'content': 'done'},
            'finish_reason': 'stop',
          },
        ],
        'usage': {
          'prompt_tokens': 10,
          'completion_tokens': 2,
          'total_tokens': 12,
        },
      },
      {
        'choices': <dynamic>[],
        'usage': {
          'prompt_tokens': 10,
          'completion_tokens': 3,
          'total_tokens': 13,
        },
      },
    ];

    final messages = await Stream<Map<String, dynamic>>.fromIterable(
      chunks,
    ).transform(OpenAIResponseTransformer(config)).toList();

    expect(
      messages.where((m) => m.textOutput != null).single.textOutput,
      'done',
    );
    expect(messages.where((m) => m.stopReason != null), hasLength(1));
    expect(messages.last.stopReason, 'stop');
    expect(messages.last.usage?.completionTokens, 3);
    expect(messages.last.usage?.totalTokens, 13);
  });

  test(
    'keeps content, reasoning, tool calls, finish reason, and usage together',
    () async {
      final chunks = <Map<String, dynamic>>[
        {
          'choices': [
            {
              'index': 0,
              'delta': {
                'content': 'calling tool',
                'reasoning_content': 'need external data',
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_1',
                    'function': {
                      'name': 'lookup',
                      'arguments': '{"query":"dart"}',
                    },
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
          'usage': {
            'prompt_tokens': 8,
            'completion_tokens': 5,
            'total_tokens': 13,
            'completion_tokens_details': {'reasoning_tokens': 2},
          },
        },
      ];

      final messages = await Stream<Map<String, dynamic>>.fromIterable(
        chunks,
      ).transform(OpenAIResponseTransformer(config)).toList();

      expect(
        messages.where((m) => m.textOutput != null).single.textOutput,
        'calling tool',
      );
      expect(
        messages.where((m) => m.thought != null).single.thought,
        'need external data',
      );

      final terminal = messages.singleWhere(
        (m) => m.stopReason == 'tool_calls',
      );
      expect(terminal.functionCalls, hasLength(1));
      expect(terminal.functionCalls.single.id, 'call_1');
      expect(terminal.functionCalls.single.name, 'lookup');
      expect(terminal.functionCalls.single.arguments, '{"query":"dart"}');
      expect(terminal.usage?.totalTokens, 13);
      expect(terminal.usage?.thoughtToken, 2);
    },
  );
}
