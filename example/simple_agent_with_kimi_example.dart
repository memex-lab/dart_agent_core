import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';

String getWeather(String location) {
  if (location.toLowerCase().contains('tokyo')) return 'Sunny, 25°C';
  if (location.toLowerCase().contains('london')) return 'Cloudy, 15°C';
  return 'Weather data not available for this location';
}

void main() async {
  final apiKey = Platform.environment['MOONSHOT_API_KEY'] ?? 'YOUR_API_KEY';

  // Kimi (Moonshot AI) is compatible with the OpenAI Chat Completions API.
  // Just point OpenAIClient to the Kimi base URL.
  final client = OpenAIClient(
    apiKey: apiKey,
    baseUrl: 'https://api.moonshot.cn/v1',
  );

  final modelConfig = ModelConfig(model: 'kimi-k2.5');

  final weatherTool = Tool(
    name: 'get_weather',
    description: 'Get the current weather for a city.',
    executable: getWeather,
    parameters: {
      'type': 'object',
      'properties': {
        'location': {'type': 'string', 'description': 'City name, e.g. Tokyo'},
      },
      'required': ['location'],
    },
  );

  final agent = StatefulAgent(
    name: 'kimi_weather_agent',
    client: client,
    tools: [weatherTool],
    modelConfig: modelConfig,
    state: AgentState.empty(),
    systemPrompts: ['You are a helpful assistant.'],
  );

  final responses = await agent.run([
    UserMessage.text('What is the weather like in Tokyo and London?'),
  ]);

  print((responses.last as ModelMessage).textOutput);
}
