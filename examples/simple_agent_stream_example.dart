import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';

String getWeather(String location) {
  if (location.toLowerCase().contains('tokyo')) return 'Sunny, 25C';
  return 'Unknown';
}

void main() async {
  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? 'YOUR_API_KEY';

  final client = GeminiClient(apiKey: apiKey);
  final modelConfig = ModelConfig(model: 'gemini-2.5-flash');

  final weatherTool = Tool(
    name: 'get_weather',
    description: 'Get the current weather for a location.',
    executable: getWeather,
    parameters: {
      'type': 'object',
      'properties': {
        'location': {
          'type': 'string',
          'description': 'The city and state, e.g. Tokyo',
        },
      },
      'required': ['location'],
    },
  );

  final agent = StatefulAgent(
    name: 'streaming_agent',
    client: client,
    tools: [weatherTool],
    modelConfig: modelConfig,
    state: AgentState.empty(),
    systemPrompts: ['You are a helpful assistant.'],
  );

  print('Sending message to agent and streaming response...');
  final stream = agent.runStream([
    UserMessage.text(
      'Tell me a short story about a robot traveling to Tokyo, and mention the weather there.',
    ),
  ]);

  await for (final event in stream) {
    if (event.eventType == StreamingEventType.modelChunkMessage) {
      final chunk = event.data as ModelMessage;
      if (chunk.textOutput != null) {
        stdout.write(chunk.textOutput);
      }
    } else if (event.eventType == StreamingEventType.functionCallRequest) {
      print('\n[Agent is calling a tool...]');
    }
  }
  print('\nDone streaming.');
}
