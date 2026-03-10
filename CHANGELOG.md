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
