# LLM Provider 与配置

[English](providers.md) | [简体中文](providers.zh-CN.md)

`dart_agent_core` 通过统一的 `LLMClient` 接口屏蔽不同 LLM 提供商的差异。初始化所需客户端后传给 `StatefulAgent` 即可。

## 支持的 Provider

### OpenAI（Chat Completions）

使用 OpenAI Chat Completions API。默认 `baseUrl` 为 `https://api.openai.com`，库会再拼接 `/chat/completions` 作为最终端点。可覆盖 `baseUrl` 以接入 Azure OpenAI 或兼容代理。

```dart
final client = OpenAIClient(
  apiKey: Platform.environment['OPENAI_API_KEY'] ?? '',
  // Azure 示例：'https://YOUR_RESOURCE.openai.azure.com/openai/v1'
  // baseUrl: 'https://api.openai.com',
);
final config = ModelConfig(model: 'gpt-4o', temperature: 0.7);
```

额外构造参数：

| 参数 | 默认值 | 说明 |
|-----------|---------|-------------|
| `timeout` | 300s | 请求超时 |
| `connectTimeout` | 60s | 连接超时 |
| `proxyUrl` | null | HTTP 代理（支持 `http://user:pass@host:port`） |
| `maxRetries` | 3 | 瞬时错误重试次数 |
| `initialRetryDelayMs` | 1000 | 初始重试退避（毫秒） |
| `maxRetryDelayMs` | 10000 | 最大重试退避（毫秒） |

### OpenAI（Responses API）

使用较新的 OpenAI Responses API。`LLMClient` 接口（`generate` / `stream`）相同，但底层请求格式与 Chat Completions 不同。客户端会自动从 `ModelMessage` 提取 `responseId`，并在下次请求中作为 `previous_response_id` 传入，只发送上次响应之后的新消息。这能降低多轮对话的 Token 用量。

`ResponsesClient` 还提供 `checkResponseId(responseId)`，用于校验已保存的 response ID 在服务端是否仍然有效。

```dart
final client = ResponsesClient(
  apiKey: Platform.environment['OPENAI_API_KEY'] ?? '',
);
final config = ModelConfig(model: 'gpt-4o');
```

### Google Gemini

对接 Google Generative Language API。客户端会处理 Gemini 特有的格式（system instruction、content role、function call schema）。

```dart
final client = GeminiClient(
  apiKey: Platform.environment['GEMINI_API_KEY'] ?? '',
);
final config = ModelConfig(model: 'gemini-2.5-pro');
```

### Amazon Bedrock（Claude）

Bedrock 使用 AWS Signature V4 鉴权，而不是简单 API Key。客户端会根据 AWS 凭证自动计算签名。

```dart
final client = BedrockClaudeClient(
  region: 'us-east-1',
  accessKeyId: Platform.environment['AWS_ACCESS_KEY_ID'] ?? '',
  secretAccessKey: Platform.environment['AWS_SECRET_ACCESS_KEY'] ?? '',
  sessionToken: Platform.environment['AWS_SESSION_TOKEN'], // 可选，临时凭证
);
final config = ModelConfig(model: 'us.anthropic.claude-3-5-sonnet-20241022-v2:0');
```

---

## `ModelConfig`

`ModelConfig` 传给 `StatefulAgent`，并在每次调用时转发给 LLM 客户端。

```dart
final config = ModelConfig(
  model: 'gpt-4o-mini',
  temperature: 0.7,
  maxTokens: 4096,
  topP: 0.9,
  // topK: Gemini 支持
  // extra: Provider 特有参数（见下文）
  // generationConfig: Gemini 特有生成配置
);
```

### 通过 `extra` 传递 Provider 特有参数

`extra` map 会合并进请求体，用于传递 `ModelConfig` 没有独立字段的 Provider 特有参数。

**Claude Extended Thinking（Bedrock）：**

