import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  test('stopFlag ends the loop without a second model call', () async {
    final client = _QueuedLLMClient([
      _toolCallReply('halt', {}),
      _textReply('should not run'),
    ]);
    final agent = _agent(
      client: client,
      tools: [
        Tool(
          name: 'halt',
          description: 'stop',
          parameters: const {'type': 'object', 'properties': {}},
          parameterMode: ToolParameterMode.object,
          executable: (Map<String, dynamic> _) =>
              AgentToolResult(content: TextPart('stopped'), stopFlag: true),
        ),
      ],
    );

    await agent.run([UserMessage.text('stop now')], useStream: false);

    expect(client.generateCalls, 1);
    expect(agent.state.isRunning, isFalse);
  });

  test('unknown tools and thrown executables become isError results', () async {
    var boomRan = false;
    final client = _QueuedLLMClient([
      ModelMessage(
        model: 'fake-model',
        stopReason: 'tool_calls',
        functionCalls: [
          FunctionCall(id: 'missing', name: 'missing_tool', arguments: '{}'),
          FunctionCall(id: 'boom', name: 'boom', arguments: '{}'),
        ],
      ),
      _textReply('recovered'),
    ]);
    final agent = _agent(
      client: client,
      tools: [
        Tool(
          name: 'boom',
          description: 'throws',
          parameters: const {'type': 'object', 'properties': {}},
          parameterMode: ToolParameterMode.object,
          executable: (Map<String, dynamic> _) {
            boomRan = true;
            throw StateError('boom');
          },
        ),
      ],
    );

    await agent.run([UserMessage.text('call both')], useStream: false);

    expect(boomRan, isTrue);
    final results = agent.state.history.messages
        .whereType<FunctionExecutionResultMessage>()
        .single
        .results;
    expect(results, hasLength(2));
    expect(results.every((result) => result.isError), isTrue);
    expect(client.generateCalls, 2);
  });

  test(
    'empty stopReason retries then succeeds without wrapping replies',
    () async {
      final client = _QueuedLLMClient([
        ModelMessage(model: 'fake-model', textOutput: 'partial'),
        ModelMessage(model: 'fake-model', textOutput: 'still partial'),
        _textReply('final'),
      ]);
      final agent = _agent(client: client);

      await agent.run([UserMessage.text('hello')], useStream: false);

      expect(client.generateCalls, 3);
      expect(
        (agent.state.history.messages.whereType<ModelMessage>().last)
            .textOutput,
        'final',
      );
    },
  );

  test('three empty stopReason retries throw loopDetection', () async {
    final client = _QueuedLLMClient([
      ModelMessage(model: 'fake-model', textOutput: 'a'),
      ModelMessage(model: 'fake-model', textOutput: 'b'),
      ModelMessage(model: 'fake-model', textOutput: 'c'),
    ]);
    final agent = _agent(client: client);

    await expectLater(
      agent.run([UserMessage.text('hello')], useStream: false),
      throwsA(
        isA<AgentException>().having(
          (e) => e.code,
          'code',
          AgentExceptionCode.loopDetection,
        ),
      ),
    );
    expect(client.generateCalls, 3);
    expect(agent.state.isRunning, isTrue);
  });

  test(
    'maxTurns throws loopDetection and resume starts a fresh budget',
    () async {
      final client = _RepeatingLLMClient(_toolCallReply('ping', {'n': 1}));
      final agent = _agent(
        client: client,
        maxTurns: 2,
        tools: [
          Tool(
            name: 'ping',
            description: 'ping',
            parameters: const {
              'type': 'object',
              'properties': {
                'n': {'type': 'integer'},
              },
            },
            parameterMode: ToolParameterMode.object,
            executable: (Map<String, dynamic> _) => 'pong',
          ),
        ],
      );

      await expectLater(
        agent.run([UserMessage.text('loop')], useStream: false),
        throwsA(
          isA<AgentException>().having(
            (e) => e.code,
            'code',
            AgentExceptionCode.loopDetection,
          ),
        ),
      );
      expect(agent.state.isRunning, isTrue);
      expect(agent.state.currentLoopCount, 2);

      client.reply = _textReply('resumed');
      await agent.resume(useStream: false);
      expect(agent.state.isRunning, isFalse);
      expect(agent.state.currentLoopCount, 1);
    },
  );

  test('cancel keeps isRunning so resume remains available', () async {
    final cancelToken = CancelToken();
    final client = _QueuedLLMClient([_textReply('never')]);
    final agent = _agent(client: client);
    cancelToken.cancel('user cancelled');

    await expectLater(
      agent.run(
        [UserMessage.text('hello')],
        useStream: false,
        cancelToken: cancelToken,
      ),
      throwsA(
        isA<AgentException>().having(
          (e) => e.code,
          'code',
          AgentExceptionCode.cancelled,
        ),
      ),
    );
    expect(agent.state.isRunning, isTrue);
    expect(client.generateCalls, 0);
  });

  test('PlanMode.auto injects write_todos and records PlanState', () async {
    final client = _QueuedLLMClient([
      _toolCallReply('write_todos', {
        'todos': [
          {'description': 'one', 'status': 'in_progress'},
        ],
      }),
      _textReply('planned'),
    ]);
    final agent = StatefulAgent(
      name: 'planner',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      planMode: PlanMode.auto,
      withGeneralPrinciples: false,
      disableSubAgents: true,
    );

    expect(
      agent.composeTools().map((tool) => tool.name),
      contains('write_todos'),
    );

    await agent.run([UserMessage.text('plan')], useStream: false);

    expect(agent.state.plan, isNotNull);
    expect(agent.state.plan!.steps.single.description, 'one');
    expect(agent.state.plan!.steps.single.status, StepStatus.inProgress);
  });
}

StatefulAgent _agent({
  required LLMClient client,
  List<Tool>? tools,
  int maxTurns = 20,
}) {
  return StatefulAgent(
    name: 'loop',
    client: client,
    modelConfig: ModelConfig(model: 'fake-model'),
    state: AgentState.empty(),
    tools: tools,
    maxTurns: maxTurns,
    withGeneralPrinciples: false,
    disableSubAgents: true,
  );
}

class _QueuedLLMClient extends LLMClient {
  final List<ModelMessage> replies;
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

class _RepeatingLLMClient extends LLMClient {
  ModelMessage reply;
  int generateCalls = 0;

  _RepeatingLLMClient(this.reply);

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    generateCalls++;
    return reply;
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
