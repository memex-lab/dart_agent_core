import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';

String generateHaikuTopic(String input) {
  if (input.toLowerCase().contains('tech')) return 'Servers hum softly';
  return 'Nature is quiet';
}

void main() async {
  final apiKey = Platform.environment['OPENAI_API_KEY'] ?? 'YOUR_API_KEY';

  final client = OpenAIClient(apiKey: apiKey);
  final modelConfig = ModelConfig(model: 'gpt-4o', temperature: 0.7);

  final topicTool = Tool(
    name: 'generate_topic',
    description: 'Generates a starting line for a haiku based on a category.',
    executable: generateHaikuTopic,
    parameters: {
      'type': 'object',
      'properties': {
        'input': {
          'type': 'string',
          'description': 'The category, e.g. tech or nature',
        },
      },
      'required': ['input'],
    },
  );

  final agent = StatefulAgent(
    name: 'openai_agent',
    client: client,
    tools: [topicTool],
    modelConfig: modelConfig,
    state: AgentState.empty(),
  );

  print('Sending message to OpenAI agent to use a tool...');
  final responses = await agent.run([
    UserMessage.text(
      'Generate a starting line for a tech haiku using the tool, and then finish the poem.',
    ),
  ]);

  print('Agent response:\n${(responses.last as ModelMessage).textOutput}');
}
