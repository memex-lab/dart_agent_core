import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

Future<void> main(List<String> args) async {
  final startupLogPath = args.single;
  File(startupLogPath).writeAsStringSync(
    '$pid|${Platform.environment['PATH']}\n',
    mode: FileMode.append,
    flush: true,
  );

  final server = McpServer(
    const Implementation(name: 'paged-test-server', version: '1.0.0'),
    options: const McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
        resources: ServerCapabilitiesResources(),
        prompts: ServerCapabilitiesPrompts(),
      ),
    ),
  );

  server.server.setRequestHandler<JsonRpcListToolsRequest>(
    Method.toolsList,
    (request, extra) async => ListToolsResult(
      tools: [
        Tool(
          name: request.listParams.cursor == null ? 'tool-one' : 'tool-two',
          inputSchema: JsonSchema.object(),
        ),
      ],
      nextCursor: request.listParams.cursor == null ? 'tools-page-2' : null,
    ),
    (id, params, meta) => JsonRpcListToolsRequest.fromJson({
      'jsonrpc': jsonRpcVersion,
      'id': id,
      'method': Method.toolsList,
      'params': ?params,
      '_meta': ?meta,
    }),
  );

  server.server.setRequestHandler<JsonRpcListResourcesRequest>(
    Method.resourcesList,
    (request, extra) async => ListResourcesResult(
      resources: [
        Resource(
          uri: request.listParams.cursor == null
              ? 'test://resource-one'
              : 'test://resource-two',
          name: request.listParams.cursor == null
              ? 'resource-one'
              : 'resource-two',
        ),
      ],
      nextCursor: request.listParams.cursor == null ? 'resources-page-2' : null,
    ),
    (id, params, meta) => JsonRpcListResourcesRequest.fromJson({
      'jsonrpc': jsonRpcVersion,
      'id': id,
      'method': Method.resourcesList,
      'params': ?params,
      '_meta': ?meta,
    }),
  );

  server.server.setRequestHandler<JsonRpcListPromptsRequest>(
    Method.promptsList,
    (request, extra) async => ListPromptsResult(
      prompts: [
        Prompt(
          name: request.listParams.cursor == null ? 'prompt-one' : 'prompt-two',
        ),
      ],
      nextCursor: request.listParams.cursor == null ? 'prompts-page-2' : null,
    ),
    (id, params, meta) => JsonRpcListPromptsRequest.fromJson({
      'jsonrpc': jsonRpcVersion,
      'id': id,
      'method': Method.promptsList,
      'params': ?params,
      '_meta': ?meta,
    }),
  );

  await server.connect(StdioServerTransport());
}
