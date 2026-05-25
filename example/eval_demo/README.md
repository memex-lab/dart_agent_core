# eval_demo — calculator agent end-to-end demo

A minimal but full demo of the eval subsystem. One agent, one
suite, three tasks (positive · positive · negative), and a real LLM call
through any OpenAI-compatible endpoint.

## What it shows

- **Agent under test** (`agent.dart`): four arithmetic tools
  (`add` / `subtract` / `multiply` / `divide`) plus a structured
  submission protocol (`submit_answer` / `decline`). System prompt forces
  the agent to use tools instead of computing mentally and to decline
  off-topic prompts.
- **`EvalEnvironment`** (`environment.dart`): per-trial temp directory,
  optional record/replay wrapping for the LLM client.
- **`AgentHarnessFactory`** (`harness.dart`): subscribes to the
  `AgentController` event bus to assemble a `Transcript`
  (messages + tool calls + retries + exceptions + timing + tokens) and
  reads `answer.txt` / `declined.txt` from the workspace to produce an
  `Outcome`.
- **Tasks** (`tasks.dart`): three `EvalTask` implementations
  (single-step add, multi-step compose, off-topic decline) covering both
  Anthropic positive and negative cases. Each declares its own graders,
  reference solution, metadata, trials/run, and timeout.
- **Graders** (`graders.dart`): `AnswerCorrectnessGrader`,
  `ToolUsageGrader`, `DeclineGrader` — all `CodeGrader` subclasses that
  inspect the outcome and the transcript.
- **Runner glue** (`main.dart`): wires `EvalRunner` with a
  `JsonlTraceExporter`, a `FileReportStore`, a `RecordingStore`
  (when `--mode record|replay`), and an `RpmRateLimitGate` (when
  `--rpm` is set). Generates a Markdown report per run.

## Run it

```bash
# OpenAI-compatible endpoint (works with OpenAI, OpenRouter, …)
export OPENAI_BASE_URL='https://...'
export OPENAI_API_KEY='sk-...'

# Optional: pick a different model.
# export EVAL_MODEL='openai/gpt-5.4'

dart pub get
dart run example/eval_demo/main.dart \
  --run-name demo_run_1 \
  --concurrency 2 \
  --mode live
```

Output:

- `./.eval_reports/<run_name>.md` — Markdown summary.
- `./.eval_reports/reports/<run_name>.json` — full report (trials,
  scores, outcome).
- `./.eval_reports/index.jsonl` — append-only run index.
- `./.eval_traces/<run_name>.jsonl` — JSONL trace (one event per line).

The exit code reflects task pass rate: `0` if all tasks passed, `1`
otherwise.

## Modes

- `--mode live`   — call the real LLM, no recording.
- `--mode record` — call the real LLM and write recordings to
  `--recording-dir` (default `./.eval_recordings`).
- `--mode replay` — read recordings only; raises on a miss.

## Inspect transcripts

```bash
dart run bin/transcripts.dart list  --store .eval_reports
dart run bin/transcripts.dart show  --store .eval_reports \
  --trial demo_run_1/task_multi_step#0
dart run bin/transcripts.dart diff  --store .eval_reports \
  --task task_multi_step --runs demo_run_1,demo_run_2
dart run bin/transcripts.dart export --store .eval_reports \
  --run demo_run_1 --format markdown
```
