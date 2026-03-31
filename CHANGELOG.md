## 1.0.6

- Fix `OpenAIClient` not handling `reasoning_content` for thinking/reasoning models (e.g. `kimi-k2-thinking`, `o1`, `deepseek-r1`).
- Parse `reasoning_content` from both non-streaming and streaming responses into `ModelMessage.thought`.
- Re-send `reasoning_content` in assistant messages during multi-turn conversations to satisfy API validation.
- Add `simple_agent_with_kimi_vision_example.dart` for image analysis with Kimi.

## 1.0.5

- Add examples for MiniMax, Kimi, Volcengine Seed, Zhipu GLM, and Qwen via OpenAI-compatible API.
- Fix `OpenAIResponseTransformer` not extracting `finish_reason` when provider sends it in the same chunk as `usage` (e.g. GLM).
- Fix double JSON encoding of `FunctionCall.arguments` in `OpenAIClient` and `ResponsesClient` request body.

## 1.0.4

- Add `DirectorySkill` support: load skills from `SKILL.md` files in a directory tree with automatic discovery and system prompt injection.
- Add `JavaScriptRuntime` and `NodeJavaScriptRuntime` for executing JavaScript scripts with bidirectional Dart↔JS bridge communication.
- Integrate directory skills and JavaScript execution into `StatefulAgent`.
- Add `simple_agent_with_directory_skills_example.dart` example.
- Update README documentation.

## 1.0.3

- Add `maxTurns` protection to `StatefulAgent` to prevent potential infinite loops.
- Add internal retry limit for empty model responses/stop reasons in `runStream`.

## 1.0.2

- Add standard entry-point `example/main.dart` to fix pub.dev example discovery.
- Add comprehensive API documentation comments (`///`) to core library members.
- Fix library-level documentation in `lib/dart_agent_core.dart`.

## 1.0.1

- Add `ClaudeClient` for direct Anthropic Messages API support (no AWS Bedrock required).
- Add examples for Ollama and OpenRouter usage via `OpenAIClient`.
- Add Claude example with `ClaudeClient`.
- Rename `docs/` to `doc/` and `examples/` to `example/` to follow pub.dev conventions.

## 1.0.0

- Initial release.
- Multi-provider LLM support: OpenAI (Chat Completions & Responses API), Google Gemini, AWS Bedrock (Claude).
- StatefulAgent with autonomous tool-calling loop.
- Multimodal message support (text, image, audio, video, document).
- Streaming via `runStream()` with fine-grained `StreamingEvent`s.
- Dynamic Skill system with runtime activation/deactivation.
- Sub-agent delegation with `clone` and named sub-agents.
- Planning via `write_todos` tool with `PlanMode`.
- Context compression with `LLMBasedContextCompressor` and episodic memory.
- Loop detection (tool signature tracking + LLM-based diagnosis).
- AgentController with Pub/Sub and Request/Response lifecycle hooks.
- `systemCallback` for per-call request modification.
- FileStateStorage for JSON-based state persistence.
