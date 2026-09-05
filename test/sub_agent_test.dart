import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  test('named sub-agent runs and returns the worker text', () async {
    final client = _QueuedLLMClient([
      _toolCallReply('delegate_task', {
        'assignee': 'QA_Expert',
        'task_description': 'Review the plan.',
      }),
      _textReply('qa done'),
      _textReply('parent done'),
    ]);
    final parentState = AgentState.empty();
    late StatefulAgent worker;
    final agent = StatefulAgent(
      name: 'manager',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: parentState,
      withGeneralPrinciples: false,
      subAgents: [
        SubAgent(
          name: 'QA_Expert',
          description: 'Reviews work',
          agentFactory: (parent) {
            worker = StatefulAgent(
              name: 'qa',
              client: parent.client,
              modelConfig: parent.modelConfig,
              state: AgentState(
                sessionId: 'worker-1',
                metadata: {'sub_agent_mode': true},
              ),
              withGeneralPrinciples: false,
              disableSubAgents: true,
              isSubAgent: true,
            );
            return worker;
          },
        ),
      ],
    );

    await agent.run([UserMessage.text('delegate')], useStream: false);

    expect(client.generateCalls, 3);
    final result = parentState.history.messages
        .whereType<FunctionExecutionResultMessage>()
        .single
        .results
        .single;
    expect((result.content.single as TextPart).text, contains('qa done'));
    expect(worker.isSubAgent, isTrue);
    expect(
      worker.composeTools().map((tool) => tool.name),
      isNot(contains('delegate_task')),
    );
  });

  test(
    'unknown assignee returns a soft error without calling a worker',
    () async {
      final client = _QueuedLLMClient([
        _toolCallReply('delegate_task', {
          'assignee': 'missing',
          'task_description': 'Go',
        }),
        _textReply('ok'),
      ]);
      final agent = StatefulAgent(
        name: 'manager',
        client: client,
        modelConfig: ModelConfig(model: 'fake-model'),
        state: AgentState.empty(),
        withGeneralPrinciples: false,
        subAgents: const [],
      );

      await agent.run([UserMessage.text('delegate')], useStream: false);

      final text =
          (agent.state.history.messages
                      .whereType<FunctionExecutionResultMessage>()
                      .single
                      .results
                      .single
                      .content
                      .single
                  as TextPart)
              .text;
      expect(text, contains('not found in registry'));
      expect(client.generateCalls, 2);
    },
  );

  test('named factory that forgets isSubAgent is rejected', () async {
    final client = _QueuedLLMClient([
      _toolCallReply('delegate_task', {
        'assignee': 'QA_Expert',
        'task_description': 'Go',
      }),
      _textReply('ok'),
    ]);
    final agent = StatefulAgent(
      name: 'manager',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      withGeneralPrinciples: false,
      subAgents: [
        SubAgent(
          name: 'QA_Expert',
          description: 'Reviews work',
          agentFactory: (parent) => StatefulAgent(
            name: 'qa',
            client: parent.client,
            modelConfig: parent.modelConfig,
            state: AgentState.empty(),
            withGeneralPrinciples: false,
            disableSubAgents: true,
          ),
        ),
      ],
    );

    await agent.run([UserMessage.text('delegate')], useStream: false);

    final text =
        (agent.state.history.messages
                    .whereType<FunctionExecutionResultMessage>()
                    .single
                    .results
                    .single
                    .content
                    .single
                as TextPart)
            .text;
    expect(text, contains('is not available'));
    expect(client.generateCalls, 2);
  });

  test('clone copies recent parent history into the worker snapshot', () async {
    final client = _QueuedLLMClient([
      _toolCallReply('delegate_task', {
        'assignee': 'clone',
        'task_description': 'Summarize.',
      }),
      _textReply('clone done'),
      _textReply('parent done'),
    ]);
    final state = AgentState.empty();
    for (var i = 0; i < 3; i++) {
      state.history.messages.add(UserMessage.text('prior-$i'));
    }
    final agent = StatefulAgent(
      name: 'manager',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: state,
      withGeneralPrinciples: false,
    );

    await agent.run([UserMessage.text('delegate')], useStream: false);

    final workerMessages = client.capturedMessages[1];
    final joined = workerMessages
        .whereType<UserMessage>()
        .map((m) => (m.contents.single as TextPart).text)
        .join('\n');
    expect(joined, contains('parent_agent_state_snapshot'));
    expect(joined, contains('prior-0'));
    expect(joined, contains('Summarize.'));
  });
}

class _QueuedLLMClient extends LLMClient {
  final List<ModelMessage> replies;
  final capturedMessages = <List<LLMMessage>>[];
  int generateCalls = 0;

  _QueuedLLMClient(this.replies);

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    capturedMessages.add(List<LLMMessage>.from(messages));
    if (generateCalls >= replies.length) {
      throw StateError('Unexpected extra generate() call');
    }
    return replies[generateCalls++];
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    return Stream.value(
      StreamingMessage(
        modelMessage: await generate(
          messages,
          tools: tools,
          toolChoice: toolChoice,
          modelConfig: modelConfig,
          jsonOutput: jsonOutput,
          cancelToken: cancelToken,
        ),
      ),
    );
  }
}

ModelMessage _textReply(String text) {
  return ModelMessage(
    textOutput: text,
    model: 'fake-model',
    stopReason: 'stop',
  );
}

ModelMessage _toolCallReply(String name, Map<String, dynamic> arguments) {
  return ModelMessage(
    model: 'fake-model',
    stopReason: 'tool_calls',
    functionCalls: [
      FunctionCall(id: 'call-1', name: name, arguments: jsonEncode(arguments)),
    ],
  );
}
