<div align="center">

# Dart Agent Core

**A mobile-first, local-first Dart library for building and evaluating stateful, tool-using AI agents**

[English](README.md) | [简体中文](README.zh-CN.md)

[![Pub Version](https://img.shields.io/pub/v/dart_agent_core?color=blue&style=flat-square)](https://pub.dev/packages/dart_agent_core)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg?style=flat-square)](LICENSE)
[![Dart SDK Version](https://badgen.net/pub/sdk-version/dart_agent_core?style=flat-square)](https://pub.dev/packages/dart_agent_core)

</div>

`dart_agent_core` is a mobile-first, local-first Dart library that implements a full agentic loop with tool use, state persistence, multi-turn memory, skill system, context compression, and agent evals. It connects to mainstream LLM providers (OpenAI, Gemini, Claude, and any OpenAI-compatible API) and handles the orchestration layer — tool calling, streaming, planning, sub-agent delegation — entirely in Dart, making it suitable for Flutter apps without a Python or Node.js backend.

---

## Features

- **Multi-provider support**: Unified `LLMClient` interface for OpenAI (Chat Completions & Responses API), Google Gemini, and Anthropic Claude via AWS Bedrock.
- **Tool use**: Wrap any Dart function as a tool with a JSON Schema definition. The agent dispatches calls, feeds results back, and loops until done. Tools support two parameter modes: function mode (positional/named parameter mapping via `Function.apply`) and object mode (receive all arguments as a `Map<String, dynamic>`). Tools can return `AgentToolResult` to carry multimodal content, metadata, or a stop signal.
- **Multimodal input**: `UserMessage` accepts text, images, audio, video, and documents as content parts. Model responses can include text, images, video, and audio.
- **Stateful sessions**: `AgentState` tracks conversation history, token usage, active skills, plan, and custom metadata. `FileStateStorage` persists state to disk as JSON.
- **Agent evals**: Run evaluation suites against your Dart agent code with tasks, graders, transcripts, record/replay, reports, and pass@k / pass^k metrics.
- **Streaming**: `runStream()` yields `StreamingEvent`s for model chunks, tool call requests/results, and retries — suitable for real-time UI updates in Flutter.
- **Pure Dart Skills**: Define modular capabilities (`Skill`) with their own system prompts and tools. Skills can be always-on (`forceActivate`) or toggled dynamically by the agent at runtime to save context window.
- **File-system Skills**: Load Skills from `SKILL.md` files under a local directory root. With `javaScriptRuntime` configured, these Skills can execute JavaScript scripts via `RunJavaScript` and bridge channels.
- **Sub-agent delegation**: Register named sub-agents or use `clone` to delegate tasks to a worker agent with an isolated context.
- **Planning**: Optional `PlanMode` injects a `write_todos` tool that lets the agent maintain a step-by-step task list during execution.
- **Context compression**: `LLMBasedContextCompressor` summarizes old messages into episodic memory when the token count exceeds a threshold. The agent can recall original messages via the built-in `retrieve_memory` tool.
- **Loop detection**: `DefaultLoopDetector` catches repeated identical tool calls and can run periodic LLM-based diagnosis for subtler loops.
- **Controller events**: `AgentController` publishes observation events for run, model, tool, plan, retry, cancellation, and error lifecycle steps.
- **Agent hooks**: A unified `AgentHook` pipeline can rewrite model inputs, transform streaming chunks and final responses, deny/defer/rewrite tool calls, inject follow-up context, continue final turns, abort runs, and wrap state persistence.

---

## Installation

```yaml
dependencies:
  dart_agent_core: ^2.0.3
```

---

## Platform Support

`dart_agent_core` runs on all six Dart/Flutter platforms — **Android, iOS, Web, Windows, macOS, and Linux** — and is **WebAssembly (WASM) compatible** (6/6 platforms on [pub.dev](https://pub.dev/packages/dart_agent_core)). Platform-specific concerns (file-system state storage, HTTP adapters, JavaScript runtime) are resolved at compile time via conditional exports, so the public API is identical on native and web.

There is no `dart:io` on the web, so `Platform.environment` is unavailable. Read your API key from the browser instead — for example from `localStorage` via `package:web` (WASM-safe):

```dart
import 'package:web/web.dart' as web;
import 'package:dart_agent_core/dart_agent_core.dart';

void main() async {
  // Persist the key once from your app (e.g. a settings screen):
  //   web.window.localStorage.setItem('OPENAI_API_KEY', '<key>');
  final apiKey = web.window.localStorage.getItem('OPENAI_API_KEY') ?? '';
  final client = OpenAIClient(apiKey: apiKey);
  // ... same StatefulAgent setup as Quick Start
}
```

> Add `web: ^1.0.0` to your `dependencies` to use `package:web`. Avoid the legacy `dart:html`, which is not WASM-compatible. On web, use an in-memory or `localStorage`-backed `StateStorage` rather than `FileStateStorage`, which requires a real file system.

---

## Quick Start

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

## Supported Providers

### OpenAI (Chat Completions)

```dart
final client = OpenAIClient(
  apiKey: Platform.environment['OPENAI_API_KEY'] ?? '',
  // baseUrl defaults to 'https://api.openai.com'
  // Override for Azure OpenAI or compatible proxies
);
```

### OpenAI (Responses API)

Uses the newer stateful Responses API. The client automatically extracts `responseId` from `ModelMessage` and passes it as `previous_response_id` on subsequent requests, so only new messages are sent.

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

### AWS Bedrock (Claude)

Uses AWS Signature V4 for authentication instead of a simple API key.

```dart
final client = BedrockClaudeClient(
  region: 'us-east-1',
  accessKeyId: Platform.environment['AWS_ACCESS_KEY_ID'] ?? '',
  secretAccessKey: Platform.environment['AWS_SECRET_ACCESS_KEY'] ?? '',
);
```

### Anthropic Claude (Direct)

Directly calls the Anthropic Messages API, no AWS Bedrock needed.

```dart
final client = ClaudeClient(
  apiKey: Platform.environment['ANTHROPIC_API_KEY'] ?? '',
);
```

All clients support HTTP proxies via `proxyUrl` and configurable retry/timeout parameters. See [Providers doc](doc/providers.md) for details.

---

## Tool Use

Wrap any Dart function (sync or async) as a tool. The agent parses the LLM's function call JSON, maps arguments to your function's parameters, executes it, and feeds the result back.

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

Alternatively, use `parameterMode: ToolParameterMode.object` to receive all arguments as a single `Map<String, dynamic>`, bypassing positional/named parameter mapping:

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

Tools can access the current session state via `AgentCallToolContext.current` without explicit parameters:

```dart
String checkBalance(String currency) {
  final userId = AgentCallToolContext.current?.state.metadata['user_id'];
  return fetchBalance(userId, currency);
}
```

Return `AgentToolResult` for advanced control:

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

See [Tools & Planning doc](doc/tools_and_planning.md) for parameter modes, async tools, and more.

---

## Skill System

`dart_agent_core` supports two Skill types:

1) **Pure Dart Skills** (`Skill` objects)
2) **File-system Skills** (`SKILL.md` files discovered from a root directory)

These two modes are mutually exclusive in `StatefulAgent` (use one or the other per agent instance).

### Pure Dart Skills

Pure Dart Skills are modular capability units — a system prompt plus optional tools bundled under a name. The agent can activate/deactivate Skills at runtime to keep the context window focused.

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

- **Dynamic skills** (default): Start inactive. The agent gains `activate_skills` / `deactivate_skills` tools to toggle them based on the current task.
- **Always-on skills** (`forceActivate: true`): Permanently active, cannot be deactivated.

### File-system Skills (`SKILL.md`)

File-system Skill mode loads Skills from local folders: discover available Skills, read `SKILL.md` on demand, and inject Skill content into conversation context when activated.

```dart
final agent = StatefulAgent(
  ...
  // Required file tools should be provided by host app (for example: Read, LS).
  tools: [readTool, lsTool],
  skillDirectoryPath: '/absolute/path/to/skills_root',
  javaScriptRuntime: NodeJavaScriptRuntime(), // optional, enables RunJavaScript
  skills: null, // do not use with skillDirectoryPath
);
```

When `javaScriptRuntime` is configured in File-system Skill mode, the framework exposes `RunJavaScript`.

#### Flutter configuration for `RunJavaScript`

In Flutter apps, configure a custom `JavaScriptRuntime` implementation (for example using `flutter_js`) and pass it to `StatefulAgent`.

1. Add dependency in your Flutter app:

```yaml
dependencies:
  flutter_js: ^0.8.7
```

2. Implement `JavaScriptRuntime` and inject it:

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

3. (Optional) Register bridge channels for native capabilities:

```dart
agent.registerJavaScriptBridgeChannel('local.greeting', (payload, context) {
  final name = (payload['name'] ?? 'friend').toString();
  return {'message': 'Hello, $name'};
});
```

Bridge channels can be extended by host apps via:
- `registerJavaScriptBridgeChannel(channel, handler)`
- `unregisterJavaScriptBridgeChannel(channel)`

---

## Sub-Agent Delegation

Register sub-agents for specialized or parallelizable work. Each worker runs in its own isolated `AgentState`.

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

The agent uses the built-in `delegate_task` tool to dispatch work:

- `assignee: 'clone'` — creates a copy of the current agent with clean context.
- `assignee: 'researcher'` — uses a registered named sub-agent.

---

## Streaming

`runStream()` yields fine-grained events for Flutter UI integration:

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

## Planning

Pass `planMode: PlanMode.auto` (or `PlanMode.must`) to enable the planner. This injects a `write_todos` tool that the agent uses to create and update a task list with statuses: `pending`, `in_progress`, `completed`, `cancelled`.

```dart
final agent = StatefulAgent(
  ...
  planMode: PlanMode.auto,
);
```

React to plan changes via `AgentController`:

```dart
controller.on<PlanChangedEvent>((event) {
  for (final step in event.plan.steps) {
    print('[${step.status.name}] ${step.description}');
  }
});
```

---

## Context Compression

For long-running sessions, attach a compressor to automatically summarize old messages when token usage exceeds a threshold:

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

Compressed history is stored as episodic memories. The agent can retrieve the original messages via the built-in `retrieve_memory` tool when the summary isn't detailed enough.

---

## Controller Events

`AgentController` observes lifecycle events without changing agent behavior:

```dart
final controller = AgentController();

controller.on<AfterToolCallEvent>((event) {
  print('Tool ${event.result.name} finished');
});

final agent = StatefulAgent(..., controller: controller);
```

---

## Agent Hooks

Use `AgentHook` for controlled changes to the agent loop. Hooks receive typed context objects and return typed outcomes. To affect only the current model call, rewrite the request. To persist context for later loops or resume, write to `context.state`.

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

Available hook phases include `beforeRun`, `beforeModelCall`, `onModelChunk`, `afterModelCall`, `beforeToolCall`, `afterToolCall`, `onTurnCompletion`, `beforePersistState`, `afterPersistState`, and `afterRun`.

---

## Examples

See the [`example/`](example) directory:

- [Basic agent with tool use](example/simple_agent_example.dart)
- [Streaming responses](example/simple_agent_stream_example.dart)
- [Persistent state across sessions](example/simple_agent_with_state_example.dart)
- [Planning with write_todos](example/simple_agent_with_plan_example.dart)
- [Dynamic skill system](example/simple_agent_with_skills_example.dart)
- [File-system Skills + JavaScript scripts execute](example/simple_agent_with_directory_skills_example.dart)
- [Sub-agent delegation](example/simple_agent_with_sub_agent_example.dart)
- [Controller events + hook policy](example/simple_agent_with_controller_example.dart)
- [Unified agent hooks](example/simple_agent_with_hooks_example.dart)
- [Claude extended thinking via Bedrock](example/simple_agent_with_thinking_example.dart)
- [OpenAI](example/simple_agent_with_openai_example.dart)
- [Gemini](example/simple_agent_with_gemini_example.dart)
- [Claude (direct Anthropic API)](example/simple_agent_with_claude_example.dart)
- [AWS Bedrock (Claude)](example/simple_agent_with_bedrock_claude_example.dart)
- [Kimi (Moonshot AI)](example/simple_agent_with_kimi_example.dart)
- [Qwen (Alibaba DashScope)](example/simple_agent_with_qwen_example.dart)
- [Zhipu GLM](example/simple_agent_with_glm_example.dart)
- [Volcengine Doubao-Seed](example/simple_agent_with_seed_example.dart)
- [MiniMax](example/simple_agent_with_minimax_example.dart)
- [Ollama (local)](example/simple_agent_with_ollama_example.dart)
- [OpenRouter](example/simple_agent_with_openrouter_example.dart)

---

## Documentation

- [Architecture & Lifecycle](doc/architecture.md) — Agent loop, streaming events, agent hooks, loop detection, cancellation
- [LLM Providers & Configuration](doc/providers.md) — OpenAI, Gemini, Bedrock setup, ModelConfig, proxy support
- [Tools & Planning](doc/tools_and_planning.md) — Tool creation, parameter mapping, AgentToolResult, skills, sub-agents, planner
- [State & Memory Management](doc/state_and_memory.md) — AgentState, FileStateStorage, context compression, episodic memory
- [Evaluating Agents](doc/eval-guide.md) — Anthropic-aligned eval subsystem: tasks, graders, suites, pass@k / pass^k, record/replay, Langfuse export, cross-run health

---

## Contributing

Bug reports and pull requests are welcome. Please open an issue first for significant changes.

---

## About

`dart_agent_core` is developed by [Memex Lab](https://memexlab.ai). Visit our homepage for more projects and updates.
