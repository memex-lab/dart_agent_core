import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('OpenAIClient', () {
    test('deduplicates repeated tool call ids in the request body', () async {
      Map<String, dynamic>? capturedBody;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              capturedBody = Map<String, dynamic>.from(options.data as Map);
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'choices': [
                      {
                        'message': {'content': 'ok'},
                        'finish_reason': 'stop',
                      },
                    ],
                    'model': 'kimi-k2.6',
                  },
                ),
              );
            },
          ),
        );
      final client = OpenAIClient(apiKey: 'test', client: dio);

      await client.generate([
        ModelMessage(
          model: 'gemini',
          functionCalls: [
            FunctionCall(
              id: 'Glob:3',
              name: 'Glob',
              arguments: '{"pattern":"Cards/*.yaml"}',
            ),
          ],
        ),
        FunctionExecutionResultMessage(
          results: [
            FunctionExecutionResult(
              id: 'Glob:3',
              name: 'Glob',
              isError: false,
              arguments: '{"pattern":"Cards/*.yaml"}',
              content: [TextPart('first')],
            ),
          ],
        ),
        ModelMessage(
          model: 'gemini',
          functionCalls: [
            FunctionCall(
              id: 'Glob:3',
              name: 'Glob',
              arguments: '{"pattern":"PKM/*.md"}',
            ),
          ],
        ),
        FunctionExecutionResultMessage(
          results: [
            FunctionExecutionResult(
              id: 'Glob:3',
              name: 'Glob',
              isError: false,
              arguments: '{"pattern":"PKM/*.md"}',
              content: [TextPart('second')],
            ),
          ],
        ),
      ], modelConfig: ModelConfig(model: 'kimi-k2.6'));

      final messages = capturedBody!['messages'] as List;
      final toolCallIds = messages
          .where(
            (message) =>
                message is Map<String, dynamic> &&
                message['role'] == 'assistant' &&
                message['tool_calls'] != null,
          )
          .expand((message) => message['tool_calls'] as List)
          .map((toolCall) => toolCall['id'] as String)
          .toList();
      final toolResultIds = messages
          .where(
            (message) =>
                message is Map<String, dynamic> && message['role'] == 'tool',
          )
          .map((message) => message['tool_call_id'] as String)
          .toList();

      expect(toolCallIds.toSet(), hasLength(toolCallIds.length));
      expect(toolCallIds.first, 'Glob:3');
      expect(toolCallIds.last, isNot('Glob:3'));
      expect(toolCallIds.last, startsWith('memex_Glob_3_'));
      expect(toolResultIds, toolCallIds);
    });
  });
}
