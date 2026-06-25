import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';

// Tools for the agent

String readFile(String path) {
  return 'Contents of $path: [simulated file data]';
}

String deleteFile(String path) {
  return 'Deleted $path';
}

void main() async {
  final apiKey = Platform.environment['OPENAI_API_KEY'] ?? 'YOUR_API_KEY';
  final client = OpenAIClient(apiKey: apiKey);
  final modelConfig = ModelConfig(model: 'gpt-4o-mini');

  final readTool = Tool(
    name: 'read_file',
    description: 'Read the contents of a file.',
    executable: readFile,
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'File path to read'},
      },
      'required': ['path'],
    },
  );

  final deleteTool = Tool(
    name: 'delete_file',
    description: 'Delete a file at the given path.',
    executable: deleteFile,
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'File path to delete'},
      },
      'required': ['path'],
    },
  );

  // 1. Create an AgentController to observe agent behavior
  final controller = AgentController();

  // 2. Observe events (Pub/Sub pattern)
  controller.on<AgentStartedEvent>((event) {
    print('[Controller] Agent "${event.agent.name}" started');
  });

  controller.on<BeforeToolCallEvent>((event) {
    print(
      '[Controller] Tool call: ${event.functionCall.name}(${event.functionCall.arguments})',
    );
  });

  controller.on<AfterToolCallEvent>((event) {
    final status = event.result.isError ? 'FAILED' : 'OK';
    print('[Controller] Tool result: ${event.result.name} -> $status');
  });

  controller.on<PlanChangedEvent>((event) {
    print('[Controller] Plan updated:');
    for (final step in event.plan.steps) {
      print('  [${step.status.name}] ${step.description}');
    }
  });

  controller.on<AgentRunSuccessedEvent>((event) {
    print('[Controller] Agent completed. Stop reason: ${event.stopReason}');
  });

  // 3. Create the agent with controller observation and hook control
  final agent = StatefulAgent(
    name: 'controlled_agent',
    client: client,
    modelConfig: modelConfig,
    state: AgentState.empty(),
    tools: [readTool, deleteTool],
    systemPrompts: ['You are a file management assistant.'],
    controller: controller,
    hooks: [DeleteFilePolicyHook()],
  );

  print('Asking agent to read and then delete a file...\n');
  final responses = await agent.run([
    UserMessage.text('First read the file at /tmp/data.txt, then delete it.'),
  ]);
  print('\nAgent response: ${(responses.last as ModelMessage).textOutput}');
}

class DeleteFilePolicyHook extends AgentHook {
  @override
  ToolCallHookResult beforeToolCall(ToolCallHookContext context) {
    if (context.call.name != 'delete_file') {
      return ToolCallHookResult.proceed(context.call);
    }
    print('[Hook] BLOCKED: delete_file is not allowed!');
    return ToolCallHookResult.deny(
      content: [TextPart('delete_file is blocked by local policy.')],
    );
  }
}
