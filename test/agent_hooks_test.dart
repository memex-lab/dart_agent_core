import 'dart:async';
import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  test(
    'beforeModelCall can persist injected messages into later loops',
    () async {
      final client = _CapturingLLMClient([
        _toolCallReply('echo', {'value': 'first'}),
        _textReply('done'),
      ]);
      final state = AgentState.empty();
      final agent = StatefulAgent(
        name: 'hooked',
        client: client,
        modelConfig: ModelConfig(model: 'fake-model'),
        state: state,
        withGeneralPrinciples: false,
        disableSubAgents: true,
        tools: [
          Tool(
            name: 'echo',
            description: 'echo',
            parameters: const {
              'type': 'object',
              'properties': {
                'value': {'type': 'string'},
              },
            },
            parameterMode: ToolParameterMode.object,
            executable: (Map<String, dynamic> args) => args['value'],
          ),
        ],
        hooks: [_RewriteModelInputHook()],
      );

      await agent.run([UserMessage.text('hello')], useStream: false);

      final firstCallMessages = client.capturedMessages.first;
      expect(firstCallMessages.first, isA<SystemMessage>());
      expect((firstCallMessages.first as SystemMessage).content, 'hook system');
      expect(_userText(firstCallMessages.last as UserMessage), 'hook context');

      final secondCallMessages = client.capturedMessages[1];
      expect(
        secondCallMessages.whereType<UserMessage>().map(_userText),
        contains('hook context'),
      );
      expect(
        state.history.messages.whereType<UserMessage>().map(_userText),
        contains('hook context'),
      );
    },
  );

  test(
    'beforeToolCall can deny with synthetic result without executing tool',
    () async {
      var executed = false;
      final client = _CapturingLLMClient([
        _toolCallReply('danger', {'value': 'secret'}),
        _textReply('done'),
      ]);
      final state = AgentState.empty();
      final agent = StatefulAgent(
        name: 'hooked',
        client: client,
        modelConfig: ModelConfig(model: 'fake-model'),
        state: state,
        withGeneralPrinciples: false,
        disableSubAgents: true,
        tools: [
          Tool(
            name: 'danger',
            description: 'dangerous tool',
            parameters: const {
              'type': 'object',
              'properties': {
                'value': {'type': 'string'},
              },
            },
            parameterMode: ToolParameterMode.object,
            executable: (Map<String, dynamic> _) {
              executed = true;
              return 'executed';
            },
          ),
        ],
        hooks: [_DenyDangerToolHook()],
      );

      await agent.run([UserMessage.text('run tool')], useStream: false);

      expect(executed, isFalse);
      final toolMessage = state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .single;
      final result = toolMessage.results.single;
      expect(result.name, 'danger');
      expect(result.isError, isTrue);
      expect((result.content.single as TextPart).text, 'blocked');
    },
  );

  test('beforeToolCall can rewrite tool arguments before execution', () async {
    String? seenValue;
    final client = _CapturingLLMClient([
      _toolCallReply('echo', {'value': 'old'}),
      _textReply('done'),
    ]);
    final agent = StatefulAgent(
      name: 'hooked',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      withGeneralPrinciples: false,
      disableSubAgents: true,
      tools: [
        Tool(
          name: 'echo',
          description: 'echo',
          parameters: const {
            'type': 'object',
            'properties': {
              'value': {'type': 'string'},
            },
          },
          parameterMode: ToolParameterMode.object,
          executable: (Map<String, dynamic> args) {
            seenValue = args['value'] as String?;
            return 'ok';
          },
        ),
      ],
      hooks: [_RewriteToolArgumentsHook()],
    );

    await agent.run([UserMessage.text('run tool')], useStream: false);

    expect(seenValue, 'new');
  });

  test(
    'onTurnCompletion can continue the run with follow-up messages',
    () async {
      final client = _CapturingLLMClient([
        _textReply('first'),
        _textReply('second'),
      ]);
      final state = AgentState.empty();
      final agent = StatefulAgent(
        name: 'hooked',
        client: client,
        modelConfig: ModelConfig(model: 'fake-model'),
        state: state,
        withGeneralPrinciples: false,
        disableSubAgents: true,
        hooks: [_ContinueOnceHook()],
      );

      final responses = await agent.run([
        UserMessage.text('start'),
      ], useStream: false);

      expect(client.generateCalls, 2);
      expect(responses.whereType<ModelMessage>().map((m) => m.textOutput), [
        'first',
        'second',
      ]);
      expect(
        state.history.messages.whereType<UserMessage>().map(_userText),
        contains('continue'),
      );
    },
  );

  test('beforeRun can rewrite input and afterRun observes success', () async {
    final client = _CapturingLLMClient([_textReply('done')]);
    final state = AgentState.empty();
    final afterRun = _AfterRunRecorderHook();
    final agent = StatefulAgent(
      name: 'hooked',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: state,
      withGeneralPrinciples: false,
      disableSubAgents: true,
      hooks: [_RewriteRunInputHook(), afterRun],
    );

    await agent.run([UserMessage.text('original')], useStream: false);

    expect(
      client.capturedMessages.single.whereType<UserMessage>().map(_userText),
      contains('rewritten input'),
    );
    expect(
      state.history.messages.whereType<UserMessage>().map(_userText),
      contains('rewritten input'),
    );
    expect(afterRun.errors, [null]);
    expect(afterRun.inputs.single.whereType<UserMessage>().map(_userText), [
      'rewritten input',
    ]);
  });

  test('beforeModelCall can respond without calling the model', () async {
    final client = _CapturingLLMClient([]);
    final state = AgentState.empty();
    final agent = StatefulAgent(
      name: 'hooked',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: state,
      withGeneralPrinciples: false,
      disableSubAgents: true,
      hooks: [_SyntheticModelResponseHook()],
    );

    final responses = await agent.run([
      UserMessage.text('hello'),
    ], useStream: false);

    expect(client.generateCalls, 0);
    expect(client.streamCalls, 0);
    expect((responses.single as ModelMessage).textOutput, 'synthetic');
    expect(
      state.history.messages.whereType<UserMessage>().map(_userText),
      contains('persisted synthetic context'),
    );
  });

  test('onModelChunk can drop and rewrite streaming chunks', () async {
    final client = _StreamingChunksLLMClient([
      ModelMessage(textOutput: 'drop me', model: 'fake-model'),
      ModelMessage(textOutput: 'kept', model: 'fake-model', stopReason: 'stop'),
    ]);
    final agent = StatefulAgent(
      name: 'hooked',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      withGeneralPrinciples: false,
      disableSubAgents: true,
      hooks: [_ChunkTransformHook()],
    );

    final responses = await agent.run([UserMessage.text('hello')]);

    expect((responses.single as ModelMessage).textOutput, 'rewritten');
    expect(client.streamCalls, 1);
  });

  test('afterModelCall can retry and rewrite the final response', () async {
    final client = _CapturingLLMClient([
      _textReply('first'),
      _textReply('second'),
    ]);
    final agent = StatefulAgent(
      name: 'hooked',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      withGeneralPrinciples: false,
      disableSubAgents: true,
      hooks: [_RetryThenRewriteModelResponseHook()],
    );

    final responses = await agent.run([
      UserMessage.text('hello'),
    ], useStream: false);

    expect(client.generateCalls, 2);
    expect((responses.single as ModelMessage).textOutput, 'rewritten final');
  });

  test('beforeToolCall can defer with a synthetic result', () async {
    var executed = false;
    final client = _CapturingLLMClient([
      _toolCallReply('echo', {'value': 'defer'}),
      _textReply('done'),
    ]);
    final state = AgentState.empty();
    final agent = StatefulAgent(
      name: 'hooked',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: state,
      withGeneralPrinciples: false,
      disableSubAgents: true,
      tools: [
        _echoTool((_) {
          executed = true;
          return 'executed';
        }),
      ],
      hooks: [_DeferToolHook()],
    );

    await agent.run([UserMessage.text('run tool')], useStream: false);

    expect(executed, isFalse);
    final result = state.history.messages
        .whereType<FunctionExecutionResultMessage>()
        .single
        .results
        .single;
    expect(result.isError, isFalse);
    expect((result.content.single as TextPart).text, 'deferred');
  });

  test(
    'beforeToolCall denyWithResult preserves the original tool call id',
    () async {
      final client = _CapturingLLMClient([
        _toolCallReply('echo', {'value': 'deny'}),
        _textReply('done'),
      ]);
      final state = AgentState.empty();
      final agent = StatefulAgent(
        name: 'hooked',
        client: client,
        modelConfig: ModelConfig(model: 'fake-model'),
        state: state,
        withGeneralPrinciples: false,
        disableSubAgents: true,
        tools: [_echoTool((args) => args['value'])],
        hooks: [_DenyWithResultHook()],
      );

      await agent.run([UserMessage.text('run tool')], useStream: false);

      final result = state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .single
          .results
          .single;
      expect(result.id, 'call-1');
      expect(result.name, 'echo');
      expect(result.isError, isTrue);
      expect((result.content.single as TextPart).text, 'supplied denial');
    },
  );

  test('afterToolCall can rewrite result, inject messages, and stop', () async {
    final client = _CapturingLLMClient([
      _toolCallReply('echo', {'value': 'old'}),
      _textReply('should not be called'),
    ]);
    final state = AgentState.empty();
    final agent = StatefulAgent(
      name: 'hooked',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: state,
      withGeneralPrinciples: false,
      disableSubAgents: true,
      tools: [_echoTool((args) => args['value'])],
      hooks: [_RewriteToolResultAndStopHook()],
    );

    await agent.run([UserMessage.text('run tool')], useStream: false);

    expect(client.generateCalls, 1);
    final result = state.history.messages
        .whereType<FunctionExecutionResultMessage>()
        .single
        .results
        .single;
    expect((result.content.single as TextPart).text, 'changed result');
    expect(
      state.history.messages.whereType<UserMessage>().map(_userText),
      contains('injected after tool'),
    );
  });

  test('state persistence hooks wrap autoSaveStateFunc', () async {
    var beforePersistCount = 0;
    var afterPersistCount = 0;
    var saveCount = 0;
    final agent = StatefulAgent(
      name: 'hooked',
      client: _CapturingLLMClient([_textReply('done')]),
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      withGeneralPrinciples: false,
      disableSubAgents: true,
      autoSaveStateFunc: (_) {
        saveCount++;
      },
      hooks: [
        _PersistenceCountingHook(
          onBefore: () => beforePersistCount++,
          onAfter: () => afterPersistCount++,
        ),
      ],
    );

    await agent.run([UserMessage.text('hello')], useStream: false);

    expect(beforePersistCount, 1);
    expect(saveCount, 1);
    expect(afterPersistCount, 1);
  });

  test('beforePersistState can skip autoSaveStateFunc', () async {
    var saveCount = 0;
    var afterPersistCount = 0;
    final agent = StatefulAgent(
      name: 'hooked',
      client: _CapturingLLMClient([_textReply('done')]),
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      withGeneralPrinciples: false,
      disableSubAgents: true,
      autoSaveStateFunc: (_) {
        saveCount++;
      },
      hooks: [_SkipPersistenceHook(onAfter: () => afterPersistCount++)],
    );

    await agent.run([UserMessage.text('hello')], useStream: false);

    expect(saveCount, 0);
    expect(afterPersistCount, 0);
  });

  test(
    'abort actions surface AgentException and afterRun sees errors',
    () async {
      final phases = <String, _AbortCase>{
        'beforeRun': _AbortCase(
          hook: _AbortPhaseHook('beforeRun'),
          client: _CapturingLLMClient([_textReply('unused')]),
        ),
        'beforeModelCall': _AbortCase(
          hook: _AbortPhaseHook('beforeModelCall'),
          client: _CapturingLLMClient([_textReply('unused')]),
        ),
        'onModelChunk': _AbortCase(
          hook: _AbortPhaseHook('onModelChunk'),
          client: _CapturingLLMClient([_textReply('unused')]),
        ),
        'afterModelCall': _AbortCase(
          hook: _AbortPhaseHook('afterModelCall'),
          client: _CapturingLLMClient([_textReply('unused')]),
        ),
        'beforeToolCall': _AbortCase(
          hook: _AbortPhaseHook('beforeToolCall'),
          client: _CapturingLLMClient([
            _toolCallReply('echo', {'value': 'x'}),
          ]),
          tools: [_echoTool((args) => args['value'])],
        ),
        'afterToolCall': _AbortCase(
          hook: _AbortPhaseHook('afterToolCall'),
          client: _CapturingLLMClient([
            _toolCallReply('echo', {'value': 'x'}),
          ]),
          tools: [_echoTool((args) => args['value'])],
        ),
        'onTurnCompletion': _AbortCase(
          hook: _AbortPhaseHook('onTurnCompletion'),
          client: _CapturingLLMClient([_textReply('done')]),
        ),
        'beforePersistState': _AbortCase(
          hook: _AbortPhaseHook('beforePersistState'),
          client: _CapturingLLMClient([_textReply('done')]),
        ),
      };

      for (final entry in phases.entries) {
        final afterRun = _AfterRunRecorderHook();
        final agent = StatefulAgent(
          name: 'hooked_${entry.key}',
          client: entry.value.client,
          modelConfig: ModelConfig(model: 'fake-model'),
          state: AgentState.empty(),
          withGeneralPrinciples: false,
          disableSubAgents: true,
          tools: entry.value.tools,
          hooks: [entry.value.hook, afterRun],
        );

        await expectLater(
          agent.run([UserMessage.text('hello')], useStream: false),
          throwsA(
            isA<AgentException>()
                .having(
                  (e) => e.code,
                  'code',
                  AgentExceptionCode.stopByController,
                )
                .having((e) => e.message, 'message', contains(entry.key)),
          ),
        );
        if (entry.key == 'beforePersistState') {
          expect(afterRun.errors.single, isNull);
        } else {
          expect(afterRun.errors.single, isA<AgentException>());
        }
      }
    },
  );
}

