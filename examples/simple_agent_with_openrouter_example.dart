import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';

String getWeather(String location) {
  if (location.toLowerCase().contains('tokyo')) return 'Sunny, 25°C';
  if (location.toLowerCase().contains('london')) return 'Cloudy, 15°C';
  return 'Weather data not available for this location';
}

void main() async {
  // OpenRouter provides an OpenAI-compatible API
  final client = OpenAIClient(
    apiKey: Platform.environment['OPENROUTER_API_KEY'] ?? 'YOUR_API_KEY',
    baseUrl: 'https://openrouter.ai/api/v1',
  );

  // Any model available on OpenRouter
  final modelConfig = ModelConfig(
    model: 'anthropic/claude-opus-4.6',
    extra: {
      'thinking': {'type': 'enabled', 'budget_tokens': 2000},
    },
  );

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
    name: 'openrouter_agent',
    client: client,
    tools: [weatherTool],
    modelConfig: modelConfig,
    state: AgentState.empty(),
    systemPrompts: ['You are a helpful assistant.'],
  );

  await for (final event in agent.runStream([
    UserMessage.text('What is the weather like in Tokyo and London?'),
  ])) {
    switch (event.eventType) {
      case StreamingEventType.modelChunkMessage:
        final chunk = event.data as ModelMessage;
        if (chunk.thought != null && chunk.thought!.isNotEmpty) {
          stdout.write('[thinking] ${chunk.thought}');
        }
        if (chunk.textOutput != null && chunk.textOutput!.isNotEmpty) {
          stdout.write(chunk.textOutput);
        }
        break;
      case StreamingEventType.fullModelMessage:
        print('\n');
        break;
      case StreamingEventType.functionCallRequest:
        final calls = event.data as List<FunctionCall>;
        for (final call in calls) {
          print('[tool call] ${call.name}(${call.arguments})');
        }
        break;
      case StreamingEventType.functionCallResult:
        final result = event.data as FunctionExecutionResultMessage;
        for (final r in result.results) {
          print('[tool result] ${r.name}: ${r.content.map((p) => p is TextPart ? p.text : '...').join()}');
        }
        break;
      default:
        break;
    }
  }
}
