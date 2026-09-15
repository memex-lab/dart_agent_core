import 'package:mcp_dart/mcp_dart.dart';

Future<void> main() async {
  final server = McpServer(
    const Implementation(name: 'echo-test-server', version: '1.0.0'),
    options: const McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
        resources: ServerCapabilitiesResources(),
        prompts: ServerCapabilitiesPrompts(),
      ),
    ),
  );

  server.registerTool(
    'echo',
    description: 'Echo a message back.',
    inputSchema: JsonSchema.object(
      properties: {'message': JsonSchema.string()},
      required: ['message'],
    ),
    callback: (args, extra) async {
      return CallToolResult.fromContent([
        TextContent(text: 'echo:${args['message']}'),
      ]);
    },
  );

  server.registerTool(
    'fail',
    description: 'Returns a protocol tool error.',
    inputSchema: JsonSchema.object(properties: {}),
    callback: (args, extra) async => const CallToolResult(
      content: [TextContent(text: 'request rejected')],
      isError: true,
    ),
  );

  server.registerTool(
    'error_text',
    description: 'Successful text containing an error prefix.',
    inputSchema: JsonSchema.object(properties: {}),
    callback: (args, extra) async => const CallToolResult(
      content: [TextContent(text: 'Error: this is ordinary document content')],
    ),
  );

  server.registerResource('notes', 'test://notes', null, (uri, extra) async {
    return ReadResourceResult(
      contents: [
        TextResourceContents(
          uri: uri.toString(),
          mimeType: 'text/plain',
          text: 'resource-body',
        ),
      ],
    );
  });

  server.registerPrompt(
    'greet',
    description: 'A greeting prompt',
    argsSchema: {
      'name': const PromptArgumentDefinition(
        type: String,
        description: 'Name to greet',
        required: true,
      ),
    },
    callback: (args, extra) async {
      return GetPromptResult(
        messages: [
          PromptMessage(
            role: PromptMessageRole.user,
            content: TextContent(text: 'Hello ${args?['name']}'),
          ),
        ],
      );
    },
  );

  await server.connect(StdioServerTransport());
}