class _CapturingLLMClient extends LLMClient {
  final List<ModelMessage> replies;
  final capturedMessages = <List<LLMMessage>>[];
  final capturedTools = <List<Tool>?>[];
  int generateCalls = 0;
  int streamCalls = 0;

  _CapturingLLMClient(this.replies);

  ModelMessage _next() =>
      replies[(generateCalls + streamCalls) % replies.length];

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
    capturedTools.add(tools == null ? null : List<Tool>.from(tools));
    final reply = _next();
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
    capturedMessages.add(List<LLMMessage>.from(messages));
    capturedTools.add(tools == null ? null : List<Tool>.from(tools));
    final reply = _next();
    streamCalls++;
    return Stream.value(StreamingMessage(modelMessage: reply));
  }
}

class _StreamingChunksLLMClient extends LLMClient {
  final List<ModelMessage> chunks;
  final capturedMessages = <List<LLMMessage>>[];
  int streamCalls = 0;

  _StreamingChunksLLMClient(this.chunks);

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) {
    throw UnimplementedError('stream-only test client');
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
    capturedMessages.add(List<LLMMessage>.from(messages));
    streamCalls++;
    return Stream.fromIterable(
      chunks.map((chunk) => StreamingMessage(modelMessage: chunk)),
    );
  }
}

