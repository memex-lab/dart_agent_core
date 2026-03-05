import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';

String searchInternet(String query) {
  if (query.contains('capital of France')) return 'Paris';
  if (query.contains('population of Paris')) return 'About 2.1 million';
  return 'No results found.';
}

void main() async {
  final apiKey = Platform.environment['OPENAI_API_KEY'] ?? 'YOUR_API_KEY';

  final client = OpenAIClient(apiKey: apiKey);
  final modelConfig = ModelConfig(model: 'gpt-4o');

  final searchTool = Tool(
    name: 'search_internet',
    description: 'Search the internet for factual information.',
    executable: searchInternet,
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'The search query'},
      },
      'required': ['query'],
    },
  );

  final agent = StatefulAgent(
    name: 'planning_agent',
    client: client,
    tools: [searchTool],
    modelConfig: modelConfig,
    state: AgentState.empty(),
    // Enforce PlanMode to create a plan before executing
    planMode: PlanMode.must,
    controller: AgentController(),
  );

  print('Sending a multi-step task to planning agent...');
  final responses = await agent.run([
    UserMessage.text(
      'Find the capital of France and then tell me its population.',
    ),
  ]);

  print('Final Agent response: ${(responses.last as ModelMessage).textOutput}');
}
