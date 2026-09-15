import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  for (final stop in ['budget', 'hook']) {
    test('actual worker $stop stop lets the parent recover', () async {
      final client = _QueuedLLMClient([
        _toolCallReply('delegate_task', {
          'assignee': 'worker',
          'task_description': 'go',
        }),
        _textReply('parent recovered'),
      ]);
      final workerClient = _QueuedLLMClient([]);
      final parent = StatefulAgent(
        name: 'parent',
        client: client,
        modelConfig: ModelConfig(model: 'fake-model'),
        state: AgentState.empty(),
        withGeneralPrinciples: false,
        subAgents: [
          SubAgent(
            name: 'worker',
            description: 'worker',
            agentFactory: (_) => StatefulAgent(
              name: 'worker',
              client: workerClient,
              modelConfig: ModelConfig(model: 'fake-model'),
              state: AgentState.empty(),
              isSubAgent: true,
              withGeneralPrinciples: false,
              maxTurns: stop == 'budget' ? 0 : 20,
              hooks: stop == 'hook' ? [_WorkerAbortHook()] : [],
            ),
          ),
        ],
      );
      await parent.run(
        [UserMessage.text('go')],
        useStream: false,
        cancelToken: CancelToken(),
      );
      expect(client.generateCalls, 2);
      expect(workerClient.generateCalls, 0);
      final result = parent.state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .single
          .results
          .single;
      expect(result.isError, isTrue);
      expect(result.metadata?['status'], 'error');
    });
  }

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
    expect(result.isError, isFalse);
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
      expect(
        agent.state.history.messages
            .whereType<FunctionExecutionResultMessage>()
            .single
            .results
            .single
            .isError,
        isTrue,
      );
      expect(client.generateCalls, 2);
    },
  );

  test('doc-shaped factory with only isSubAgent omits delegate_task', () {
    final worker = StatefulAgent(
      name: 'researcher',
      client: _QueuedLLMClient([]),
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      withGeneralPrinciples: false,
      isSubAgent: true,
    );

    expect(
      worker.composeTools().map((tool) => tool.name),
      isNot(contains('delegate_task')),
    );
    expect(
      worker.composeSystemMessage()?.content ?? '',
      isNot(contains('delegate_task')),
    );
  });

  test(
    'named doc-shaped factory gets sub_agent_mode metadata on delegate',
    () async {
      final client = _QueuedLLMClient([
        _toolCallReply('delegate_task', {
          'assignee': 'researcher',
          'task_description': 'Look it up.',
        }),
        _textReply('research done'),
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
            name: 'researcher',
            description: 'Researches',
            agentFactory: (parent) {
              worker = StatefulAgent(
                name: 'researcher',
                client: parent.client,
                modelConfig: parent.modelConfig,
                state: AgentState(sessionId: 'worker-doc'),
                withGeneralPrinciples: false,
                isSubAgent: true,
              );
              return worker;
            },
          ),
        ],
      );

      await agent.run([UserMessage.text('delegate')], useStream: false);

      expect(worker.state.metadata['sub_agent_mode'], isTrue);
      expect(worker.state.metadata['parent_session_id'], parentState.sessionId);
      expect(
        worker.composeTools().map((tool) => tool.name),
        isNot(contains('delegate_task')),
      );
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
    expect(
      agent.state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .single
          .results
          .single
          .isError,
      isTrue,
    );
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

  test(
    'cancel during worker run propagates AgentException.cancelled to parent',
    () async {
      final cancelToken = CancelToken();
      final client = _CancelOnWorkerGenerateClient([
        _toolCallReply('delegate_task', {
          'assignee': 'QA_Expert',
          'task_description': 'Review.',
        }),
      ], cancelToken);
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
              state: AgentState(
                sessionId: 'worker-cancel',
                metadata: {'sub_agent_mode': true},
              ),
              withGeneralPrinciples: false,
              disableSubAgents: true,
              isSubAgent: true,
            ),
          ),
        ],
      );

      await expectLater(
        agent.run(
          [UserMessage.text('delegate')],
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
      expect(client.generateCalls, 2);
      expect(
        agent.state.history.messages
            .whereType<FunctionExecutionResultMessage>(),
        isEmpty,
      );
    },
  );

  test(
    'ordinary worker failure remains a soft tool error for the parent',
    () async {
      final client = _FailingWorkerThenParentClient([
        _toolCallReply('delegate_task', {
          'assignee': 'QA_Expert',
          'task_description': 'Review.',
        }),
        _textReply('parent recovered'),
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
              state: AgentState(
                sessionId: 'worker-fail',
                metadata: {'sub_agent_mode': true},
              ),
              withGeneralPrinciples: false,
              disableSubAgents: true,
              isSubAgent: true,
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
      expect(text, contains('execution failed'));
      expect(text, contains('boom'));
      expect(
        agent.state.history.messages
            .whereType<FunctionExecutionResultMessage>()
            .single
            .results
            .single
            .isError,
        isTrue,
      );
      expect(client.generateCalls, 3);
    },
  );

  for (final code in AgentExceptionCode.values) {
    test('worker-local $code remains recoverable', () async {
      final client = _ThrowOnWorkerGenerateClient(
        parentThenRecover: [
          _toolCallReply('delegate_task', {
            'assignee': 'QA_Expert',
            'task_description': 'Review.',
          }),
          _textReply('parent recovered'),
        ],
        workerError: AgentException(code, 'worker stopped locally'),
      );
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
              state: AgentState(
                sessionId: 'worker-loop',
                metadata: {'sub_agent_mode': true},
              ),
              withGeneralPrinciples: false,
              disableSubAgents: true,
              isSubAgent: true,
            ),
          ),
        ],
      );

      await agent.run([UserMessage.text('delegate')], useStream: false);
      final result = agent.state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .single
          .results
          .single;
      expect(result.isError, isTrue);
      expect(result.metadata?['status'], 'error');
      expect(
        (result.content.single as TextPart).text,
        contains('worker stopped locally'),
      );
      expect(client.workerThrows, 1);
      expect(client.parentRecoverCalls, 1);
    });
  }
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