class _RewriteModelInputHook extends AgentHook {
  bool _injected = false;

  @override
  ModelCallHookResult beforeModelCall(ModelCallHookContext context) {
    var request = context.request.copyWith(
      systemMessage: SystemMessage('hook system'),
    );
    if (_injected) {
      return ModelCallHookResult.proceed(request: request);
    }
    _injected = true;
    final persistedMessage = UserMessage.text('hook context');
    context.state.history.messages.add(persistedMessage);
    request = request.copyWith(
      requestMessages: [...request.requestMessages, persistedMessage],
    );
    return ModelCallHookResult.proceed(request: request);
  }
}

class _RewriteRunInputHook extends AgentHook {
  @override
  BeforeRunHookResult beforeRun(BeforeRunHookContext context) {
    return BeforeRunHookResult.proceed([UserMessage.text('rewritten input')]);
  }
}

class _SyntheticModelResponseHook extends AgentHook {
  @override
  ModelCallHookResult beforeModelCall(ModelCallHookContext context) {
    context.state.history.messages.add(
      UserMessage.text('persisted synthetic context'),
    );
    return ModelCallHookResult.respond(_textReply('synthetic'));
  }
}

class _ChunkTransformHook extends AgentHook {
  @override
  ModelChunkHookResult onModelChunk(ModelChunkHookContext context) {
    if (context.chunk.textOutput == 'drop me') {
      return const ModelChunkHookResult.drop(reason: 'test drop');
    }
    return ModelChunkHookResult.proceed(
      ModelMessage(
        textOutput: 'rewritten',
        model: context.chunk.model,
        stopReason: context.chunk.stopReason,
      ),
    );
  }
}

