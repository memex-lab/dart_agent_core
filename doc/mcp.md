# Model Context Protocol (MCP)

`dart_agent_core` can connect a `StatefulAgent` to one or more MCP servers. MCP capabilities are exposed through a small, fixed bridge instead of registering every remote tool directly with the LLM.

## How it works

MCP integration uses three levels of progressive disclosure:

1. The system prompt lists connected servers, their descriptions, and capability counts.
2. The model uses bridge tools to inspect a selected server's tools, resources, or prompts.
3. The model calls or reads only the capability it needs.

This keeps the model tool list stable and avoids placing every remote JSON Schema in the context up front.

## Connect a server

Create an `McpManager`, call `connectAll()`, and pass the connected manager to `StatefulAgent`.

### Streamable HTTP

HTTP is available on Android, iOS, Web, Windows, macOS, and Linux.

```dart
final manager = McpManager();
await manager.connectAll([
  McpConnectionConfig(
    serverName: 'knowledge',
    type: McpTransportType.http,
    url: 'https://example.com/mcp',
    headers: {
      'Authorization': 'Bearer $token',
    },
  ),
]);
```

### Stdio

Stdio starts a local child process and is available on Dart IO platforms only. The configured environment overrides parent-process variables with the same names while inheriting all other parent variables.

```dart
final manager = McpManager();
await manager.connectAll([
  const McpConnectionConfig(
    serverName: 'filesystem',
    type: McpTransportType.stdio,
    command: 'npx',
    args: [
      '-y',
      '@modelcontextprotocol/server-filesystem',
      '/absolute/allowed/root',
    ],
    env: {'LOG_LEVEL': 'warn'},
  ),
]);
```

Each `serverName` must be unique. `connectAll()` rejects duplicate names before opening any connections. A failure to connect one server is logged without preventing other configured servers from connecting. Inspect `manager.hasServers`, `manager.serverNames`, or `manager.getSession(name)` after connection if availability is required.

## Attach the manager to an agent

```dart
final agent = StatefulAgent(
  name: 'mcp_agent',
  client: client,
  modelConfig: modelConfig,
  state: AgentState.empty(),
  mcpManager: manager,
);

final messages = await agent.run([
  UserMessage.text('Use the knowledge server to answer this question.'),
]);
```

Only successfully connected servers are included in the system prompt and bridge.

## Bridge tools

The agent registers these tools whenever the manager has connected servers:

| Bridge tool | Purpose |
| --- | --- |
| `mcp_list_tools` | Discover a server's tools and input schemas |
| `mcp_call_tool` | Invoke a discovered tool with a JSON argument object |
| `mcp_list_resources` | Discover available resource URIs |
| `mcp_read_resource` | Read a resource by URI |
| `mcp_list_prompts` | Discover prompt templates and their arguments |
| `mcp_get_prompt` | Render a prompt template with optional arguments |

Every bridge call requires `server_name`. Discovery follows MCP pagination until all pages are collected; repeated cursors and excessively long pagination sequences are rejected to prevent infinite loops.

## Lifecycle

MCP connections are scoped to one agent run:

1. Call `manager.connectAll(configs)`.
2. Call `agent.run()` or consume `agent.runStream()`.
3. `StatefulAgent` calls `manager.disconnectAll()` during run cleanup.

To reuse the same agent for another request, reconnect first:

```dart
await manager.connectAll(configs);
await agent.run([UserMessage.text('First request')]);

await manager.connectAll(configs);
await agent.run([UserMessage.text('Second request')]);
```

`disconnectAll()` and `dispose()` are idempotent and can be called by application cleanup code.

## Platform and security notes

- Streamable HTTP is the MCP transport for Web and WASM applications; stdio is not available in a browser.
- Keep authentication headers and stdio environment variables outside source control.
- Restrict local stdio servers to the minimum directories and credentials they need.
- Treat MCP servers as privileged integrations: their descriptions, tool outputs, resources, and prompts become model-visible content.
- The manager exposes fixed bridge tools, so avoid defining application tools with the same `mcp_*` names.

See [`example/simple_agent_with_mcp_example.dart`](../example/simple_agent_with_mcp_example.dart) for a complete remote HTTP example.