/// Parent generate returns [replies.first]; worker generate cancels the token
/// and throws the cancel DioException so the worker surfaces cancelled.
class _CancelOnWorkerGenerateClient extends _QueuedLLMClient {
  final CancelToken tokenToCancel;

  _CancelOnWorkerGenerateClient(super.replies, this.tokenToCancel);

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
    if (generateCalls == 0) {
      return replies[generateCalls++];
    }
    generateCalls++;
    tokenToCancel.cancel('user cancelled');
    throw tokenToCancel.cancelError!;
  }
}

/// Parent tool-call reply, then worker throws, then parent recovery text.
///
/// [replies] is `[parentToolCall, parentRecoveryText]`. The worker call sits
/// between them and always throws `Exception('boom')`.
class _FailingWorkerThenParentClient extends _QueuedLLMClient {
  _FailingWorkerThenParentClient(super.replies);

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
    final callIndex = generateCalls++;
    if (callIndex == 1) {
      throw Exception('boom');
    }
    final replyIndex = callIndex == 0 ? 0 : callIndex - 1;
    if (replyIndex >= replies.length) {
      throw StateError('Unexpected extra generate() call');
    }
    return replies[replyIndex];
  }
}

/// First parent call returns [parentThenRecover.first]; worker throws
/// [workerError]; if the parent keeps running it consumes further recovery
/// replies (used to prove soft-swallow vs propagate).
class _ThrowOnWorkerGenerateClient extends LLMClient {
  final List<ModelMessage> parentThenRecover;
  final Object workerError;
  final capturedMessages = <List<LLMMessage>>[];
  int generateCalls = 0;
  int workerThrows = 0;
  int parentRecoverCalls = 0;

  _ThrowOnWorkerGenerateClient({
    required this.parentThenRecover,
    required this.workerError,
  });

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
    final callIndex = generateCalls++;
    if (callIndex == 0) {
      return parentThenRecover[0];
    }
    if (callIndex == 1) {
      workerThrows++;
      throw workerError;
    }
    parentRecoverCalls++;
    final recoverIndex = callIndex - 1;
    if (recoverIndex >= parentThenRecover.length) {
      throw StateError('Unexpected extra generate() call');
    }
    return parentThenRecover[recoverIndex];
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

class _WorkerAbortHook extends AgentHook {
  @override
  BeforeRunHookResult beforeRun(BeforeRunHookContext context) =>
      const BeforeRunHookResult.abort(reason: 'worker stopped locally');
}
