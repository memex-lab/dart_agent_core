import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDirectory;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync(
      'dart_agent_core_directory_skills_',
    );
  });

  tearDown(() {
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  test('blank roots do not enable directory skill mode', () {
    final agent = _createAgent(
      skillDirectoryPaths: const ['', '   '],
      javaScriptRuntime: _RecordingJavaScriptRuntime(),
    );

    expect(
      agent.composeTools().where((tool) => tool.name == 'RunJavaScript'),
      isEmpty,
    );
  });

  test('blank roots do not conflict with in-memory skills', () {
    expect(
      () => StatefulAgent(
        name: 'directory-skills-test',
        client: _CapturingLLMClient(),
        modelConfig: ModelConfig(model: 'fake-model'),
        state: AgentState.empty(),
        skills: [_TestSkill()],
        skillDirectoryPaths: const ['   '],
      ),
      returnsNormally,
    );
  });

  test(
    'blank roots cannot expand JavaScript access to the working directory',
    () async {
      final allowedRoot = Directory('${tempDirectory.path}/allowed')
        ..createSync();
      final outsideScript = File(
        '${Directory.current.path}/.directory_skill_security_test_$pid.js',
      )..writeAsStringSync('// regression test');
      addTearDown(() {
        if (outsideScript.existsSync()) outsideScript.deleteSync();
      });
      final runtime = _RecordingJavaScriptRuntime();
      final agent = _createAgent(
        skillDirectoryPaths: [allowedRoot.path, '   '],
        javaScriptRuntime: runtime,
      );
      final runJavaScript = agent.composeTools().singleWhere(
        (tool) => tool.name == 'RunJavaScript',
      );

      final result =
          await Function.apply(runJavaScript.executable!, [
                outsideScript.absolute.path,
                null,
                null,
              ])
              as String;

      expect(
        result,
        contains('must stay under one of the skillDirectoryPaths'),
      );
      expect(runtime.executedPaths, isEmpty);
    },
  );

  test('overlapping roots inject the same skill only once', () async {
    final parentRoot = Directory('${tempDirectory.path}/skills')..createSync();
    final projectRoot = Directory('${parentRoot.path}/project')..createSync();
    final skillFile = _writeSkill(
      projectRoot,
      'demo',
      'Duplicate-root regression skill.',
    );
    final client = _CapturingLLMClient();
    final state = AgentState.empty();
    final agent = _createAgent(
      client: client,
      state: state,
      skillDirectoryPaths: [parentRoot.path, projectRoot.path],
    );

    await agent.run([UserMessage.text(r'Use $demo')], useStream: false);

    final injectedSkills = state.history.messages
        .whereType<UserMessage>()
        .where((message) => message.metadata?['type'] == 'skill_instructions')
        .toList();
    expect(injectedSkills, hasLength(1));
    expect(
      injectedSkills.single.metadata?['skill_path'],
      skillFile.absolute.path,
    );

    final systemPrompt = client.capturedMessages.single
        .whereType<SystemMessage>()
        .single
        .content;
    expect(
      RegExp('Duplicate-root regression skill').allMatches(systemPrompt),
      hasLength(1),
    );
  });

  test('a single valid root discovers and injects a named skill', () async {
    final root = Directory('${tempDirectory.path}/single')..createSync();
    final skillFile = _writeSkill(root, 'single', 'Single-root skill.');
    final state = AgentState.empty();
    final agent = _createAgent(state: state, skillDirectoryPaths: [root.path]);

    await agent.run([UserMessage.text(r'Use $single')], useStream: false);

    final injectedSkills = _injectedSkillMessages(state);
    expect(injectedSkills, hasLength(1));
    expect(
      injectedSkills.single.metadata?['skill_path'],
      skillFile.absolute.path,
    );
  });

  test('distinct roots discover and inject all named skills', () async {
    final systemRoot = Directory('${tempDirectory.path}/system')..createSync();
    final projectRoot = Directory('${tempDirectory.path}/project')
      ..createSync();
    final systemSkill = _writeSkill(
      systemRoot,
      'system_skill',
      'System-level skill.',
    );
    final projectSkill = _writeSkill(
      projectRoot,
      'project_skill',
      'Project-level skill.',
    );
    final state = AgentState.empty();
    final agent = _createAgent(
      state: state,
      skillDirectoryPaths: [systemRoot.path, projectRoot.path],
    );

    await agent.run([
      UserMessage.text(r'Use $system_skill and $project_skill'),
    ], useStream: false);

    expect(
      _injectedSkillMessages(
        state,
      ).map((message) => message.metadata?['skill_path']),
      unorderedEquals([systemSkill.absolute.path, projectSkill.absolute.path]),
    );
  });

  test(
    'JavaScript execution allows files inside roots and rejects outside files',
    () async {
      final root = Directory('${tempDirectory.path}/allowed')..createSync();
      final insideScript = File('${root.path}/inside.js')
        ..writeAsStringSync('// allowed');
      final outsideScript = File('${tempDirectory.path}/outside.js')
        ..writeAsStringSync('// rejected');
      final runtime = _RecordingJavaScriptRuntime();
      final agent = _createAgent(
        skillDirectoryPaths: [root.path],
        javaScriptRuntime: runtime,
      );
      final runJavaScript = agent.composeTools().singleWhere(
        (tool) => tool.name == 'RunJavaScript',
      );

      final insideResult =
          await Function.apply(runJavaScript.executable!, [
                insideScript.absolute.path,
                null,
                null,
              ])
              as String;
      final outsideResult =
          await Function.apply(runJavaScript.executable!, [
                outsideScript.absolute.path,
                null,
                null,
              ])
              as String;

      expect(jsonDecode(insideResult), containsPair('success', true));
      expect(outsideResult, contains('must stay under'));
      expect(runtime.executedPaths, [insideScript.absolute.path]);
    },
  );

  test(
    'agent loop executes RunJavaScript through the central tool path',
    () async {
      final root = Directory('${tempDirectory.path}/allowed')..createSync();
      final script = File('${root.path}/skill.js')
        ..writeAsStringSync('ctx.args.n');
      final runtime = _RecordingJavaScriptRuntime();
      final client = _CapturingLLMClient([
        _runJavaScriptCall(
          id: 'js-1',
          scriptPath: script.absolute.path,
          args: '{"n":1}',
        ),
        ModelMessage(
          model: 'fake-model',
          textOutput: 'done',
          stopReason: 'stop',
        ),
      ]);
      final agent = _createAgent(
        client: client,
        skillDirectoryPaths: [root.path],
        javaScriptRuntime: runtime,
      );

      await agent.run([
        UserMessage.text('Run the skill script.'),
      ], useStream: false);

      expect(runtime.executedPaths, [script.absolute.path]);
      expect(runtime.executedArgs, [
        {'n': 1},
      ]);
      expect(runtime.executionContexts.single?.agent, same(agent));
      expect(runtime.executionContexts.single?.state, same(agent.state));
      final toolResult = agent.state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .single
          .results
          .single;
      expect(toolResult.isError, isFalse);
      expect(
        jsonDecode((toolResult.content.single as TextPart).text),
        containsPair('success', true),
      );
    },
  );

  test('custom RunJavaScript tools use their registered executable', () async {
    var customToolCalls = 0;
    final client = _CapturingLLMClient([
      ModelMessage(
        model: 'fake-model',
        functionCalls: [
          FunctionCall(
            id: 'custom-js',
            name: 'RunJavaScript',
            arguments: jsonEncode({'value': 'custom'}),
          ),
        ],
        stopReason: 'tool_use',
      ),
      ModelMessage(model: 'fake-model', textOutput: 'done', stopReason: 'stop'),
    ]);
    final agent = _createAgent(
      client: client,
      skillDirectoryPaths: const [],
      tools: [
        Tool(
          name: 'RunJavaScript',
          description: 'A user-defined tool with the same name.',
          executable: (String value) {
            customToolCalls++;
            return 'custom:$value';
          },
          parameters: {
            'type': 'object',
            'properties': {
              'value': {'type': 'string'},
            },
            'required': ['value'],
          },
        ),
      ],
    );

    await agent.run([
      UserMessage.text('Run the custom JavaScript tool.'),
    ], useStream: false);

    expect(customToolCalls, 1);
    final toolResult = agent.state.history.messages
        .whereType<FunctionExecutionResultMessage>()
        .single
        .results
        .single;
    expect(toolResult.isError, isFalse);
    expect((toolResult.content.single as TextPart).text, 'custom:custom');
  });

  test('cancelled runs do not start registered tools', () async {
    var toolCalls = 0;
    final cancelToken = CancelToken();
    final client = _CancelAfterGenerateClient(cancelToken, [
      ModelMessage(
        model: 'fake-model',
        functionCalls: [
          FunctionCall(
            id: 'cancelled-tool',
            name: 'custom_tool',
            arguments: '{}',
          ),
        ],
        stopReason: 'tool_use',
      ),
    ]);
    final agent = _createAgent(
      client: client,
      skillDirectoryPaths: const [],
      tools: [
        Tool(
          name: 'custom_tool',
          description: 'Must not run after cancellation.',
          executable: () {
            toolCalls++;
            return 'unexpected';
          },
          parameters: const {'type': 'object', 'properties': {}},
        ),
      ],
    );

    await expectLater(
      agent.run(
        [UserMessage.text('Run then cancel.')],
        useStream: false,
        cancelToken: cancelToken,
      ),
      throwsA(
        isA<AgentException>().having(
          (error) => error.code,
          'code',
          AgentExceptionCode.cancelled,
        ),
      ),
    );
    expect(toolCalls, 0);
  });

  test(
    'agent loop sandbox rejects RunJavaScript paths outside skill roots',
    () async {
      final root = Directory('${tempDirectory.path}/allowed')..createSync();
      final outside = File('${tempDirectory.path}/outside.js')
        ..writeAsStringSync('// rejected');
      final runtime = _RecordingJavaScriptRuntime();
      final client = _CapturingLLMClient([
        _runJavaScriptCall(id: 'js-out', scriptPath: outside.absolute.path),
        ModelMessage(
          model: 'fake-model',
          textOutput: 'done',
          stopReason: 'stop',
        ),
      ]);
      final agent = _createAgent(
        client: client,
        skillDirectoryPaths: [root.path],
        javaScriptRuntime: runtime,
      );

      await agent.run([
        UserMessage.text('Run a script outside the skill root.'),
      ], useStream: false);

      expect(runtime.executedPaths, isEmpty);
      final toolResult = agent.state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .single
          .results
          .single;
      expect(toolResult.isError, isTrue);
      expect(
        (toolResult.content.single as TextPart).text,
        contains('must stay under one of the skillDirectoryPaths'),
      );
    },
  );

  test(
    'cancelled RunJavaScript does not start the JavaScript runtime',
    () async {
      final root = Directory('${tempDirectory.path}/allowed')..createSync();
      final script = File('${root.path}/skill.js')..writeAsStringSync('1');
      final runtime = _RecordingJavaScriptRuntime();
      final cancelToken = CancelToken();
      final client = _CancelAfterGenerateClient(cancelToken, [
        _runJavaScriptCall(id: 'js-cancel', scriptPath: script.absolute.path),
      ]);
      final agent = _createAgent(
        client: client,
        skillDirectoryPaths: [root.path],
        javaScriptRuntime: runtime,
      );

      await expectLater(
        agent.run(
          [UserMessage.text('Run then cancel.')],
          useStream: false,
          cancelToken: cancelToken,
        ),
        throwsA(
          isA<AgentException>().having(
            (error) => error.code,
            'code',
            AgentExceptionCode.cancelled,
          ),
        ),
      );
      expect(runtime.executedPaths, isEmpty);
    },
  );

  test('clone sub-agents inherit every configured skill root', () async {
    final systemRoot = Directory('${tempDirectory.path}/system')..createSync();
    final projectRoot = Directory('${tempDirectory.path}/project')
      ..createSync();
    _writeSkill(systemRoot, 'system_skill', 'Inherited system skill.');
    _writeSkill(projectRoot, 'project_skill', 'Inherited project skill.');
    final client = _CapturingLLMClient([
      ModelMessage(
        model: 'fake-model',
        functionCalls: [
          FunctionCall(
            id: 'delegate-1',
            name: 'delegate_task',
            arguments: jsonEncode({
              'assignee': 'clone',
              'task_description': 'Complete the delegated task.',
            }),
          ),
        ],
        stopReason: 'tool_use',
      ),
      ModelMessage(
        model: 'fake-model',
        textOutput: 'worker done',
        stopReason: 'stop',
      ),
      ModelMessage(
        model: 'fake-model',
        textOutput: 'parent done',
        stopReason: 'stop',
      ),
    ]);
    final agent = _createAgent(
      client: client,
      skillDirectoryPaths: [systemRoot.path, projectRoot.path],
      disableSubAgents: false,
    );

    await agent.run([
      UserMessage.text('Delegate this task to a clone.'),
    ], useStream: false);

    final workerMessages = client.capturedMessages.singleWhere(
      (messages) => messages.whereType<SystemMessage>().any(
        (message) => message.content.contains('WORKER AGENT PROTOCOL'),
      ),
    );
    final workerSystemPrompt = workerMessages
        .whereType<SystemMessage>()
        .single
        .content;
    expect(workerSystemPrompt, contains('Inherited system skill.'));
    expect(workerSystemPrompt, contains('Inherited project skill.'));
  });
}

File _writeSkill(Directory root, String name, String description) {
  return File('${root.path}/$name/SKILL.md')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
---
name: $name
description: $description
---

Follow the $name instructions.
''');
}

List<UserMessage> _injectedSkillMessages(AgentState state) {
  return state.history.messages
      .whereType<UserMessage>()
      .where((message) => message.metadata?['type'] == 'skill_instructions')
      .toList();
}

StatefulAgent _createAgent({
  LLMClient? client,
  AgentState? state,
  required List<String> skillDirectoryPaths,
  JavaScriptRuntime? javaScriptRuntime,
  List<Tool>? tools,
  bool disableSubAgents = true,
}) {
  return StatefulAgent(
    name: 'directory-skills-test',
    client: client ?? _CapturingLLMClient(),
    modelConfig: ModelConfig(model: 'fake-model'),
    state: state ?? AgentState.empty(),
    tools: tools,
    skillDirectoryPaths: skillDirectoryPaths,
    javaScriptRuntime: javaScriptRuntime,
    withGeneralPrinciples: false,
    disableSubAgents: disableSubAgents,
  );
}

class _CapturingLLMClient extends LLMClient {
  final capturedMessages = <List<LLMMessage>>[];
  final List<ModelMessage> replies;
  int _replyIndex = 0;

  _CapturingLLMClient([this.replies = const []]);

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
    if (replies.isNotEmpty) {
      return replies[_replyIndex++];
    }
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
    CancelToken? cancelToken,
  }) async {
    capturedMessages.add(List<LLMMessage>.from(messages));
    final reply = replies.isEmpty
        ? ModelMessage(
            model: modelConfig.model,
            textOutput: 'done',
            stopReason: 'stop',
          )
        : replies[_replyIndex++];
    return Stream.value(StreamingMessage(modelMessage: reply));
  }
}

class _CancelAfterGenerateClient extends _CapturingLLMClient {
  final CancelToken tokenToCancel;

  _CancelAfterGenerateClient(this.tokenToCancel, [super.replies]);

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    final reply = await super.generate(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
      cancelToken: cancelToken,
    );
    tokenToCancel.cancel('stop');
    return reply;
  }
}

class _RecordingJavaScriptRuntime implements JavaScriptRuntime {
  final executedPaths = <String>[];
  final executedArgs = <Map<String, dynamic>?>[];
  final executionContexts = <AgentCallToolContext?>[];

  @override
  Future<JavaScriptExecutionResult> executeFile({
    required String scriptPath,
    Map<String, dynamic>? args,
    Duration? timeout,
    required JavaScriptBridgeRegistry bridgeRegistry,
    required JavaScriptBridgeContext bridgeContext,
  }) async {
    executedPaths.add(scriptPath);
    executedArgs.add(args);
    executionContexts.add(AgentCallToolContext.current);
    return JavaScriptExecutionResult(success: true);
  }
}

ModelMessage _runJavaScriptCall({
  required String id,
  required String scriptPath,
  String? args,
}) {
  return ModelMessage(
    model: 'fake-model',
    functionCalls: [
      FunctionCall(
        id: id,
        name: 'RunJavaScript',
        arguments: jsonEncode({'script_path': scriptPath, 'args': ?args}),
      ),
    ],
    stopReason: 'tool_use',
  );
}

class _TestSkill extends Skill {
  _TestSkill()
    : super(
        name: 'in-memory',
        description: 'In-memory regression skill.',
        systemPrompt: 'Use the in-memory skill.',
      );
}