class _RetryThenRewriteModelResponseHook extends AgentHook {
  var _retried = false;

  @override
  ModelResponseHookResult afterModelCall(ModelResponseHookContext context) {
    if (!_retried) {
      _retried = true;
      return const ModelResponseHookResult.retry('test retry');
    }
    return ModelResponseHookResult.proceed(_textReply('rewritten final'));
  }
}

class _DenyDangerToolHook extends AgentHook {
  @override
  ToolCallHookResult beforeToolCall(ToolCallHookContext context) {
    return ToolCallHookResult.deny(content: [TextPart('blocked')]);
  }
}

class _RewriteToolArgumentsHook extends AgentHook {
  @override
  ToolCallHookResult beforeToolCall(ToolCallHookContext context) {
    return ToolCallHookResult.proceed(
      FunctionCall(
        id: context.call.id,
        name: context.call.name,
        arguments: jsonEncode({'value': 'new'}),
      ),
    );
  }
}

class _DeferToolHook extends AgentHook {
  @override
  ToolCallHookResult beforeToolCall(ToolCallHookContext context) {
    return ToolCallHookResult.defer(content: [TextPart('deferred')]);
  }
}

class _DenyWithResultHook extends AgentHook {
  @override
  ToolCallHookResult beforeToolCall(ToolCallHookContext context) {
    return ToolCallHookResult.denyWithResult(
      ExecutionToolResult(
        id: 'different-id',
        name: context.call.name,
        arguments: context.call.arguments,
        content: [TextPart('supplied denial')],
        isError: true,
      ),
    );
  }
}

