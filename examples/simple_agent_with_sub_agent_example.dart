import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';

// 1. Define tools that sub-agents will use

String searchWeb(String query) {
  final database = {
    'dart language creator': 'Dart was created by Lars Bak and Kasper Lund at Google.',
    'dart first release': 'Dart 1.0 was released on November 14, 2013.',
    'flutter first release': 'Flutter 1.0 was released on December 4, 2018.',
  };
  for (final entry in database.entries) {
    if (query.toLowerCase().contains(entry.key)) {
      return entry.value;
    }
  }
  return 'No results found for "$query"';
}

String summarizeText(String text) {
  // Simulated summarizer — just truncates for demo
  if (text.length > 100) {
    return '${text.substring(0, 100)}... [summarized]';
  }
  return text;
}

void main() async {
  final apiKey = Platform.environment['OPENAI_API_KEY'] ?? 'YOUR_API_KEY';
  final client = OpenAIClient(apiKey: apiKey);
  final modelConfig = ModelConfig(model: 'gpt-4o-mini');

  final searchTool = Tool(
    name: 'search_web',
    description: 'Search the web for information.',
    executable: searchWeb,
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'The search query'},
      },
      'required': ['query'],
    },
  );

  final summarizeTool = Tool(
    name: 'summarize_text',
    description: 'Summarize a piece of text.',
    executable: summarizeText,
    parameters: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'description': 'The text to summarize'},
      },
      'required': ['text'],
    },
  );

  // 2. Define a named sub-agent specialized for research
  final researchSubAgent = SubAgent(
    name: 'researcher',
    description:
        'A research specialist that searches the web and summarizes findings.',
    agentFactory: (parent) => StatefulAgent(
      name: 'researcher',
      client: parent.client,
      modelConfig: parent.modelConfig,
      state: AgentState.empty(),
      tools: [searchTool, summarizeTool],
      systemPrompts: [
        'You are a research specialist. Search for information and provide concise summaries.',
      ],
      isSubAgent: true, // Required for sub-agents
    ),
  );

  // 3. Create the manager agent with the sub-agent registered
  final agent = StatefulAgent(
    name: 'manager_agent',
    client: client,
    modelConfig: modelConfig,
    state: AgentState.empty(),
    systemPrompts: [
      'You are a manager agent. Delegate research tasks to your researcher sub-agent.',
    ],
    subAgents: [researchSubAgent],
  );

  print('Asking manager agent to research Dart language history...\n');
  final responses = await agent.run([
    UserMessage.text(
      'Find out who created the Dart programming language and when Flutter was first released.',
    ),
  ]);

  print('Manager response: ${(responses.last as ModelMessage).textOutput}');
}