```dart
final config = ModelConfig(
  model: 'us.anthropic.claude-3-7-sonnet-20250219-v1:0',
  maxTokens: 16000,
  extra: {
    'thinking': {'type': 'enabled', 'budget_tokens': 10000},
  },
);
```

启用 thinking 后，模型推理过程可从 `(modelMessage).thought` 读取，校验签名在 `(modelMessage).thoughtSignature`。

**OpenAI reasoning 模型（o 系列）：**

```dart
final config = ModelConfig(
  model: 'o3-mini',
  extra: {'reasoning_effort': 'high'},
);
```

---

## 代理支持

所有客户端都支持通过 `proxyUrl` 配置 HTTP 代理，并支持 Basic Auth：

```dart
final client = OpenAIClient(
  apiKey: '...',
  proxyUrl: 'http://user:password@proxy.example.com:8080',
);
```

---

## OpenAI 兼容 Provider

许多 LLM 提供商暴露 OpenAI 兼容的 Chat Completions API。可以用带自定义 `baseUrl` 的 `OpenAIClient` 接入。

### Kimi（Moonshot AI）

```dart
final client = OpenAIClient(
  apiKey: Platform.environment['MOONSHOT_API_KEY'] ?? '',
  baseUrl: 'https://api.moonshot.cn/v1',
);
final config = ModelConfig(model: 'kimi-k2');
// thinking 模型：ModelConfig(model: 'kimi-k2-thinking')
// reasoning_content 会自动处理
```

### 通义千问（Qwen）

```dart
final client = OpenAIClient(
  apiKey: Platform.environment['DASHSCOPE_API_KEY'] ?? '',
  baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
);
final config = ModelConfig(model: 'qwen3.5-plus');
```

### 智谱 GLM

```dart
final client = OpenAIClient(
  apiKey: Platform.environment['GLM_API_KEY'] ?? '',
  baseUrl: 'https://open.bigmodel.cn/api/coding/paas/v4',
);
final config = ModelConfig(model: 'GLM-4.7');
```

### Ollama（本地部署）

```dart
final client = OpenAIClient(
  apiKey: '', // 不需要 API Key
  baseUrl: 'http://localhost:11434/v1',
);
final config = ModelConfig(model: 'qwen2.5:7b');
```

### OpenRouter

```dart
final client = OpenAIClient(
  apiKey: Platform.environment['OPENROUTER_API_KEY'] ?? '',
  baseUrl: 'https://openrouter.ai/api/v1',
);
final config = ModelConfig(model: 'anthropic/claude-opus-4.6');
```

---

## Responses API 兼容 Provider

### 火山引擎豆包（Doubao-Seed）

```dart
final client = ResponsesClient(
  apiKey: Platform.environment['ARK_API_KEY'] ?? '',
  baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
);
final config = ModelConfig(model: 'doubao-seed-1-8-251228');
```

---

## Anthropic API 兼容 Provider

### Anthropic Claude（直连）

```dart
final client = ClaudeClient(
  apiKey: Platform.environment['ANTHROPIC_API_KEY'] ?? '',
);
final config = ModelConfig(model: 'claude-sonnet-4-20250514');
```

### MiniMax

MiniMax 暴露 Anthropic 兼容 API 端点。

```dart
final client = ClaudeClient(
  apiKey: Platform.environment['MINIMAX_API_KEY'] ?? '',
  baseUrl: 'https://api.minimaxi.com/anthropic',
);
final config = ModelConfig(model: 'MiniMax-M2.5');
```

---

## Thinking / Reasoning 模型

支持 extended thinking 的模型（例如 `kimi-k2-thinking`、`o1`、`o3`、`deepseek-r1`）会在响应中返回 `reasoning_content`。框架会自动处理：

- 流式与非流式响应都会把 `reasoning_content` 解析到 `ModelMessage.thought`。
- 多轮对话会按 API 要求在 assistant 消息中回传 `reasoning_content`。
- 通过 `modelMessage.thought` 读取思考内容。
