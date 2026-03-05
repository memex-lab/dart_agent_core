import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/src/agent/util.dart';
import 'package:logging/logging.dart';

final _subAgentLogger = Logger('SubAgent');

class SubAgent {
  final String name;
  final String description;
  final StatefulAgent Function(StatefulAgent parent) agentFactory;

  SubAgent({
    required this.name,
    required this.description,
    required this.agentFactory,
  });
}

final subAgentTools = [_delegateTaskTool];

final _delegateTaskTool = Tool(
  name: 'delegate_task',
  description:
      'Delegate a complex or specialized task to a worker agent. '
      'This tool runs a separate agent loop and returns the final result. '
      'Use this to isolate context or utilize specific expertise.',
  executable: _delegateTask,
  parameters: {
    'type': 'object',
    'properties': {
      'assignee': {
        'type': 'string',
        'description':
            'The target worker. '
            'Use "clone" for a standard copy of yourself (clean context). '
            'Use a specific name (e.g., "QA_Expert") if listed in your available sub-agents.',
      },
      'task_description': {
        'type': 'string',
        'description':
            'Detailed instructions for the worker. Include all necessary context.',
      },
    },
    'required': ['assignee', 'task_description'],
  },
);

Future<AgentToolResult> _delegateTask(
  String assignee,
  String task_description,
) async {
  final context = AgentCallToolContext.current!;
  final parentState = context.state;
  final parentAgent = context.agent;
  final availableSubAgents = parentAgent.subAgents ?? [];
  final cancelToken = context.cancelToken;

  StatefulAgent workerAgent;
  if (assignee.toLowerCase() == 'clone') {
    String workerSessionId =
        "${parentState.sessionId}_${assignee}_${uuid.v4()}";
    final history = _copyParentHistory(parentState.history);
    AgentState workerState = AgentState(
      sessionId: workerSessionId,
      metadata: Map.from(parentState.metadata)
        ..addAll({
          'parent_session_id': parentState.sessionId,
          'sub_agent_mode': true,
        }),
      history: history,
    );
    workerAgent = StatefulAgent(
      name: '${parentAgent.name}_cloned_worker',
      client: parentAgent.client,
      modelConfig: parentAgent.modelConfig,
      state: workerState,
      tools: parentAgent.tools,
      systemPrompts: List.from(parentAgent.systemPrompts),
      compressor: parentAgent.compressor,
      planMode: PlanMode.auto,
      skills: parentAgent.skills,
      withGeneralPrinciples: parentAgent.withGeneralPrinciples,
      loopDetector: parentAgent.loopDetector,
      autoSaveStateFunc: parentAgent.autoSaveStateFunc,
      controller: parentAgent.controller,
      isSubAgent: true,
    );
  } else {
    try {
      final subAgent = availableSubAgents.firstWhere((s) => s.name == assignee);
      workerAgent = subAgent.agentFactory(parentAgent);
      if (!workerAgent.isSubAgent) {
        _subAgentLogger.severe(
          "[${parentAgent.name}] Agent ($assignee) is not a sub-agent, please set isSubAgent to true",
        );
        return AgentToolResult(
          content: TextPart(
            "Error: Sub-agent '$assignee' is not available. please don't delegate task to it.",
          ),
        );
      }
    } catch (e) {
      _subAgentLogger.warning(
        "[${parentAgent.name}] Sub-agent ($assignee) not found in registry",
      );
      return AgentToolResult(
        content: TextPart(
          "Error: Sub-agent '$assignee' not found in registry.",
        ),
      );
    }
  }

  workerAgent.systemPrompts.add("""
## WORKER AGENT PROTOCOL
You are currently running as a delegated **Sub-Agent** (Worker).
- **Manager Context**: A snapshot of the manager's recent conversation has been injected into your **Episodic Memory**. If the task references "context", "history", or "above", query your memory to find it.

## OUTPUT CONSTRAINTS
1. **Direct Execution**: Do not engage in small talk (e.g., "Sure, I can help"). Start directly with the solution or answer.
2. **Self-Contained**: Your response will be parsed programmatically by the Manager Agent. Ensure it is complete and well-formatted (use Markdown).
3. **No Handoffs**: Do not ask the user for more info; use your best judgment based on the provided context.
""");

  final taskInput = [
    UserMessage.text(
      "YOUR TASK DESCRIPTION:\n\"\"\"\n$task_description\n\"\"\"",
    ),
  ];

  try {
    final result = await workerAgent.run(taskInput, cancelToken: cancelToken);
    final lastMessage = result.last;
    if (lastMessage is! ModelMessage) {
      _subAgentLogger.warning(
        "[${workerAgent.name}] Sub-agent ($assignee) execution failed",
      );
      return AgentToolResult(
        content: TextPart("Sub-agent ($assignee) execution failed"),
        metadata: {
          "sub_agent_session_id": workerAgent.state.sessionId,
          "task_description": task_description,
          "assignee": assignee,
          "status": "error",
        },
      );
    }
    return AgentToolResult(
      content: TextPart(
        "Sub-agent ($assignee) execution result:\n\n${lastMessage.textOutput}",
      ),
      metadata: {
        "sub_agent_session_id": workerAgent.state.sessionId,
        "task_description": task_description,
        "assignee": assignee,
        "status": "success",
      },
    );
  } catch (e) {
    _subAgentLogger.warning(
      "[${workerAgent.name}] Sub-agent ($assignee) execution failed: $e",
    );
    return AgentToolResult(
      content: TextPart("Sub-agent $assignee execution failed: $e"),
      metadata: {
        "sub_agent_session_id": workerAgent.state.sessionId,
        "task_description": task_description,
        "assignee": assignee,
        "status": "error",
      },
    );
  }
}