class _RewriteToolResultAndStopHook extends AgentHook {
  @override
  ToolResultHookResult afterToolCall(ToolResultHookContext context) {
    return ToolResultHookResult.stop(
      result: FunctionExecutionResult(
        id: context.result.id,
        name: context.result.name,
        arguments: context.result.arguments,
        content: [TextPart('changed result')],
        isError: false,
      ),
      injectedMessages: [UserMessage.text('injected after tool')],
      reason: 'test stop',
    );
  }
}

class _ContinueOnceHook extends AgentHook {
  @override
  TurnCompletionHookResult onTurnCompletion(TurnCompletionHookContext context) {
    if (context.continuationCount > 0) {
      return const TurnCompletionHookResult.accept();
    }
    return TurnCompletionHookResult.continueWith([
      UserMessage.text('continue'),
    ]);
  }
}

class _PersistenceCountingHook extends AgentHook {
  final void Function() onBefore;
  final void Function() onAfter;

  _PersistenceCountingHook({required this.onBefore, required this.onAfter});

  @override
  StatePersistenceHookResult beforePersistState(
    StatePersistenceHookContext context,
  ) {
    onBefore();
    return const StatePersistenceHookResult.proceed();
  }

  @override
  void afterPersistState(StatePersistenceHookContext context) {
    onAfter();
  }
}

