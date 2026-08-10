import 'dart:async';
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
    final skillFile = File('${projectRoot.path}/demo/SKILL.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
---
name: demo
description: Duplicate-root regression skill.
---

Follow the demo instructions.
''');
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
}

StatefulAgent _createAgent({
  LLMClient? client,
  AgentState? state,
  required List<String> skillDirectoryPaths,
  JavaScriptRuntime? javaScriptRuntime,
}) {
  return StatefulAgent(
    name: 'directory-skills-test',
    client: client ?? _CapturingLLMClient(),
    modelConfig: ModelConfig(model: 'fake-model'),
    state: state ?? AgentState.empty(),
    skillDirectoryPaths: skillDirectoryPaths,
    javaScriptRuntime: javaScriptRuntime,
    withGeneralPrinciples: false,
    disableSubAgents: true,
  );
}

class _CapturingLLMClient extends LLMClient {
  final capturedMessages = <List<LLMMessage>>[];

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
    throw UnimplementedError('This test client only supports generate().');
  }
}

class _RecordingJavaScriptRuntime implements JavaScriptRuntime {
  final executedPaths = <String>[];

  @override
  Future<JavaScriptExecutionResult> executeFile({
    required String scriptPath,
    Map<String, dynamic>? args,
    Duration? timeout,
    required JavaScriptBridgeRegistry bridgeRegistry,
    required JavaScriptBridgeContext bridgeContext,
  }) async {
    executedPaths.add(scriptPath);
    return JavaScriptExecutionResult(success: true);
  }
}

class _TestSkill extends Skill {
  _TestSkill()
    : super(
        name: 'in-memory',
        description: 'In-memory regression skill.',
        systemPrompt: 'Use the in-memory skill.',
      );
}
