<div align="center">

# Dart Agent Core

**一个 mobile-first、local-first 的 Dart 库，用于构建和评估有状态、可调用工具的 AI Agent**

[English](README.md) | [简体中文](README.zh-CN.md)

[![Pub Version](https://img.shields.io/pub/v/dart_agent_core?color=blue&style=flat-square)](https://pub.dev/packages/dart_agent_core)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg?style=flat-square)](LICENSE)
[![Dart SDK Version](https://badgen.net/pub/sdk-version/dart_agent_core?style=flat-square)](https://pub.dev/packages/dart_agent_core)

</div>

`dart_agent_core` 是一个 mobile-first、local-first 的 Dart Agent 框架，实现了包含工具调用、状态持久化、多轮记忆、Skill 系统、上下文压缩、MCP 与 Agent 评估的完整 agentic loop。它可连接主流 LLM 提供商（OpenAI、Gemini、Claude 及任何 OpenAI 兼容 API），并将工具编排、流式输出、规划、子 Agent 委派等能力全部放在 Dart 侧，适合直接在 Flutter 应用中使用，而不依赖 Python 或 Node.js 后端。

---

## 特性

- **多 Provider 支持**：提供统一的 `LLMClient` 接口，内置支持 OpenAI（Chat Completions 与 Responses API）、Google Gemini、Anthropic Claude（直连与 AWS Bedrock）。同时，由于大量国产大模型兼容 OpenAI API，可通过 `OpenAIClient` 直接接入 Kimi、通义千问、智谱 GLM、Ollama 等；通过 `ResponsesClient` 接入火山引擎豆包；通过 `ClaudeClient` 接入 MiniMax。
- **工具调用**：将任意 Dart 函数封装为带 JSON Schema 的工具。Agent 会自动发起调用、回填结果并循环执行直到任务完成。工具支持两种参数模式：函数模式（通过 `Function.apply` 进行位置参数/命名参数映射）和对象模式（将所有参数作为 `Map<String, dynamic>` 直接传入）。工具可返回 `AgentToolResult`，携带多模态内容、元数据或停止信号。
- **Model Context Protocol（MCP）**：连接本地 stdio 或远程 Streamable HTTP MCP Server。Agent 通过渐进式披露桥接层按需发现并调用 Server 提供的工具、资源和 Prompt。
- **多模态输入**：`UserMessage` 支持文本、图片、音频、视频和文档等内容片段。模型输出可包含文本、图片、视频和音频。
- **有状态会话**：`AgentState` 追踪对话历史、Token 使用量、激活技能、计划与自定义元数据。`FileStateStorage` 可将状态以 JSON 持久化到磁盘。
- **Agent 评估**：直接对 Dart Agent 代码运行评估套件，支持 task、grader、transcript、record/replay、报告，以及 pass@k / pass^k 指标。
- **流式输出**：`runStream()` 会产出 `StreamingEvent`，包含模型分片、工具调用请求/结果、重试等事件，适合 Flutter 实时 UI。
- **纯Dart Skill**：可定义模块化能力（`Skill`），每个 Skill 包含独立 system prompt 与工具。Skill 可设为常驻（`forceActivate`）或在运行时动态开关，以节省上下文窗口。
- **基于文件的 Skill**：可从本地目录中的 `SKILL.md` 动态加载 Skill。配置 `javaScriptRuntime` 后，这类 Skill 可通过 `RunJavaScript` 执行 JavaScript 脚本，并支持 bridge 扩展。
- **子 Agent 委派**：支持注册命名子 Agent，或使用 `clone` 克隆 Worker Agent，并在隔离上下文中执行任务。
- **规划能力**：可选 `PlanMode` 会注入 `write_todos` 工具，让 Agent 在执行过程中维护步骤化任务清单。
- **上下文压缩**：`LLMBasedContextCompressor` 会在 Token 超阈值时将旧消息总结为情节记忆（episodic memory），并可通过内置 `retrieve_memory` 工具回溯原始消息。
- **循环检测**：`DefaultLoopDetector` 可识别重复工具调用，也可定期做 LLM 诊断以捕捉更隐蔽的循环。
- **控制器事件**：`AgentController` 发布运行、模型调用、工具调用、计划、重试、取消和错误等生命周期事件，用于观测。
- **Agent Hook**：统一的 `AgentHook` pipeline 可改写模型输入、转换流式分片与最终响应、拒绝/延后/改写工具调用、注入后续上下文、继续最终回合、中止运行，并包裹状态持久化。

---

## 安装

```yaml
dependencies:
  dart_agent_core: ^2.1.0
```

---

## 平台支持

`dart_agent_core` 可运行于全部六个 Dart/Flutter 平台 —— **Android、iOS、Web、Windows、macOS 和 Linux** —— 并且**兼容 WebAssembly（WASM）**（[pub.dev](https://pub.dev/packages/dart_agent_core) 上 6/6 平台）。平台相关的实现（文件系统状态存储、HTTP 适配器、JavaScript 运行时）通过条件导出（conditional exports）在编译期解析，因此原生端与 Web 端的公开 API 完全一致。

Web 端没有 `dart:io`，因此无法使用 `Platform.environment`。请改从浏览器读取 API Key —— 例如通过 `package:web` 从 `localStorage` 读取（WASM 安全）：

```dart
import 'package:web/web.dart' as web;
import 'package:dart_agent_core/dart_agent_core.dart';

void main() async {
  // 在应用中先写入密钥（例如设置页面）：
  //   web.window.localStorage.setItem('OPENAI_API_KEY', '<key>');
  final apiKey = web.window.localStorage.getItem('OPENAI_API_KEY') ?? '';
  final client = OpenAIClient(apiKey: apiKey);
  // ... 与快速开始相同的 StatefulAgent 配置
}
```

> 请在 `dependencies` 中添加 `web: ^1.0.0` 以使用 `package:web`。避免使用旧的 `dart:html`，它不兼容 WASM。在 Web 端请使用基于内存或 `localStorage` 的 `StateStorage`，而不是需要真实文件系统的 `FileStateStorage`。

---

## 快速开始

```dart
import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';

String getWeather(String location) {
  if (location.toLowerCase().contains('tokyo')) return 'Sunny, 25°C';
  return 'Weather data not available for this location';
}

void main() async {
  final apiKey = Platform.environment['OPENAI_API_KEY'] ?? '';
  final client = OpenAIClient(apiKey: apiKey);
  final modelConfig = ModelConfig(model: 'gpt-4o-mini');

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
    name: 'weather_agent',
    client: client,
    tools: [weatherTool],
    modelConfig: modelConfig,
    state: AgentState.empty(),
    systemPrompts: ['You are a helpful assistant.'],
  );

  final responses = await agent.run([
    UserMessage.text('What is the weather like in Tokyo right now?'),
  ]);

  print((responses.last as ModelMessage).textOutput);
}
```

---

## 支持的 Provider

`dart_agent_core` 通过统一的 `LLMClient` 接口屏蔽了不同 LLM 提供商的差异。只需初始化对应的客户端，传给 `StatefulAgent` 即可。

由于大量国产大模型都兼容 OpenAI Chat Completions API，你可以直接用 `OpenAIClient` 修改 `baseUrl` 来接入。

### OpenAI（Chat Completions）

```dart
final client = OpenAIClient(
  apiKey: Platform.environment['OPENAI_API_KEY'] ?? '',
  // baseUrl 默认为 'https://api.openai.com'
  // 可覆盖为 Azure OpenAI 或兼容代理地址
);
```

### OpenAI（Responses API）

使用新的有状态 Responses API。客户端会自动从 `ModelMessage` 提取 `responseId`，并在后续请求中通过 `previous_response_id` 传入，因此只需发送新增消息。

```dart
final client = ResponsesClient(
  apiKey: Platform.environment['OPENAI_API_KEY'] ?? '',
);
```

### Google Gemini

```dart
final client = GeminiClient(
  apiKey: Platform.environment['GEMINI_API_KEY'] ?? '',
);
```

### Anthropic Claude（直连）

直接调用 Anthropic Messages API，无需 AWS Bedrock。

```dart
final client = ClaudeClient(
  apiKey: Platform.environment['ANTHROPIC_API_KEY'] ?? '',
);
```

### AWS Bedrock（Claude）

通过 AWS Signature V4 鉴权，而不是简单 API Key。

```dart
final client = BedrockClaudeClient(
  region: 'us-east-1',
  accessKeyId: Platform.environment['AWS_ACCESS_KEY_ID'] ?? '',
  secretAccessKey: Platform.environment['AWS_SECRET_ACCESS_KEY'] ?? '',
);
```

### Kimi（Moonshot AI）

Kimi 兼容 OpenAI Chat Completions API，直接用 `OpenAIClient` 指向 Kimi 的 baseUrl。支持 `kimi-k2`、`kimi-k2-thinking` 等模型。thinking 模型的 `reasoning_content` 会自动处理。

```dart
final client = OpenAIClient(
  apiKey: Platform.environment['MOONSHOT_API_KEY'] ?? '',
  baseUrl: 'https://api.moonshot.cn/v1',
);
final config = ModelConfig(model: 'kimi-k2');
```

### 通义千问（Qwen）

阿里云 DashScope 兼容 OpenAI API。

```dart
final client = OpenAIClient(
  apiKey: Platform.environment['DASHSCOPE_API_KEY'] ?? '',
  baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
);
final config = ModelConfig(model: 'qwen3.5-plus');
```

### 智谱 GLM

智谱 GLM 兼容 OpenAI API。

```dart
final client = OpenAIClient(
  apiKey: Platform.environment['GLM_API_KEY'] ?? '',
  baseUrl: 'https://open.bigmodel.cn/api/coding/paas/v4',
);
final config = ModelConfig(model: 'GLM-4.7');
```

### 火山引擎豆包（Doubao-Seed）

豆包兼容 OpenAI Responses API，使用 `ResponsesClient`。

```dart
final client = ResponsesClient(
  apiKey: Platform.environment['ARK_API_KEY'] ?? '',
  baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
);
final config = ModelConfig(model: 'doubao-seed-1-8-251228');
```

### MiniMax

MiniMax 兼容 Anthropic API 格式，使用 `ClaudeClient`。

```dart
final client = ClaudeClient(
  apiKey: Platform.environment['MINIMAX_API_KEY'] ?? '',
  baseUrl: 'https://api.minimaxi.com/anthropic',
);
final config = ModelConfig(model: 'MiniMax-M2.5');
```

### Ollama（本地部署）

Ollama 在本地暴露 OpenAI 兼容 API，无需 API Key。

```dart
final client = OpenAIClient(
  apiKey: '', // Ollama 不需要 API Key
  baseUrl: 'http://localhost:11434/v1',
);
final config = ModelConfig(model: 'qwen2.5:7b');
```

### OpenRouter

OpenRouter 聚合了多家模型，兼容 OpenAI API。

```dart
final client = OpenAIClient(
  apiKey: Platform.environment['OPENROUTER_API_KEY'] ?? '',
  baseUrl: 'https://openrouter.ai/api/v1',
);
final config = ModelConfig(model: 'anthropic/claude-opus-4.6');
```

所有客户端都支持通过 `proxyUrl` 配置 HTTP 代理，并可设置重试和超时参数。详见 [Providers 文档](doc/providers.md)。

---

## 工具调用

可将任何同步或异步 Dart 函数包装为工具。Agent 会解析模型返回的函数调用 JSON，将参数映射到 Dart 函数参数，执行后再把结果喂回模型。

```dart
final tool = Tool(
  name: 'search_products',
  description: 'Search the product catalog.',
  executable: searchProducts,
  parameters: {
    'type': 'object',
    'properties': {
      'query': {'type': 'string'},
      'maxResults': {'type': 'integer'},
    },
    'required': ['query'],
  },
  namedParameters: ['maxResults'], // maps to Dart named parameters
);
```

也可以使用 `parameterMode: ToolParameterMode.object`，将所有参数作为一个 `Map<String, dynamic>` 直接传入，跳过位置参数/命名参数的映射：

```dart
final tool = Tool(
  name: 'search_products',
  description: 'Search the product catalog.',
  parameterMode: ToolParameterMode.object,
  executable: (Map<String, dynamic> args) async {
    final query = args['query'] as String;
    final maxResults = args['maxResults'] as int? ?? 10;
    return await searchProducts(query, maxResults);
  },
  parameters: {
    'type': 'object',
    'properties': {
      'query': {'type': 'string'},
      'maxResults': {'type': 'integer'},
    },
    'required': ['query'],
  },
);
```

工具可通过 `AgentCallToolContext.current` 访问当前会话状态，无需显式传参：

```dart
String checkBalance(String currency) {
  final userId = AgentCallToolContext.current?.state.metadata['user_id'];
  return fetchBalance(userId, currency);
}
```

若需高级控制，可返回 `AgentToolResult`：

```dart
Future<AgentToolResult> generateChart(String query) async {
  final imageBytes = await chartService.render(query);
  return AgentToolResult(
    content: ImagePart(base64Encode(imageBytes), 'image/png'),
    stopFlag: true,  // stop the agent loop after this tool
    metadata: {'chart_type': 'bar'},
  );
}
```

关于参数模式、异步工具等细节，见 [Tools & Planning 文档](doc/tools_and_planning.md)。

---

## Model Context Protocol（MCP）

在每次运行前先连接 `McpManager`，再将它传给 `StatefulAgent`。Agent 会注入六个固定桥接工具，让模型按需发现和使用 MCP 工具、资源及 Prompt，无需把所有远程 Schema 都塞进系统提示词。

```dart
final mcpManager = McpManager();
await mcpManager.connectAll([
  McpConnectionConfig(
    serverName: 'workspace',
    type: McpTransportType.http,
    url: 'https://example.com/mcp',
    headers: {'Authorization': 'Bearer $mcpToken'},
  ),
]);

final agent = StatefulAgent(
  ...,
  mcpManager: mcpManager,
);

await agent.run([
  UserMessage.text('使用可用的 MCP Server 检查工作区。'),
]);
```

HTTP transport 支持包括 Web 在内的全部平台；stdio transport 会启动本地进程，仅适用于 Dart IO 平台。MCP 连接以单次 Agent run 为生命周期：`run()` / `runStream()` 清理时会自动断开，因此后续运行前需要再次调用 `connectAll()`。

传输配置、生命周期和桥接工具详见 [MCP 指南](doc/mcp.zh-CN.md)与 [可运行示例](example/simple_agent_with_mcp_example.dart)。

---

## Skill 系统

`dart_agent_core` 支持两种 Skill 类型：

1) **纯 Dart Skill**（`Skill` 对象）
2) **基于文件的 Skill**（从目录动态发现 `SKILL.md`）

两种模式在 `StatefulAgent` 中互斥（每个 Agent 实例只能二选一）。

### 纯 Dart Skill

纯 Dart Skill 是模块化能力单元，由系统提示词与可选工具组成。Agent 可在运行时激活/停用 Skill，使上下文更聚焦。

```dart
class CodeReviewSkill extends Skill {
  CodeReviewSkill() : super(
    name: 'code_review',
    description: 'Review code for bugs and style issues.',
    systemPrompt: 'You are an expert code reviewer. Check for security issues and logic errors.',
    tools: [readFileTool, lintTool],
  );
}

final agent = StatefulAgent(
  ...
  skills: [CodeReviewSkill(), DataAnalysisSkill()],
);
```

- **动态技能**（默认）：初始不激活。Agent 会获得 `activate_skills` / `deactivate_skills` 工具，根据任务动态切换。
- **常驻技能**（`forceActivate: true`）：始终激活，不能停用。

### 基于文件的 Skill（`SKILL.md`）

基于文件的 Skill 模式会从本地目录加载 Skill：先发现可用 Skill，再按需读取 `SKILL.md`，激活后将 Skill 内容注入对话上下文。

```dart
final agent = StatefulAgent(
  ...
  // 宿主应用需提供文件工具（例如 Read、LS）
  tools: [readTool, lsTool],
  skillDirectoryPaths: [
    '/absolute/path/to/system_skills',
    '/absolute/path/to/project_skills',
  ],
  javaScriptRuntime: NodeJavaScriptRuntime(), // 可选，开启 RunJavaScript 能力
  skills: null, // 与 skillDirectoryPaths 不能同时使用
);
```

当基于文件的 Skill 模式下配置了 `javaScriptRuntime`，框架会暴露 `RunJavaScript` 工具。

#### 在 Flutter 中配置 `RunJavaScript`

在 Flutter 应用里，你需要实现一个自定义 `JavaScriptRuntime`（例如基于 `flutter_js`），并注入到 `StatefulAgent`。

1. 在 Flutter 工程添加依赖：

```yaml
dependencies:
  flutter_js: ^0.8.7
```

2. 实现并注入 `JavaScriptRuntime`：

```dart
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:flutter_js/flutter_js.dart' as flutter_js;

final agent = StatefulAgent(
  ...
  skillDirectoryPaths: ['/absolute/path/to/skills_root'],
  javaScriptRuntime: FlutterJavaScriptRuntime(
    runtime: flutter_js.getJavascriptRuntime(),
  ),
);
```

3. （可选）注册桥接通道，扩展本地能力：

```dart
agent.registerJavaScriptBridgeChannel('local.greeting', (payload, context) {
  final name = (payload['name'] ?? 'friend').toString();
  return {'message': 'Hello, $name'};
});
```

桥接通道可由宿主应用扩展：
- `registerJavaScriptBridgeChannel(channel, handler)`
- `unregisterJavaScriptBridgeChannel(channel)`

---

## 子 Agent 委派

可注册专长子 Agent 来处理可并行或专业化任务。每个 Worker 都运行在隔离的 `AgentState` 中。

```dart
final agent = StatefulAgent(
  ...
  subAgents: [
    SubAgent(
      name: 'researcher',
      description: 'Searches the web and summarizes findings.',
      agentFactory: (parent) => StatefulAgent(
        name: 'researcher',
        client: parent.client,
        modelConfig: parent.modelConfig,
        state: AgentState.empty(),
        tools: [webSearchTool],
        isSubAgent: true,
      ),
    ),
  ],
);
```

Agent 通过内置 `delegate_task` 工具进行分派：

- `assignee: 'clone'`：克隆当前 Agent 并使用干净上下文。
- `assignee: 'researcher'`：调用已注册的命名子 Agent。

---

## 流式输出

`runStream()` 会产出细粒度事件，便于 Flutter UI 实时联动：

```dart
await for (final event in agent.runStream([UserMessage.text('Hello')])) {
  switch (event.eventType) {
    case StreamingEventType.modelChunkMessage:
      final chunk = event.data as ModelMessage;
      // update text in UI incrementally
      break;
    case StreamingEventType.fullModelMessage:
      // complete assembled message for this turn
      break;
    case StreamingEventType.functionCallRequest:
      // model requested tool calls
      break;
    case StreamingEventType.functionCallResult:
      // tool execution finished
      break;
    default:
      break;
  }
}
```

---

## 规划（Planning）

将 `planMode` 设为 `PlanMode.auto`（或 `PlanMode.must`）即可启用规划器。系统会注入 `write_todos` 工具，让 Agent 维护包含 `pending`、`in_progress`、`completed`、`cancelled` 状态的任务清单。

```dart
final agent = StatefulAgent(
  ...
  planMode: PlanMode.auto,
);
```

可通过 `AgentController` 响应计划变化：

```dart
controller.on<PlanChangedEvent>((event) {
  for (final step in event.plan.steps) {
    print('[${step.status.name}] ${step.description}');
  }
});
```

---

## 上下文压缩

对于长会话，可挂载压缩器，在 Token 超过阈值时自动总结旧消息：

```dart
final agent = StatefulAgent(
  ...
  compressor: LLMBasedContextCompressor(
    client: client,
    modelConfig: ModelConfig(model: 'gpt-4o-mini'),
    totalTokenThreshold: 64000,
    keepRecentMessageSize: 10,
  ),
);
```

压缩后的历史会保存为情节记忆（episodic memory）。当摘要不够详细时，Agent 可通过内置 `retrieve_memory` 工具获取原始消息。

---

## 控制器事件

`AgentController` 用于观测生命周期事件，不改变 Agent 行为：

```dart
final controller = AgentController();

controller.on<AfterToolCallEvent>((event) {
  print('Tool ${event.result.name} finished');
});

final agent = StatefulAgent(..., controller: controller);
```

---

## Agent Hook

如需控制 Agent loop，使用 `AgentHook`。Hook 接收 typed context 并返回 typed outcome。只想影响本次模型调用时，改写 request；需要影响后续 loop 或 resume 时，直接写入 `context.state`。

```dart
class RuntimeContextHook extends AgentHook {
  @override
  ModelCallHookResult beforeModelCall(ModelCallHookContext context) {
    final transientMessage = UserMessage.text(
      'Current time: ${DateTime.now()}',
    );

    return ModelCallHookResult.proceed(
      request: context.request.copyWith(
        requestMessages: [
          ...context.request.requestMessages,
          transientMessage,
        ],
      ),
    );
  }
}

class DeleteFilePolicyHook extends AgentHook {
  @override
  ToolCallHookResult beforeToolCall(ToolCallHookContext context) {
    if (context.call.name != 'delete_file') {
      return ToolCallHookResult.proceed(context.call);
    }
    return ToolCallHookResult.deny(
      content: [TextPart('delete_file is blocked by local policy.')],
    );
  }
}

final agent = StatefulAgent(
  ...,
  hooks: [RuntimeContextHook(), DeleteFilePolicyHook()],
);
```

可用 hook phase 包括 `beforeRun`、`beforeModelCall`、`onModelChunk`、`afterModelCall`、`beforeToolCall`、`afterToolCall`、`onTurnCompletion`、`beforePersistState`、`afterPersistState` 和 `afterRun`。

---

## 示例

查看 [`example/`](example) 目录：

- [基础工具调用 Agent](example/simple_agent_example.dart)
- [流式响应](example/simple_agent_stream_example.dart)
- [跨会话状态持久化](example/simple_agent_with_state_example.dart)
- [使用 write_todos 做规划](example/simple_agent_with_plan_example.dart)
- [动态技能系统](example/simple_agent_with_skills_example.dart)
- [基于文件的 Skill + JavaScript 脚本执行](example/simple_agent_with_directory_skills_example.dart)
- [子 Agent 委派](example/simple_agent_with_sub_agent_example.dart)
- [控制器事件 + Hook 策略](example/simple_agent_with_controller_example.dart)
- [统一 Agent Hook](example/simple_agent_with_hooks_example.dart)
- [Model Context Protocol（MCP）](example/simple_agent_with_mcp_example.dart)
- [Bedrock 下的 Claude Extended Thinking](example/simple_agent_with_thinking_example.dart)
- [OpenAI](example/simple_agent_with_openai_example.dart)
- [Gemini](example/simple_agent_with_gemini_example.dart)
- [Claude（直连 Anthropic）](example/simple_agent_with_claude_example.dart)
- [AWS Bedrock（Claude）](example/simple_agent_with_bedrock_claude_example.dart)
- [Kimi（Moonshot AI）](example/simple_agent_with_kimi_example.dart)
- [通义千问（Qwen）](example/simple_agent_with_qwen_example.dart)
- [智谱 GLM](example/simple_agent_with_glm_example.dart)
- [火山引擎豆包（Seed）](example/simple_agent_with_seed_example.dart)
- [MiniMax](example/simple_agent_with_minimax_example.dart)
- [Ollama（本地部署）](example/simple_agent_with_ollama_example.dart)
- [OpenRouter](example/simple_agent_with_openrouter_example.dart)

---

## 文档

- [架构与生命周期](doc/architecture.md) — Agent 循环、流式事件、Agent Hook、循环检测、取消机制
- [LLM Provider 与配置](doc/providers.md) — OpenAI、Gemini、Bedrock、Claude、Kimi、Qwen、GLM 等配置，ModelConfig，代理支持
- [工具与规划](doc/tools_and_planning.md) — 工具创建、参数映射、AgentToolResult、技能、子 Agent、规划器
- [Model Context Protocol](doc/mcp.zh-CN.md) — stdio/HTTP 连接、渐进式发现、桥接工具、生命周期与平台说明
- [状态与记忆管理](doc/state_and_memory.md) — AgentState、FileStateStorage、上下文压缩、情节记忆
- [评估指南](doc/eval-guide.zh-CN.md) — 对齐 Anthropic 方法论的评估子系统：task / grader / suite、pass@k / pass^k、录制回放、Langfuse 上报、跨 run 健康度

---

## 贡献

欢迎提交 Issue 和 Pull Request。对于较大改动，建议先开 Issue 讨论。

---

## 关于

`dart_agent_core` 由 [Memex Lab](https://memexlab.ai) 开发维护。访问我们的主页了解更多项目和动态。