AgentMessageHistory _copyParentHistory(AgentMessageHistory parentHistory) {
  final parentHistoryJson = parentHistory.toJson();
  final history = AgentMessageHistory.fromJson(parentHistoryJson);
  if (history.messages.isNotEmpty) {
    final recentHistory = history.messages.length > 10
        ? history.messages.sublist(history.messages.length - 10)
        : history.messages;
    final recentHistoryString = buildConversationHistory(recentHistory);
    final recentHistorySnapshot =
        'Here is the recent conversation history of the parent agent:\n\n<parent_agent_state_snapshot>\n$recentHistoryString\n</parent_agent_state_snapshot>';
    history.messages.clear();
    history.messages.addAll([
      UserMessage.text(recentHistorySnapshot),
      UserMessage.text(
        "Got it. Thanks for the additional context! I already know the parent agent's context, I will focus on completing my task",
      ),
    ]);
  }
  return history;
}

SystemPromptPart? buildSubAgentSystemPrompt(
  AgentState state,
  List<SubAgent>? subAgents,
) {
  final buffer = StringBuffer();

  buffer.writeln("# Worker Agents & Delegation Strategy");
  buffer.writeln(
    "You are a Manager Agent. You have access to a team of specialized worker agents and a generic 'clone' capability.",
  );
  buffer.writeln(
    "Use the `delegate_task` tool to offload complex, isolated, or specialized work.",
  );

  buffer.writeln("\n## Available Sub-Agents:");

  buffer.writeln(
    "- **clone**: A standard copy of yourself. Use this for general-purpose parallel tasks, reducing your context window usage, or when you need a fresh perspective on a specific sub-problem without the clutter of the current conversation history.",
  );

  if (subAgents != null && subAgents.isNotEmpty) {
    for (final subAgent in subAgents) {
      buffer.writeln("- **${subAgent.name}**: ${subAgent.description}");
    }
  }

  buffer.writeln("\n## Best Practices for Delegation:");
  buffer.writeln(
    "1. **Isolate Context**: Worker agents start with a clean conversation history (but share your long-term memories).",
  );
  buffer.writeln(
    "2. **Be Explicit**: Your `task_description` must be self-contained. Do not say 'check the file mentioned above'. Instead, copy the file path or content or summary into the `task_description`.",
  );

  return SystemPromptPart(name: "sub_agents", content: buffer.toString());
}
