# AGENTS.md

This file provides guidance to Qoder (qoder.com) when working with code in this repository.

`dart_agent_core` is a mobile-first / local-first Dart library that implements a full agentic loop (tool use, streaming, state persistence, skills, sub-agents, planning, context compression, loop detection) plus an agent-evaluation subsystem. It targets Flutter/Dart apps with no Python or Node.js backend, and supports all 6 platforms including Web.

## Common Commands

```bash
dart pub get                      # install dependencies

dart analyze .                    # static analysis (whole package, matches pana/CI)
dart format .                     # format; pana fails the score if anything is unformatted

dart test                         # run all tests
dart test test/planner_test.dart  # run a single test file
dart test -n "substring"          # run tests whose name matches

# Regenerate mockito mocks (*.mocks.dart) after changing mocked classes
dart run build_runner build --delete-conflicting-outputs

# Pub-score / platform-tag review (web support, lints, formatting)
pana --no-warning .
```

Running examples and the eval demo (require provider credentials via env vars):

```bash
export OPENAI_API_KEY=sk-...
dart run example/simple_agent_example.dart

# Eval harness demo: --suite calculator|card_agent|pkm_agent|all, --mode live|record|replay
export OPENAI_BASE_URL=https://...
dart run example/eval_demo/main.dart --suite all --concurrency 4 --mode live

# Transcript viewer CLI (reads eval traces)
dart run bin/transcripts.dart
```

## Two Public Libraries

The package exposes **two separate entry points** — keep them decoupled:

- `lib/dart_agent_core.dart` — the agent runtime (clients, agent, tools, skills, state).
- `lib/eval.dart` — the evaluation subsystem (tasks, graders, suites, record/replay, metrics, reporting). It is intentionally a separate import so apps that don't run evals don't pay the import cost. **Do not** pull eval primitives into the main library.

## Architecture (big picture)

The orchestrator is [`StatefulAgent`](lib/src/agent/stateful_agent.dart) (~1600 lines). It owns an `AgentState` and runs a think-act-observe loop:

1. `runStream()` is the core; it yields `StreamingEvent`s. `run()` is a thin wrapper that collects `fullModelMessage` + `functionCallResult` events into a `List<LLMMessage>`.
2. Each turn: optionally compress context → compose system message + tool list (system prompts + active skills + planner/sub-agent/memory tools) → optional `systemCallback` → call `LLMClient` → if the model returned `FunctionCall`s, execute matching `Tool`s in parallel and loop; otherwise stop.
3. Stop conditions: no tool calls, a tool returning `stopFlag = true`, or an `AgentException` (loop detected / cancelled / blocked by controller).

Supporting subsystems (all under `lib/src/`):

- **LLM clients** — `core/llm_client.dart` defines the `LLMClient` abstraction; implementations live in `src/llm/` (`openai_client`, `responses_client`, `gemini_client`, `claude_client`, `bedrock_claude_client`). Bedrock uses AWS SigV4; others use API keys. All go through Dio.
- **Messages** — `core/message.dart` holds the multimodal message model (`UserMessage`, `ModelMessage`, content parts for text/image/audio/video/document).
- **Tools** — `core/tool.dart`. Two parameter modes: function mode (positional/named via `Function.apply`) and object mode (`Map<String,dynamic>`). Tools read session state via `AgentCallToolContext.current` without explicit params and may return `AgentToolResult`.
- **Control / events** — `agent/controller.dart`, `agent/events.dart`, `core/event_bus.dart`. `AgentController` offers pub/sub observation and request/response hooks (`Before*`/`After*`) that can approve or stop steps.
- **Skills** — `agent/skill.dart`. Two mutually-exclusive modes per agent: pure-Dart `Skill` objects (`skills:`) **or** filesystem `SKILL.md` discovery (`skillDirectoryPath:`). Filesystem skills can run JS via an injected `JavaScriptRuntime`.
- **Planner / sub-agents / memory** — `agent/planner.dart` (`write_todos`), `agent/sub_agent.dart` (`delegate_task`, `clone`), `agent/memory.dart` + `agent/context_compressor.dart` (episodic memory + `retrieve_memory`), `agent/loop_detector.dart`.
- **State** — `agent/state_storage.dart` defines the `StateStorage` interface; `agent/file_state_storage.dart` is the disk/in-memory implementation.
- **Eval** — `src/eval/` mirrors the Anthropic eval methodology: `core/` (tasks, suites, runner, transcripts), `graders/`, `llm/` (record/replay + rate limiting), `observability/` (JSONL + Langfuse exporters), `metrics/` (pass@k, pass^k), `suite_health/`, `calibration/`, `reporting/`, `loaders/` (JSON data-driven suites).

## Cross-platform / Web support (critical when touching `dart:io`)

The package supports Web. `dart:io` must **not** be reachable from either public library, or the Web platform tag breaks. The convention is a conditional-export triple:

```dart
// selector file X.dart
export 'X_web.dart' if (dart.library.io) 'X_io.dart';
```

Existing triples: `core/fs.dart` (+ `fs_io.dart`/`fs_stub.dart`), `core/http_util.dart`, `agent/file_state_storage.dart`, `agent/node_javascript_runtime.dart`. Shared filesystem access goes through the `fs*` helpers in `core/fs.dart` (native uses real `dart:io`; web stubs return not-found/empty or throw `UnsupportedError`). `agent/javascript_runtime.dart` holds only shared, platform-agnostic types and re-exports the node selector.

When adding filesystem/process/socket code: route it through `fs.dart`, or add a new selector + `_io` + `_web` triple. Never `import 'dart:io'` directly in a file reachable from `dart_agent_core.dart` or `eval.dart`. Network error handling relies on Dio (`DioException`) rather than `SocketException`/`HttpException`.

## Lint conventions

`analysis_options.yaml` uses `package:lints/recommended.yaml` with these rules disabled: `constant_identifier_names`, `non_constant_identifier_names`, `annotate_overrides`, `curly_braces_in_flow_control_structures`.
