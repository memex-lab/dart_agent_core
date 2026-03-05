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
