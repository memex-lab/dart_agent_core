import 'dart:convert';
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
/// Everything else (event-bus wiring, transcript assembly, message
/// snapshot) is identical across demos.
class GenericAgentSession implements AgentHarnessSession {
  final EvalTask task;
  final Trial trial;
  final EvalContext context;
  final ModelConfig modelConfig;
  final String agentName;
  final String systemPrompt;
  final List<Tool> Function(Directory workspace) buildTools;
  final Outcome Function(Directory workspace, SessionState state)
  captureOutcome;

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

  final SessionState _state = SessionState();

  @override
  Future<({Transcript transcript, Outcome outcome})> run() async {
    final ws = context.workspaceDir!;
    final controller = context.controller;
    _wireListeners(controller);

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
      _state.events.add(
        TranscriptEvent(
          at: DateTime.now(),
          kind: 'agent_run_error',
          message: e.toString(),
          details: {'stackTrace': st.toString()},
        ),
      );
    }

    _state.messages
      ..clear()
      ..addAll(agentState.history.messages);

    final outcome = captureOutcome(ws, _state);
    final transcript = _buildTranscript();
    return (transcript: transcript, outcome: outcome);
  }

  @override
  Future<void> dispose() async {
    // Controller is closed by the environment when the trial ends.
  }

  void _wireListeners(AgentController controller) {
    controller.on<BeforeToolCallEvent>((e) {
      _state.pendingToolCalls[e.functionCall.id] = ToolCallStart(
        startedAt: DateTime.now(),
        toolName: e.functionCall.name,
        arguments: _decodeArgs(e.functionCall.arguments),
      );
    });

    controller.on<AfterToolCallEvent>((e) {
      final start = _state.pendingToolCalls.remove(e.result.id);
      final endedAt = DateTime.now();
      _state.toolCalls.add(
        ToolCallRecord(
          callId: e.result.id,
          toolName: e.result.name,
          arguments: start?.arguments ?? const {},
          result: e.result,
          startedAt: start?.startedAt ?? endedAt,
          endedAt: endedAt,
          isError: e.result.isError,
        ),
      );
    });

    controller.on<AfterCallLLMEvent>((e) {
      _state.nTurns += 1;
      _state.firstLLMReplyAt ??= DateTime.now();
      _state.lastLLMReplyAt = DateTime.now();
      final usage = e.response.usage;
      if (usage != null) {
        _state.totalTokens += usage.totalTokens;
      }
    });

    controller.on<LLMRetryingEvent>((e) {
      _state.events.add(
        TranscriptEvent(
          at: DateTime.now(),
          kind: 'llm_retry',
          message: e.reason,
        ),
      );
    });

    controller.on<OnAgentExceptionEvent>((e) {
      _state.events.add(
        TranscriptEvent(
          at: DateTime.now(),
          kind: 'agent_exception',
          message: e.error.toString(),
        ),
      );
    });
  }

  Map<String, dynamic> _decodeArgs(String raw) {
    if (raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
      return const {};
    } catch (_) {
      return const {};
    }
  }

  Transcript _buildTranscript() {
    final ttft = _state.firstLLMReplyAt;
    final ttlt = _state.lastLLMReplyAt;
    return Transcript(
      messages: List.unmodifiable(_state.messages),
      toolCalls: List.unmodifiable(_state.toolCalls),
      reasoningSteps: const [],
      events: List.unmodifiable(_state.events),
      metrics: TranscriptMetrics(
        nTurns: _state.nTurns,
        nToolCalls: _state.toolCalls.length,
        nTotalTokens: _state.totalTokens,
        timeToFirstToken: ttft?.difference(trial.startedAt),
        timeToLastToken: ttlt?.difference(trial.startedAt),
      ),
    );
  }
}

/// Tracks progress of a single agent run. Public so demo
/// `captureOutcome` callbacks can read tool calls, messages, and timings
/// without the analyzer warning about private types in public API.
class SessionState {
  final List<LLMMessage> messages = [];
  final List<ToolCallRecord> toolCalls = [];
  final List<TranscriptEvent> events = [];
  final Map<String, ToolCallStart> pendingToolCalls = {};
  DateTime? firstLLMReplyAt;
  DateTime? lastLLMReplyAt;
  int nTurns = 0;
  int totalTokens = 0;
}

class ToolCallStart {
  final DateTime startedAt;
  final String toolName;
  final Map<String, dynamic> arguments;
  const ToolCallStart({
    required this.startedAt,
    required this.toolName,
    required this.arguments,
  });
}
