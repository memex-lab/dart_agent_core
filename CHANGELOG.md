## 1.0.13

- Fix `EventBus`: ignore late events after `close()` to prevent errors when events are published during teardown.
- Add unit tests for `LoopDetector`, `Planner`, and `EventBus`.

## 1.0.12

- Add `EvalTranscriptRecorder`: automatically captures execution traces (messages, tool calls, reasoning steps, token/turn metrics) from `AgentController` during eval runs — harnesses no longer need to manually build transcripts.
- `EvalRunner` now integrates `EvalTranscriptRecorder` per trial, producing richer `Transcript` data with timing metrics (time-to-first-token, time-to-last-token).
- Simplify `AgentHarnessFactory` interface — harnesses focus on running the agent and returning `Outcome`, transcript recording is handled by the framework.
- Update eval guide docs and examples to reflect the new recorder-based workflow.

## 1.0.11

- Add evaluation subsystem under `package:dart_agent_core/eval.dart` (separate entry point — no impact on existing `dart_agent_core.dart` consumers).
  - Core: `EvalTask` / `EvalSuite` / `EvalRunner` / `Trial` / `Outcome` / `Transcript` / `EvalEnvironment` / `AgentHarnessFactory`.
  - Graders: `CodeGrader` (rule / script / classification), `ModelGrader` (LLM-as-judge with required `Unknown` escape hatch), `HumanGrader`.
  - LLM record / replay: hash-based `RecordingLLMClient` / `ReplayLLMClient`, `FileRecordingStore`, per-trial `cacheSalt` so `trialsPerRun > 1` does not collapse into a single cache entry.
  - Rate limiting: `RpmRateLimitGate`, `TpmRateLimitGate`, `NoopRateLimitGate` — decoupled from concurrency, replay hits skip the gate.
  - Metrics: `pass@k` (Codex unbiased estimator), `pass^k` (empirical), `ClassificationMetrics`, bucket pass rates, grader means.
  - Reporting: `FileReportStore`, `diffRunReports`, markdown + JSON output.
  - Suite health: `SuiteHealthAnalyzer` — graduation candidates and broken-task detection across runs.
  - Calibration: `JudgeCalibrator` — Spearman / Pearson / MAE against a human-labeled golden set.
  - Loaders: code-defined suites and JSON file-tree-defined suites via `loadEvalSuiteFromDir` + `GraderRegistry`.
  - Observability: `JsonlTraceExporter`, `CompositeTraceExporter`, and built-in `LangfuseTraceExporter` (background batched ingestion to Langfuse cloud or self-hosted, exponential-backoff retries, schema aligned with langfuse v4).
- Add `bin/transcripts.dart` CLI: `list` / `show` / `diff` / `export` for persisted run reports, runnable via `dart run dart_agent_core:transcripts`.
- Add three runnable end-to-end demos under `example/eval_demo/`: `calculator/` and `card_agent/` (code-defined suites), `pkm_agent/` (file-defined suite with fixtures); plus a 130-line self-contained `example/min_eval/main.dart`.
- Add `doc/eval-guide.md` (English) and `doc/eval-guide.zh-CN.md` covering core concepts, components, two suite definition styles, three grader styles, metrics, record/replay, Langfuse export, cross-run health, judge calibration, CLI, and an API cheat sheet. Linked from each README.

## 1.0.10

- Update README and documentation.

## 1.0.9

- **BREAKING**: Replace `SystemCallback` return type from Dart Record `(SystemMessage?, List<Tool>, List<LLMMessage>)` to `SystemCallbackResult` class for broader SDK compatibility and clearer semantics. Callers using `systemCallback` must update to access `.systemMessage`, `.tools`, `.requestMessages` properties instead of positional destructuring.

## 1.0.8

- Lower Dart SDK minimum constraint from `^3.10.4` to `^3.9.2` to support Flutter 3.35 and HarmonyOS ecosystem.
- Add `ToolParameterMode.object` for tools: receive all arguments as a single `Map<String, dynamic>` instead of positional/named parameter mapping via `Function.apply`.
- Update tool documentation in README, README.zh-CN, and `doc/tools_and_planning.md` with object mode usage and examples.

This library is part of the [Memex](https://www.memexlab.ai/changelog) project by [Memex Lab](https://memexlab.ai).

## 1.0.7

- Add `baseUrl` / `region` to request log messages across all LLM clients for easier debugging.
- Add comprehensive provider documentation for Chinese README (Kimi, Qwen, GLM, Doubao, MiniMax, Ollama, OpenRouter, Claude direct).
- Add OpenAI-compatible and Anthropic-compatible provider sections to `doc/providers.md`.
- Document thinking/reasoning model support (`reasoning_content` handling).
- Update examples list in both READMEs with all provider examples.
- Fix typo "Sendings" → "Sending" in `OpenAIClient` streaming log.
- Fix broken `docs/` links to `doc/` in Chinese README.

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
