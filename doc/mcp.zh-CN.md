# Model Context Protocol（MCP）

`dart_agent_core` 可以让 `StatefulAgent` 连接一个或多个 MCP Server。框架使用一组固定桥接工具暴露 MCP 能力，而不是把所有远程工具直接注册给 LLM。

## 工作方式

MCP 集成采用三层渐进式披露：

1. 系统提示词只列出已连接的 Server、描述与能力数量。
2. 模型通过桥接工具查看指定 Server 的工具、资源或 Prompt。
3. 模型只调用或读取当前任务需要的能力。

这样可以保持模型工具列表稳定，并避免预先把所有远程 JSON Schema 塞进上下文。

## 连接 Server

创建 `McpManager`，调用 `connectAll()`，然后把已连接的 Manager 传给 `StatefulAgent`。

### Streamable HTTP

HTTP 支持 Android、iOS、Web、Windows、macOS 与 Linux。

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

Stdio 会启动本地子进程，仅适用于 Dart IO 平台。显式配置的环境变量会覆盖父进程中的同名变量，同时继承其余父进程变量。

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

每个 `serverName` 必须唯一。`connectAll()` 会在打开任何连接前拒绝重复名称。单个 Server 连接失败会被记录，但不会阻止其他 Server 继续连接。如果业务要求 MCP 必须可用，请在连接后检查 `manager.hasServers`、`manager.serverNames` 或 `manager.getSession(name)`。

## 挂载到 Agent

```dart
final agent = StatefulAgent(
  name: 'mcp_agent',
  client: client,
  modelConfig: modelConfig,
  state: AgentState.empty(),
  mcpManager: manager,
);

final messages = await agent.run([
  UserMessage.text('使用 knowledge Server 回答这个问题。'),
]);
```

只有连接成功的 Server 才会出现在系统提示词和桥接工具中。

## 桥接工具

Manager 存在已连接 Server 时，Agent 会注册以下工具：

| 桥接工具 | 用途 |
| --- | --- |
| `mcp_list_tools` | 发现 Server 的工具及输入 Schema |
| `mcp_call_tool` | 使用 JSON 参数对象调用已发现的工具 |
| `mcp_list_resources` | 发现可用资源 URI |
| `mcp_read_resource` | 按 URI 读取资源 |
| `mcp_list_prompts` | 发现 Prompt 模板及其参数 |
| `mcp_get_prompt` | 使用可选参数渲染 Prompt 模板 |

每次桥接调用都必须提供 `server_name`。能力发现会沿 MCP 分页读取所有页面；重复游标或异常长的分页序列会被拒绝，以避免无限循环。

## 生命周期

MCP 连接以单次 Agent run 为生命周期：

1. 调用 `manager.connectAll(configs)`。
2. 调用 `agent.run()` 或消费 `agent.runStream()`。
3. `StatefulAgent` 在 run 清理阶段调用 `manager.disconnectAll()`。

复用同一个 Agent 处理后续请求时，需要先重新连接：

```dart
await manager.connectAll(configs);
await agent.run([UserMessage.text('第一次请求')]);

await manager.connectAll(configs);
await agent.run([UserMessage.text('第二次请求')]);
```

`disconnectAll()` 和 `dispose()` 都是幂等的，应用清理代码可以安全调用。

## 平台与安全注意事项

- Web 与 WASM 应用应使用 Streamable HTTP；浏览器不支持 stdio。
- 不要把认证 Header 或 stdio 环境变量提交到源码仓库。
- 本地 stdio Server 只应获得完成任务所需的最小目录和凭据权限。
- MCP Server 属于高权限集成：它的描述、工具输出、资源与 Prompt 都会成为模型可见内容。
- Manager 使用固定桥接工具名，因此应用工具应避免使用相同的 `mcp_*` 名称。

完整的远程 HTTP 示例见 [`example/simple_agent_with_mcp_example.dart`](../example/simple_agent_with_mcp_example.dart)。
