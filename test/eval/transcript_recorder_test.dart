import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';
import 'package:test/test.dart';

import '_helpers.dart';

void main() {
  test(
    'EvalTranscriptRecorder captures messages, tool calls, and metrics',
    () async {
      final controller = AgentController();
      final startedAt = DateTime(2026, 1, 1, 12);
      var tick = 0;
      final recorder = EvalTranscriptRecorder(
        controller: controller,
        startedAt: startedAt,
        now: () => startedAt.add(Duration(milliseconds: ++tick * 10)),
      );

      final agent = _agentWithTool(controller);
      await agent.run([UserMessage.text('echo hi')], useStream: false);
      await Future<void>.delayed(Duration.zero);

      final transcript = recorder.snapshot();
      await recorder.dispose();
      controller.close();

      expect(transcript.messages, hasLength(5));
      expect(transcript.messages.first, isA<SystemMessage>());
      expect(transcript.messages[1], isA<UserMessage>());
      expect(transcript.messages[2], isA<ModelMessage>());
      expect(transcript.messages[3], isA<FunctionExecutionResultMessage>());
      expect(transcript.messages.last, isA<ModelMessage>());
      expect(transcript.toolCalls, hasLength(1));
      expect(transcript.toolCalls.single.toolName, 'echo_tool');
      expect(transcript.toolCalls.single.arguments, {'value': 'hi'});
      expect(transcript.toolCalls.single.isError, isFalse);
      expect(transcript.reasoningSteps, ['need echo']);
      expect(transcript.metrics.nTurns, 2);
      expect(transcript.metrics.nToolCalls, 1);
      expect(transcript.metrics.nTotalTokens, 18);
      expect(
        transcript.metrics.timeToFirstToken,
        const Duration(milliseconds: 10),
      );
    },
  );

  test(
    'EvalRunner replaces an empty harness transcript with recorder output',
    () async {
      final environment = _RecorderEnvironment();
      final runner = EvalRunner(
        environment: environment,
        harnessFactory: _RecorderHarnessFactory(),
      );

      final report = await runner.runSuite(
        runName: 'recorder_run',
        suite: EvalSuite(
          name: 'recorder_suite',
          agentName: 'agent',
          kind: SuiteKind.capability,
          tasks: [_RecorderTask()],
        ),
        concurrency: 1,
      );

      final transcript = report.trials.single.transcript;
      expect(transcript.messages, isNotEmpty);
      expect(transcript.toolCalls.single.toolName, 'echo_tool');
      expect(transcript.metrics.nTurns, 2);
    },
  );
}

StatefulAgent _agentWithTool(AgentController controller) {
  return StatefulAgent(
    name: 'recorder_test_agent',
    client: FakeLLMClient([
      ModelMessage(
        model: 'fake-model',
        stopReason: 'tool_use',
        thought: 'need echo',
        usage: ModelUsage(
          promptTokens: 3,
          completionTokens: 4,
          totalTokens: 7,
          model: 'fake-model',
        ),
        functionCalls: [
          FunctionCall(
            id: 'call_1',
            name: 'echo_tool',
            arguments: '{"value":"hi"}',
          ),
        ],
      ),
      ModelMessage(
        model: 'fake-model',
        stopReason: 'stop',
        textOutput: 'done',
        usage: ModelUsage(
          promptTokens: 5,
          completionTokens: 6,
          totalTokens: 11,
          model: 'fake-model',
        ),
      ),
    ]),
    modelConfig: ModelConfig(model: 'fake-model'),
    state: AgentState(sessionId: 'recorder_test'),
    tools: [
      Tool(
        name: 'echo_tool',
        description: 'Echoes a value.',
        parameterMode: ToolParameterMode.object,
        parameters: {
          'type': 'object',
          'properties': {
            'value': {'type': 'string'},
          },
          'required': ['value'],
        },
        executable: (Map<String, dynamic> args) => 'echo ${args['value']}',
      ),
    ],
    systemPrompts: const ['You are a test agent.'],
    controller: controller,
    withGeneralPrinciples: false,
    planMode: PlanMode.none,
    disableSubAgents: true,
    autoSaveStateFunc: (_) async {},
  );
}

class _RecorderEnvironment implements EvalEnvironment {
  @override
  Future<EvalContext> prepare({
    required Trial trial,
    required EvalTask task,
  }) async {
    return EvalContext(
      workspaceDir: await Directory.systemTemp.createTemp('recorder_eval_'),
      clock: const SystemEvalClock(),
      llmClient: FakeLLMClient([textReply('unused')]),
      controller: AgentController(),
    );
  }

  @override
  Future<void> dispose(EvalContext context) async {
    final ws = context.workspaceDir;
    if (ws != null && await ws.exists()) {
      await ws.delete(recursive: true);
    }
    context.controller.close();
  }
}

class _RecorderHarnessFactory implements AgentHarnessFactory {
  @override
  Future<AgentHarnessSession> create({
    required EvalTask task,
    required Trial trial,
    required EvalContext context,
  }) async {
    return _RecorderSession(context.controller);
  }
}

class _RecorderSession implements AgentHarnessSession {
  final AgentController controller;

  _RecorderSession(this.controller);

  @override
  Future<({Transcript transcript, Outcome outcome})> run() async {
    await _agentWithTool(
      controller,
    ).run([UserMessage.text('echo hi')], useStream: false);
    return (
      transcript: emptyTranscript(),
      outcome: const Outcome(environmentState: {'ok': true}),
    );
  }

  @override
  Future<void> dispose() async {}
}

class _RecorderTask implements EvalTask {
  @override
  String get id => 'recorder_task';

  @override
  String get description => 'recorder task';

  @override
  Map<String, dynamic> get input => const {};

  @override
  Map<String, String> get metadata => const {};

  @override
  ReferenceSolution? get referenceSolution => null;

  @override
  List<Grader> get graders => [_PassGrader()];

  @override
  int get trialsPerRun => 1;

  @override
  Duration? get timeout => const Duration(seconds: 5);
}

class _PassGrader extends CodeGrader {
  @override
  String get name => 'pass';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    return [Assertion(description: 'always passes', passed: true)];
  }
}
