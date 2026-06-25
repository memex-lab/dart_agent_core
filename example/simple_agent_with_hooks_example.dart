import 'dart:async';
import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';

void main() async {
  var saveCount = 0;
  final state = AgentState.empty();
  final agent = StatefulAgent(
    name: 'hooks_demo_agent',
    client: _ScriptedClient([
      _toolCallReply('echo', {'value': 'first'}),
      _toolCallReply('delete_file', {'path': '/tmp/demo.txt'}),
      _textReply('ready to continue'),
      _textReply('done'),
    ]),
    modelConfig: ModelConfig(model: 'scripted-model'),
    state: state,
    withGeneralPrinciples: false,
    disableSubAgents: true,
    tools: [
      Tool(
        name: 'echo',
        description: 'Echo a value.',
        parameterMode: ToolParameterMode.object,
        parameters: const {
          'type': 'object',
          'properties': {
            'value': {'type': 'string'},
          },
          'required': ['value'],
        },
        executable: (Map<String, dynamic> args) => 'echo:${args['value']}',
      ),
      Tool(
        name: 'delete_file',
        description: 'Delete a file.',
        parameterMode: ToolParameterMode.object,
        parameters: const {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
        },
        executable: (_) => 'deleted',
      ),
    ],
    hooks: [_DemoHook()],
    autoSaveStateFunc: (_) {
      saveCount++;
    },
  );

  final responses = await agent.run([
    UserMessage.text('Run the hooks demo.'),
  ], useStream: false);

  print('Responses:');
  for (final response in responses) {
    if (response is ModelMessage) {
      if (response.functionCalls.isNotEmpty) {
        for (final call in response.functionCalls) {
          print('  model requested ${call.name}: ${call.arguments}');
        }
      } else {
        print('  model: ${response.textOutput}');
      }
    } else if (response is FunctionExecutionResultMessage) {
      for (final result in response.results) {
        final text = result.content.whereType<TextPart>().map((p) => p.text);
        print('  tool ${result.name}: ${text.join(' ')}');
      }
    }
  }
  print('Saved state $saveCount time(s).');
  print('Persisted user messages:');
  for (final message in state.history.messages.whereType<UserMessage>()) {
    final text = message.contents.whereType<TextPart>().map((p) => p.text);
    print('  ${text.join(' ')}');
  }
}

class _DemoHook extends AgentHook {
  var _modelContextInjected = false;
  var _continued = false;

  @override
  ModelCallHookResult beforeModelCall(ModelCallHookContext context) {
    if (_modelContextInjected) {
      return ModelCallHookResult.proceed(request: context.request);
    }
    _modelContextInjected = true;
    final persistentContext = UserMessage.text('hook persisted context');
    context.state.history.messages.add(persistentContext);
    return ModelCallHookResult.proceed(
      request: context.request.copyWith(
        requestMessages: [
          ...context.request.requestMessages,
          persistentContext,
        ],
      ),
    );
  }

  @override
  ToolCallHookResult beforeToolCall(ToolCallHookContext context) {
    if (context.call.name != 'delete_file') {
      return ToolCallHookResult.proceed(context.call);
    }
    return ToolCallHookResult.deny(
      content: [TextPart('delete_file blocked by hook')],
    );
  }

  @override
  ToolResultHookResult afterToolCall(ToolResultHookContext context) {
    if (context.result.name != 'echo') {
      return ToolResultHookResult.proceed(result: context.result);
    }
    return ToolResultHookResult.proceed(
      result: FunctionExecutionResult(
        id: context.result.id,
        name: context.result.name,
        arguments: context.result.arguments,
        content: [TextPart('echo result rewritten by hook')],
        isError: false,
      ),
      injectedMessages: [UserMessage.text('hook injected after echo')],
    );
  }

  @override
  TurnCompletionHookResult onTurnCompletion(TurnCompletionHookContext context) {
    if (_continued) {
      return const TurnCompletionHookResult.accept();
    }
    _continued = true;
    return TurnCompletionHookResult.continueWith([
      UserMessage.text('hook requested one extra turn'),
    ]);
  }

  @override
  StatePersistenceHookResult beforePersistState(
    StatePersistenceHookContext context,
  ) {
    print('Persisting state because: ${context.reason}');
    return const StatePersistenceHookResult.proceed();
  }
}

class _ScriptedClient extends LLMClient {
  final List<ModelMessage> replies;
  var _index = 0;

  _ScriptedClient(this.replies);

  ModelMessage _next() {
    if (_index >= replies.length) {
      throw StateError('No scripted LLM reply left for hooks demo.');
    }
    return replies[_index++];
  }

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    return _next();
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
    return Stream.value(StreamingMessage(modelMessage: _next()));
  }
}

ModelMessage _textReply(String text) {
  return ModelMessage(
    textOutput: text,
    model: 'scripted-model',
    stopReason: 'stop',
  );
}

ModelMessage _toolCallReply(String name, Map<String, dynamic> arguments) {
  return ModelMessage(
    model: 'scripted-model',
    stopReason: 'tool_calls',
    functionCalls: [
      FunctionCall(
        id: 'call-$name',
        name: name,
        arguments: jsonEncode(arguments),
      ),
    ],
  );
}
