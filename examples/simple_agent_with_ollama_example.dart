import 'package:dart_agent_core/dart_agent_core.dart';

String getWeather(String location) {
  if (location.toLowerCase().contains('tokyo')) return 'Sunny, 25°C';
  if (location.toLowerCase().contains('london')) return 'Cloudy, 15°C';
  return 'Weather data not available for this location';
}

void main() async {
  // Ollama exposes an OpenAI-compatible API at http://localhost:11434/v1
  final client = OpenAIClient(
    apiKey: '', // Ollama does not require an API key
    baseUrl: 'http://localhost:11434/v1',
  );

  // Use any model you have pulled locally, e.g. `ollama pull qwen2.5:7b`
  final modelConfig = ModelConfig(model: 'qwen2.5:7b');

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
    name: 'ollama_agent',
    client: client,
    tools: [weatherTool],
    modelConfig: modelConfig,
    state: AgentState.empty(),
    systemPrompts: ['You are a helpful assistant.'],
  );

  final responses = await agent.run([
    UserMessage.text('What is the weather like in Tokyo?'),
  ]);

  print((responses.last as ModelMessage).textOutput);
}
