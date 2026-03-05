import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:logging/logging.dart';

// 1. Defining a tool that reads state metadata from context
String greetUser(String providedName) {
  // Fetch the current execution context within the tool
  final context = AgentCallToolContext.current;

  // Read metadata that was injected into the state beforehand
  final String? premiumLevel =
      context?.state.metadata['premium_status'] as String?;
  final String? accountId = context?.state.metadata['account_id'] as String?;

  if (premiumLevel == 'gold') {
    return 'Hello $providedName! Welcome back, valued Gold member ($accountId).';
  } else {
    return 'Hello $providedName. Upgrading to Gold gives you more features!';
  }
}

void main() async {
  // Optional: Set up logging to watch state saves
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    if (record.message.contains('state saved')) {
      print('[STORAGE]: ${record.message}');
    }
  });

  final apiKey = Platform.environment['OPENAI_API_KEY'] ?? 'YOUR_API_KEY';
  final client = OpenAIClient(apiKey: apiKey);
  final modelConfig = ModelConfig(model: 'gpt-4o-mini');

  // 2. Set up FileStateStorage to persist to a local directory
  final stateDir = Directory('${Directory.current.path}/.state_dir');
  final storage = FileStateStorage(stateDir);

  // 3. Load an existing state (by session/user ID) or create a new one
  final state = await storage.loadOrCreate("session_123", {
    "account_id": "acc_x789",
    "premium_status": "gold",
    "last_login": DateTime.now().toIso8601String(),
  });

  final greetingTool = Tool(
    name: 'greet_user',
    description: 'Greets the user correctly based on their membership level.',
    executable: greetUser,
    parameters: {
      'type': 'object',
      'properties': {
        'providedName': {
          'type': 'string',
          'description': 'The name the user provided',
        },
      },
      'required': ['providedName'],
    },
  );

  final agent = StatefulAgent(
    name: 'stateful_greeter',
    client: client,
    tools: [greetingTool],
    modelConfig: modelConfig,
    state: state,
    systemPrompts: ['You are a helpful customer service assistant.'],
    // 4. Automatically save state after every agent run completes
    autoSaveStateFunc: (s) async {
      await storage.save(s);
      print("state saved automatically.");
    },
  );

  print('Sending message to agent to invoke the context-aware tool...');
  final responses = await agent.run([
    UserMessage.text('Hi there, my name is Alex. Can you say hello to me?'),
  ]);

  print('Agent response:\n${(responses.last as ModelMessage).textOutput}');

  // Clean up directory for the example (optional)
  // if (stateDir.existsSync()) stateDir.deleteSync(recursive: true);
}