class _SkipPersistenceHook extends AgentHook {
  final void Function() onAfter;

  _SkipPersistenceHook({required this.onAfter});

  @override
  StatePersistenceHookResult beforePersistState(
    StatePersistenceHookContext context,
  ) {
    return const StatePersistenceHookResult.skip(reason: 'test skip');
  }

  @override
  void afterPersistState(StatePersistenceHookContext context) {
    onAfter();
  }
}

class _AfterRunRecorderHook extends AgentHook {
  final inputs = <List<LLMMessage>>[];
  final errors = <AgentException?>[];

  @override
  void afterRun(AfterRunHookContext context) {
    inputs.add(List<LLMMessage>.from(context.input));
    errors.add(context.error);
  }
}

class _AbortPhaseHook extends AgentHook {
  final String phase;

  _AbortPhaseHook(this.phase);

  @override
  FutureOr<BeforeRunHookResult> beforeRun(BeforeRunHookContext context) {
    if (phase == 'beforeRun') {
      return const BeforeRunHookResult.abort(reason: 'abort beforeRun');
    }
    return super.beforeRun(context);
  }

  @override
  FutureOr<ModelCallHookResult> beforeModelCall(ModelCallHookContext context) {
    if (phase == 'beforeModelCall') {
      return const ModelCallHookResult.abort(reason: 'abort beforeModelCall');
    }
    return super.beforeModelCall(context);
  }

  @override
  FutureOr<ModelChunkHookResult> onModelChunk(ModelChunkHookContext context) {
    if (phase == 'onModelChunk') {
      return const ModelChunkHookResult.abort(reason: 'abort onModelChunk');
    }
    return super.onModelChunk(context);
  }

  @override
  FutureOr<ModelResponseHookResult> afterModelCall(
    ModelResponseHookContext context,
  ) {
    if (phase == 'afterModelCall') {
      return const ModelResponseHookResult.abort(
        reason: 'abort afterModelCall',
      );
    }
    return super.afterModelCall(context);
  }

  @override
  FutureOr<ToolCallHookResult> beforeToolCall(ToolCallHookContext context) {
    if (phase == 'beforeToolCall') {
      return const ToolCallHookResult.abort(reason: 'abort beforeToolCall');
    }
    return super.beforeToolCall(context);
  }

  @override
  FutureOr<ToolResultHookResult> afterToolCall(ToolResultHookContext context) {
    if (phase == 'afterToolCall') {
      return const ToolResultHookResult.abort(reason: 'abort afterToolCall');
    }
    return super.afterToolCall(context);
  }

  @override
  FutureOr<TurnCompletionHookResult> onTurnCompletion(
    TurnCompletionHookContext context,
  ) {
    if (phase == 'onTurnCompletion') {
      return const TurnCompletionHookResult.abort(
        reason: 'abort onTurnCompletion',
      );
    }
    return super.onTurnCompletion(context);
  }

  @override
  FutureOr<StatePersistenceHookResult> beforePersistState(
    StatePersistenceHookContext context,
  ) {
    if (phase == 'beforePersistState') {
      return const StatePersistenceHookResult.abort(
        reason: 'abort beforePersistState',
      );
    }
    return super.beforePersistState(context);
  }
}

class _AbortCase {
  final AgentHook hook;
  final _CapturingLLMClient client;
  final List<Tool>? tools;

  const _AbortCase({required this.hook, required this.client, this.tools});
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

Tool _echoTool(dynamic Function(Map<String, dynamic> args) executable) {
  return Tool(
    name: 'echo',
    description: 'echo',
    parameters: const {
      'type': 'object',
      'properties': {
        'value': {'type': 'string'},
      },
      'required': ['value'],
    },
    parameterMode: ToolParameterMode.object,
    executable: executable,
  );
}

String _userText(UserMessage message) {
  return (message.contents.single as TextPart).text;
}
