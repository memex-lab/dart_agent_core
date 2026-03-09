import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';

// 1. Define a standard Dart function
String getWeather(String location) {
  if (location.toLowerCase().contains('tokyo')) {
    return 'The weather in Tokyo is sunny and 25 degrees Celsius.';
  } else if (location.toLowerCase().contains('seattle')) {
    return 'The weather in Seattle is rainy and 12 degrees Celsius.';
  }
  return 'Weather data not available for $location';
}

void main() async {
  final apiKey = Platform.environment['OPENAI_API_KEY'] ?? 'YOUR_API_KEY';

  final client = OpenAIClient(apiKey: apiKey);
  final modelConfig = ModelConfig(model: 'gpt-4o-mini');

  // 2. Wrap the function into a Tool object with a JSON schema description
  final weatherTool = Tool(
    name: 'get_weather',
    description: 'Get the current weather for a location.',
    executable: getWeather,
    parameters: {
      'type': 'object',
      'properties': {
        'location': {
          'type': 'string',
          'description': 'The city and state, e.g. Seattle, WA',
        },
      },
      'required': ['location'],
    },
  );

  // 3. Pass the tool to the agent
  final agent = StatefulAgent(
    name: 'simple_agent',
    client: client,
    modelConfig: modelConfig,
    tools: [weatherTool],
    state: AgentState.empty(),
    systemPrompts: ['You are a helpful assistant that can check the weather.'],
  );

  print('Sending message to agent to invoke a tool...');
  final responses = await agent.run([
    UserMessage.text(
      'What is the weather like in Seattle and Tokyo right now?',
    ),
  ]);

  print('Agent response: ${(responses.last as ModelMessage).textOutput}');
}
