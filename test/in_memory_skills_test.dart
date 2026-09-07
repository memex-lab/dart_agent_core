import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  test('deactivate_skills succeeds when activeSkills is still null', () async {
    final client = _QueuedLLMClient([
      _toolCallReply('deactivate_skills', {
        'skill_names': ['optional'],
      }),
      _textReply('done'),
    ]);
    final state = AgentState.empty();
    expect(state.activeSkills, isNull);

    final agent = _agent(
      client: client,
      state: state,
      skills: [
        _NamedSkill('optional'),
        _NamedSkill('core', forceActivate: true),
      ],
    );

    await agent.run([UserMessage.text('drop optional')], useStream: false);

    expect(state.activeSkills, isEmpty);
    expect(client.generateCalls, 2);
  });

  test('unknown activeSkills names do not crash composeTools', () async {
    final client = _QueuedLLMClient([_textReply('ok')]);
    final state = AgentState.empty()..activeSkills = ['deleted_skill'];
    final agent = _agent(
      client: client,
      state: state,
      skills: [
        _NamedSkill(
          'optional',
          tools: [
            Tool(
              name: 'optional_tool',
              description: 'optional',
              parameters: const {'type': 'object', 'properties': {}},
              parameterMode: ToolParameterMode.object,
              executable: (Map<String, dynamic> _) => 'optional',
            ),
          ],
        ),
      ],
    );

    expect(() => agent.composeTools(), returnsNormally);
    expect(
      agent.composeTools().map((tool) => tool.name),
      isNot(contains('optional_tool')),
    );

    await agent.run([UserMessage.text('hello')], useStream: false);
    expect(client.generateCalls, 1);
  });

  test('activate_skills adds optional tools on the next compose', () async {
    final client = _QueuedLLMClient([
      _toolCallReply('activate_skills', {
        'skill_names': ['search'],
      }),
      _textReply('activated'),
    ]);
    final searchTool = Tool(
      name: 'search_notes',
      description: 'search',
      parameters: const {'type': 'object', 'properties': {}},
      parameterMode: ToolParameterMode.object,
      executable: (Map<String, dynamic> _) => 'hit',
    );
    final agent = _agent(
      client: client,
      state: AgentState.empty(),
      skills: [
        _NamedSkill('search', tools: [searchTool]),
      ],
    );

    expect(
      agent.composeTools().map((tool) => tool.name),
      isNot(contains('search_notes')),
    );

    await agent.run([UserMessage.text('activate search')], useStream: false);

    expect(agent.state.activeSkills, contains('search'));
    expect(
      agent.composeTools().map((tool) => tool.name),
      contains('search_notes'),
    );
  });

  test(
    'forceActivate skills cannot be deactivated and stay in composeTools',
    () async {
      final client = _QueuedLLMClient([
        _toolCallReply('deactivate_skills', {
          'skill_names': ['core'],
        }),
        _textReply('still core'),
      ]);
      final coreTool = Tool(
        name: 'core_tool',
        description: 'core',
        parameters: const {'type': 'object', 'properties': {}},
        parameterMode: ToolParameterMode.object,
        executable: (Map<String, dynamic> _) => 'core',
      );
      final agent = _agent(
        client: client,
        state: AgentState.empty(),
        skills: [
          _NamedSkill('core', forceActivate: true, tools: [coreTool]),
          _NamedSkill('optional'),
        ],
      );

      await agent.run([UserMessage.text('drop core')], useStream: false);

      expect(
        agent.composeTools().map((tool) => tool.name),
        contains('core_tool'),
      );
      final result = agent.state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .single
          .results
          .single;
      expect(
        (result.content.single as TextPart).text,
        contains('force activated'),
      );
    },
  );

  test('skills and skillDirectoryPaths cannot be enabled together', () {
    expect(
      () => StatefulAgent(
        name: 'conflict',
        client: _QueuedLLMClient([_textReply('x')]),
        modelConfig: ModelConfig(model: 'fake-model'),
        state: AgentState.empty(),
        skills: [_NamedSkill('in-memory')],
        skillDirectoryPaths: ['/tmp/skills'],
        withGeneralPrinciples: false,
        disableSubAgents: true,
      ),
      throwsA(isA<AssertionError>()),
    );
  });
}

StatefulAgent _agent({
  required LLMClient client,
  required AgentState state,
  required List<Skill> skills,
}) {
  return StatefulAgent(
    name: 'skills',
    client: client,
    modelConfig: ModelConfig(model: 'fake-model'),
    state: state,
    skills: skills,
    withGeneralPrinciples: false,
    disableSubAgents: true,
  );
}

class _NamedSkill extends Skill {
  _NamedSkill(String name, {super.forceActivate, super.tools})
    : super(
        name: name,
        description: 'skill $name',
        systemPrompt: 'Use $name when relevant.',
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
