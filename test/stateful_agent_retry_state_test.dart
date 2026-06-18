import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('failed run without progress rolls back incoming messages', () async {
    final state = AgentState.empty();
    var saveCount = 0;
    final agent = StatefulAgent(
      name: 'retry-test-agent',
      client: _ThrowingLLMClient(),
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
  });
}

class _ThrowingLLMClient extends LLMClient {
  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
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
