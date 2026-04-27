<div align="center">

# Dart Agent Core

**一个 mobile-first、local-first 的 Dart 库，用于构建有状态、可调用工具的 AI Agent**

[English](README.md) | [简体中文](README.zh-CN.md)

[![Pub Version](https://img.shields.io/pub/v/dart_agent_core?color=blue&style=flat-square)](https://pub.dev/packages/dart_agent_core)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg?style=flat-square)](LICENSE)
[![Dart SDK Version](https://badgen.net/pub/sdk-version/dart_agent_core?style=flat-square)](https://pub.dev/packages/dart_agent_core)

</div>

`dart_agent_core` 是一个 mobile-first、local-first 的 Dart Agent 框架，实现了包含工具调用、状态持久化、多轮记忆、Skill 系统与上下文压缩的完整 agentic loop。它可连接主流 LLM 提供商（OpenAI、Gemini、Claude 及任何 OpenAI 兼容 API），并将工具编排、流式输出、规划、子 Agent 委派等能力全部放在 Dart 侧，适合直接在 Flutter 应用中使用，而不依赖 Python 或 Node.js 后端。

---

## 特性

- **多 Provider 支持**：提供统一的 `LLMClient` 接口，内置支持 OpenAI（Chat Completions 与 Responses API）、Google Gemini、Anthropic Claude（直连与 AWS Bedrock）。同时，由于大量国产大模型兼容 OpenAI API，可通过 `OpenAIClient` 直接接入 Kimi、通义千问、智谱 GLM、Ollama 等；通过 `ResponsesClient` 接入火山引擎豆包；通过 `ClaudeClient` 接入 MiniMax。
- **工具调用**：将任意 Dart 函数封装为带 JSON Schema 的工具。Agent 会自动发起调用、回填结果并循环执行直到任务完成。工具支持两种参数模式：函数模式（通过 `Function.apply` 进行位置参数/命名参数映射）和对象模式（将所有参数作为 `Map<String, dynamic>` 直接传入）。工具可返回 `AgentToolResult`，携带多模态内容、元数据或停止信号。
- **多模态输入**：`UserMessage` 支持文本、图片、音频、视频和文档等内容片段。模型输出可包含文本、图片、视频和音频。
- **有状态会话**：`AgentState` 追踪对话历史、Token 使用量、激活技能、计划与自定义元数据。`FileStateStorage` 可将状态以 JSON 持久化到磁盘。
- **流式输出**：`runStream()` 会产出 `StreamingEvent`，包含模型分片、工具调用请求/结果、重试等事件，适合 Flutter 实时 UI。
- **纯Dart Skill**：可定义模块化能力（`Skill`），每个 Skill 包含独立 system prompt 与工具。Skill 可设为常驻（`forceActivate`）或在运行时动态开关，以节省上下文窗口。
- **基于文件的 Skill**：可从本地目录中的 `SKILL.md` 动态加载 Skill。配置 `javaScriptRuntime` 后，这类 Skill 可通过 `RunJavaScript` 执行 JavaScript 脚本，并支持 bridge 扩展。
- **子 Agent 委派**：支持注册命名子 Agent，或使用 `clone` 克隆 Worker Agent，并在隔离上下文中执行任务。
- **规划能力**：可选 `PlanMode` 会注入 `write_todos` 工具，让 Agent 在执行过程中维护步骤化任务清单。
- **上下文压缩**：`LLMBasedContextCompressor` 会在 Token 超阈值时将旧消息总结为情节记忆（episodic memory），并可通过内置 `retrieve_memory` 工具回溯原始消息。
- **循环检测**：`DefaultLoopDetector` 可识别重复工具调用，也可定期做 LLM 诊断以捕捉更隐蔽的循环。
- **控制器钩子**：`AgentController` 可在关键节点（运行前、LLM 调用前、工具调用前后）进行拦截，允许宿主应用审批或中止流程。
- **系统回调**：`systemCallback` 会在每次 LLM 调用前执行，你可以动态修改系统消息、工具列表或请求消息。

---

## 安装

```yaml
dependencies:
  dart_agent_core: ^1.0.7
```

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
  skillDirectoryPath: '/absolute/path/to/skills_root',
  javaScriptRuntime: NodeJavaScriptRuntime(), // 可选，开启 RunJavaScript 能力
  skills: null, // 与 skillDirectoryPath 不能同时使用
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
  skillDirectoryPath: '/absolute/path/to/skills_root',
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

参考实现：
- 查看 `lib/src/agent/javascript_runtime.dart`（注释中的 `FlutterJavaScriptRuntime` 完整示例）。

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

## 控制器钩子

`AgentController` 提供生命周期拦截点：

```dart
final controller = AgentController();

// Pub/Sub: observe events
controller.on<AfterToolCallEvent>((event) {
  print('Tool ${event.result.name} finished');
});

// Request/Response: approve or block steps
controller.registerHandler<BeforeToolCallRequest, BeforeToolCallResponse>(
  (request) async {
    if (request.functionCall.name == 'delete_files') {
      return BeforeToolCallResponse(approve: false);
    }
    return BeforeToolCallResponse(approve: true);
  },
);

final agent = StatefulAgent(..., controller: controller);
```

---

## 系统回调（System Callback）

如需在每次 LLM 调用前动态调整行为，可使用 `systemCallback`。它可修改系统消息、工具列表和请求消息：

```dart
final agent = StatefulAgent(
  ...
  systemCallback: (agent, systemMessage, tools, messages) async {
    final updated = SystemMessage(
      '${systemMessage?.content ?? ''}\nCurrent time: ${DateTime.now()}',
    );
    return (updated, tools, messages);
  },
);
```

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
- [控制器钩子（观测与拦截）](example/simple_agent_with_controller_example.dart)
- [Bedrock 下的 Claude Extended Thinking](example/simple_agent_with_thinking_example.dart)
- [OpenAI](example/simple_agent_with_openai_example.dart)
- [Gemini](example/simple_agent_with_gemini_example.dart)
- [Claude（直连 Anthropic）](example/simple_agent_with_claude_example.dart)
- [Kimi（Moonshot AI）](example/simple_agent_with_kimi_example.dart)
- [Kimi 图片分析](example/simple_agent_with_kimi_vision_example.dart)
- [通义千问（Qwen）](example/simple_agent_with_qwen_example.dart)
- [智谱 GLM](example/simple_agent_with_glm_example.dart)
- [火山引擎豆包（Seed）](example/simple_agent_with_seed_example.dart)
- [MiniMax](example/simple_agent_with_minimax_example.dart)
- [Ollama（本地部署）](example/simple_agent_with_ollama_example.dart)
- [OpenRouter](example/simple_agent_with_openrouter_example.dart)

---

## 文档

- [架构与生命周期](doc/architecture.md) — Agent 循环、流式事件、控制器钩子、循环检测、取消机制
- [LLM Provider 与配置](doc/providers.md) — OpenAI、Gemini、Bedrock、Claude、Kimi、Qwen、GLM 等配置，ModelConfig，代理支持
- [工具与规划](doc/tools_and_planning.md) — 工具创建、参数映射、AgentToolResult、技能、子 Agent、规划器
- [状态与记忆管理](doc/state_and_memory.md) — AgentState、FileStateStorage、上下文压缩、情节记忆

---

## 贡献

欢迎提交 Issue 和 Pull Request。对于较大改动，建议先开 Issue 讨论。
