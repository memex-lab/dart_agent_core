import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';

Future<void> main() async {
  final openAiApiKey = Platform.environment['OPENAI_API_KEY'] ?? '';
  final mcpServerUrl = Platform.environment['MCP_SERVER_URL'] ?? '';
  final mcpServerToken = Platform.environment['MCP_SERVER_TOKEN'];

  if (openAiApiKey.isEmpty || mcpServerUrl.isEmpty) {
    throw StateError(
      'Set OPENAI_API_KEY and MCP_SERVER_URL before running this example.',
    );
  }

  final headers = <String, String>{
    if (mcpServerToken != null && mcpServerToken.isNotEmpty)
      'Authorization': 'Bearer $mcpServerToken',
  };
  final mcpManager = McpManager();
  await mcpManager.connectAll([
    McpConnectionConfig(
      serverName: 'remote',
      type: McpTransportType.http,
      url: mcpServerUrl,
      headers: headers,
    ),
  ]);

  if (!mcpManager.hasServers) {
    throw StateError('Could not connect to the configured MCP server.');
  }

  try {
    final agent = StatefulAgent(
      name: 'mcp_agent',
      client: OpenAIClient(apiKey: openAiApiKey),
      modelConfig: ModelConfig(model: 'gpt-4o-mini'),
      state: AgentState.empty(),
      systemPrompts: ['Use the MCP server when it can help answer the user.'],
      mcpManager: mcpManager,
    );

    final responses = await agent.run([
      UserMessage.text(
        'List the capabilities of the connected MCP server and summarize what it can do.',
      ),
    ]);
    print((responses.last as ModelMessage).textOutput);
  } finally {
    // StatefulAgent already disconnects MCP sessions after each run. dispose()
    // is idempotent and also covers failures before the run starts.
    await mcpManager.dispose();
  }
}
