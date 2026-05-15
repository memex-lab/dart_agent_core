import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:http/http.dart' as http;

Future<String> youSearch(Map<String, dynamic> args) async {
  final query = (args['query'] as String?)?.trim();
  if (query == null || query.isEmpty) {
    return 'Error: query is required.';
  }

  final count = (args['count'] as int?) ?? 5;
  final uri = Uri.https('api.you.com', '/v1/agents/search', {
    'query': query,
    'count': '$count',
  });

  final key = Platform.environment['YDC_API_KEY'];
  final headers = <String, String>{
    if (key != null && key.isNotEmpty) 'X-API-Key': key,
  };

  final resp = await http.get(uri, headers: headers);
  if (resp.statusCode != 200) {
    return 'You.com search failed (${resp.statusCode}): ${resp.body}';
  }

  final data = jsonDecode(resp.body) as Map<String, dynamic>;
  final results = (data['results'] as Map<String, dynamic>?) ?? const {};
  final web = (results['web'] as List?) ?? const [];
  if (web.isEmpty) return 'No web results found.';

  final lines = <String>[];
  for (final item in web.take(count)) {
    final m = item as Map<String, dynamic>;
    lines.add('- ${m['title'] ?? '(untitled)'}\n  ${m['url'] ?? ''}\n  ${m['description'] ?? ''}');
  }
  return lines.join('\n');
}

void main() async {
  final openAiKey = Platform.environment['OPENAI_API_KEY'] ?? '';
  final client = OpenAIClient(apiKey: openAiKey);

  final searchTool = Tool(
    name: 'you_search',
    description: 'Search the web with You.com Search API.',
    parameterMode: ToolParameterMode.object,
    executable: youSearch,
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'Search query'},
        'count': {'type': 'integer', 'minimum': 1, 'maximum': 10},
      },
      'required': ['query'],
    },
  );

  final agent = StatefulAgent(
    name: 'you_search_agent',
    client: client,
    modelConfig: ModelConfig(model: 'gpt-4o-mini'),
    tools: [searchTool],
    state: AgentState.empty(),
    systemPrompts: [
      'You are a web research assistant. Use you_search for factual web lookup before answering.'
    ],
  );

  final out = await agent.run([
    UserMessage.text('Find two recent updates about Dart 3 adoption.'),
  ]);

  print((out.last as ModelMessage).textOutput);
}
