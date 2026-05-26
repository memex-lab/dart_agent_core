import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';

/// Shared `AgentHarnessSession` implementation used by every agent demo.
///
/// Each demo provides:
///   - the system prompt
///   - the tool list (a function so the workspace can be threaded in)
///   - a `captureOutcome` callback that reads disk state at the end of
///     the run and produces the [Outcome] map.
///
/// The eval runner records the generic transcript from the shared
/// [AgentController]; this harness only runs the agent and captures the final
/// environment state.
class GenericAgentSession implements AgentHarnessSession {
  final EvalTask task;
  final Trial trial;
  final EvalContext context;
  final ModelConfig modelConfig;
  final String agentName;
  final String systemPrompt;
  final List<Tool> Function(Directory workspace) buildTools;
  final Outcome Function(Directory workspace) captureOutcome;

  GenericAgentSession({
    required this.task,
    required this.trial,
    required this.context,
    required this.modelConfig,
    required this.agentName,
    required this.systemPrompt,
    required this.buildTools,
    required this.captureOutcome,
  });

  @override
  Future<({Transcript transcript, Outcome outcome})> run() async {
    final ws = context.workspaceDir!;
    final controller = context.controller;

    final tools = buildTools(ws);

    final agentState = AgentState(
      sessionId: '${trial.taskId}_${trial.trialIndex}',
    );
    agentState.metadata['userId'] = 'eval_demo';
    agentState.metadata['scene'] = agentName;
    agentState.metadata['sceneId'] = trial.taskId;

    final agent = StatefulAgent(
      name: agentName,
      client: context.llmClient,
      modelConfig: modelConfig,
      state: agentState,
      tools: tools,
      systemPrompts: [systemPrompt],
      controller: controller,
      withGeneralPrinciples: false,
      planMode: PlanMode.none,
      disableSubAgents: true,
      autoSaveStateFunc: (_) async {},
    );

    final userMessage = UserMessage([TextPart(task.input['prompt'] as String)]);

    try {
      await agent.run([userMessage], useStream: false);
    } catch (e, st) {
      controller.publish(OnAgentErrorEvent(agent, 'agent_run_error: $e\n$st'));
    }

    final outcome = captureOutcome(ws);
    return (
      transcript: Transcript(
        messages: const [],
        toolCalls: const [],
        metrics: const TranscriptMetrics(
          nTurns: 0,
          nToolCalls: 0,
          nTotalTokens: 0,
        ),
      ),
      outcome: outcome,
    );
  }

  @override
  Future<void> dispose() async {
    // Controller is closed by the environment when the trial ends.
  }
}
