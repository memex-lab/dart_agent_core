import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'failed run without progress does not commit incoming messages',
    () async {
      final state = AgentState.empty();
      var saveCount = 0;
      final client = _ThrowingLLMClient();
      final agent = StatefulAgent(
        name: 'retry-test-agent',
        client: client,
        modelConfig: ModelConfig(model: 'test-model'),
        state: state,
        autoSaveStateFunc: (_) async {
          saveCount += 1;
        },
      );

      await expectLater(
        agent.run([UserMessage.text('same turn')], useStream: false),
        throwsA(isA<AgentException>()),
      );
      await expectLater(
        agent.run([UserMessage.text('same turn')], useStream: false),
        throwsA(isA<AgentException>()),
      );

      expect(saveCount, 2);
      expect(state.history.messages, isEmpty);
      expect(state.systemPromptHistory, isEmpty);
      expect(state.toolsHistory, isEmpty);
      expect(state.isRunning, isFalse);
      expect(client.generateCount, 2);
      expect(
        client.userMessageCounts,
        everyElement(1),
        reason:
            'incoming message should still be sent once per attempted request',
      );
    },
  );

  test(
    'successful run commits pending incoming messages with model response',
    () async {
      final state = AgentState.empty();
      final agent = StatefulAgent(
        name: 'success-test-agent',
        client: _SuccessfulLLMClient(),
        modelConfig: ModelConfig(model: 'test-model'),
        state: state,
      );

      await agent.run([UserMessage.text('hello')], useStream: false);

      expect(state.history.messages, hasLength(2));
      expect(state.history.messages[0], isA<UserMessage>());
      expect(state.history.messages[1], isA<ModelMessage>());
    },
  );
}

class _ThrowingLLMClient extends LLMClient {
  int generateCount = 0;
  final List<int> messageCounts = [];
  final List<int> userMessageCounts = [];

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    generateCount += 1;
    messageCounts.add(messages.length);
    userMessageCounts.add(messages.whereType<UserMessage>().length);
    throw Exception('synthetic failure');
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    throw Exception('synthetic failure');
  }
}

class _SuccessfulLLMClient extends LLMClient {
  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    return ModelMessage(
      model: modelConfig.model,
      textOutput: 'done',
      stopReason: 'stop',
    );
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    throw UnimplementedError();
  }
}
