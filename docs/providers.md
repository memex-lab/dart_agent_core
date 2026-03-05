# LLM Providers & Configuration

`dart_agent_core` abstracts differences between LLM providers behind a single `LLMClient` interface. Initialize the client you need and pass it to `StatefulAgent`.

## Supported Providers

### OpenAI (Chat Completions)

Uses the OpenAI Chat Completions API. The default `baseUrl` is `https://api.openai.com`, and the library appends `/chat/completions` to form the final endpoint. Override `baseUrl` for Azure OpenAI or compatible proxies.

```dart
final client = OpenAIClient(
  apiKey: Platform.environment['OPENAI_API_KEY'] ?? '',
  // Override for Azure: 'https://YOUR_RESOURCE.openai.azure.com/openai/v1'
  // baseUrl: 'https://api.openai.com',
);
final config = ModelConfig(model: 'gpt-4o', temperature: 0.7);
```

Additional constructor parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `timeout` | 300s | Request timeout |
| `connectTimeout` | 60s | Connection timeout |
| `proxyUrl` | null | HTTP proxy (supports `http://user:pass@host:port`) |
| `maxRetries` | 3 | Retry count on transient errors |
| `initialRetryDelayMs` | 1000 | Initial retry backoff (ms) |
| `maxRetryDelayMs` | 10000 | Maximum retry backoff (ms) |

### OpenAI (Responses API)

Uses the newer OpenAI Responses API. The `LLMClient` interface (`generate` / `stream`) is the same, but the underlying request format differs from Chat Completions. The client automatically extracts `responseId` from `ModelMessage` and passes it as `previous_response_id` on the next request, sending only the new messages after the last response. This reduces token usage in multi-turn conversations.

`ResponsesClient` also provides a `checkResponseId(responseId)` method to verify whether a stored response ID is still valid on the server.

```dart
final client = ResponsesClient(
  apiKey: Platform.environment['OPENAI_API_KEY'] ?? '',
);
final config = ModelConfig(model: 'gpt-4o');
```

### Google Gemini

Integrates with the Google Generative Language API. The client handles Gemini-specific formatting (system instructions, content roles, function call schemas).

```dart
final client = GeminiClient(
  apiKey: Platform.environment['GEMINI_API_KEY'] ?? '',
);
final config = ModelConfig(model: 'gemini-2.5-pro');
```

### Amazon Bedrock (Claude)

Bedrock uses AWS Signature V4 for authentication rather than a simple API key. The client computes the signature automatically from your AWS credentials.

```dart
final client = BedrockClaudeClient(
  region: 'us-east-1',
  accessKeyId: Platform.environment['AWS_ACCESS_KEY_ID'] ?? '',
  secretAccessKey: Platform.environment['AWS_SECRET_ACCESS_KEY'] ?? '',
  sessionToken: Platform.environment['AWS_SESSION_TOKEN'], // optional, for temporary credentials
);
final config = ModelConfig(model: 'us.anthropic.claude-3-5-sonnet-20241022-v2:0');
```

---

## `ModelConfig`

`ModelConfig` is passed to `StatefulAgent` and forwarded to the LLM client on every call.

```dart
final config = ModelConfig(
  model: 'gpt-4o-mini',
  temperature: 0.7,
  maxTokens: 4096,
  topP: 0.9,
  // topK: supported by Gemini
  // extra: provider-specific parameters (see below)
  // generationConfig: Gemini-specific generation config
);
```

### Provider-specific parameters via `extra`

The `extra` map is merged into the request body, allowing you to pass any provider-specific field that `ModelConfig` doesn't have a dedicated parameter for.

**Claude Extended Thinking (Bedrock):**

```dart
final config = ModelConfig(
  model: 'us.anthropic.claude-3-7-sonnet-20250219-v1:0',
  maxTokens: 16000,
  extra: {
    'thinking': {'type': 'enabled', 'budget_tokens': 10000},
  },
);
```

When thinking is enabled, the model's reasoning process is available in `(modelMessage).thought` and the verification signature in `(modelMessage).thoughtSignature`.

**OpenAI reasoning models (o-series):**

```dart
final config = ModelConfig(
  model: 'o3-mini',
  extra: {'reasoning_effort': 'high'},
);
```

---

## Proxy Support

All clients support HTTP proxies via the `proxyUrl` parameter. Basic auth is supported:

```dart
final client = OpenAIClient(
  apiKey: '...',
  proxyUrl: 'http://user:password@proxy.example.com:8080',
);
```
