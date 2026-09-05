# dart_agent_core Eval Guide

> A practical guide to evaluating Dart agents.

`dart_agent_core` ships a built-in evaluation subsystem aligned with
[Anthropic's "Demystifying evals for AI
agents"](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
methodology. It plays the same role as OpenAI Evals / Inspect AI /
DeepEval / Promptfoo, but Dart-first, local-first, with no external
dependencies.

- [Core concepts](#core-concepts)
- [Components in detail](#components-in-detail)
- [Quick start](#quick-start)
- [Two ways to define a suite](#two-ways-to-define-a-suite)
- [Three ways to grade](#three-ways-to-grade)
- [Trial, Outcome, and Transcript](#trial-outcome-and-transcript)
- [Metrics and reports](#metrics-and-reports)
- [Recording / replay / rate limiting](#recording--replay--rate-limiting)
- [Langfuse export](#langfuse-export)
- [Cross-run health](#cross-run-health)
- [Judge calibration](#judge-calibration)
- [CLI tools](#cli-tools)
- [Worked examples](#worked-examples)
- [API cheat sheet](#api-cheat-sheet)
- [References](#references)

</br>

## Core concepts

Strictly aligned with Anthropic's terminology:

| Concept | Type | Description |
|---|---|---|
| **Task** | `EvalTask` | One test case: an unambiguous input plus a success contract |
| **Trial** | `Trial` | One attempt at a task. Tasks are typically run multiple times to measure non-determinism |
| **Grader** | `Grader` | Scores one facet of a trial. A task may carry multiple graders |
| **Score** / **Assertion** | `Score` / `Assertion` | A grader's output: a 0–1 value plus sub-checks plus a rationale |
| **Transcript** | `Transcript` | Full record of one trial: messages, tool calls, reasoning, events, perf |
| **Outcome** | `Outcome` | The **environment state** at trial end (what changed, not what was said) |
| **Evaluation Harness** | `EvalRunner` | The end-to-end runner |
| **Agent Harness** | `AgentHarnessFactory` / `AgentHarnessSession` | The scaffolding that lets a model behave as an agent (you provide it) |
| **Evaluation Suite** | `EvalSuite` | A set of tasks targeting one capability or behavior |

Design principle (Anthropic Step 5): **grade the right evidence**. For
final-world-state questions, use the `Outcome` ("flight booked" should
be checked against the database, not against whether the agent said it
was booked). For process questions, use the `Transcript` (for example,
whether the agent read before writing or called a required tool).

</br>

## Components in detail

One eval run involves five roles:

```
EvalSuite
  └─ EvalTask × N
      └─ Trial × trialsPerRun
          ├─ EvalEnvironment.prepare → EvalContext (workspace / clock / llmClient / controller)
          ├─ AgentHarnessFactory.create → AgentHarnessSession
          │      ↓ session.run()
          │  ┌── Transcript: what the agent did (messages / tool calls / events / perf)
          │  └── Outcome:    what the environment ended up looking like
          ├─ Graders score independently → Score[]
          └─ EvalEnvironment.dispose
                  ↓
          EvalRunReport (pass@k / pass^k / per-grader means / bucket pass rates)
```

Below, each role gets its own section. **This section covers framework
contracts only**; for plugging a real `StatefulAgent` into the
machinery, see [Quick start](#quick-start).

### EvalTask — one test case

Interface (every field is required, no defaults):

```dart
abstract class EvalTask {
  String get id;                          // globally unique
  String get description;                 // one-line, human-facing
  Map<String, dynamic> get input;         // arbitrary JSON; the harness interprets it
  Map<String, String> get metadata;       // tags like failure_bucket
  ReferenceSolution? get referenceSolution; // optional known-good answer
  List<Grader> get graders;               // graders to run on each trial
  int get trialsPerRun;                   // ≥2 to measure pass^k meaningfully
  Duration? get timeout;                  // per-trial timeout
}
```

| Field | Notes |
|---|---|
| `id` | **A semantic change to a task = a new id** (e.g. `card_001` → `card_001_v2`). Don't rewrite an existing id; `SuiteHealthAnalyzer` aligns trials across runs by id, and reusing ids will pollute graduation / broken-task detection |
| `input` | Don't bake a prompt into `input` and feed it raw to the LLM. Let the harness translate `input` into messages so the same task can be reused across agents |
| `metadata['failure_bucket']` | The framework aggregates pass rate by this key — useful for spotting which failure mode dominates |
| `graders` | A task can carry multiple graders ("got the answer right" + "used the right tool"); each scores independently. A trial passes only if every grader passes |
| `trialsPerRun` | 2–5 for capability suites; usually 1 for regression. With `trialsPerRun=1`, pass^k degenerates into pass@1 and tells you nothing |

Tasks can also be defined as **JSON files** instead of Dart classes —
see [Two ways to define a suite](#two-ways-to-define-a-suite).

### EvalSuite — a set of tasks targeting one agent

```dart
EvalSuite(
  name: 'card_capability',
  agentName: 'card_agent',          // ← suite-scope: the agent under test
  kind: SuiteKind.capability,       // capability / regression / mixed
  tasks: [task1, task2, ...],
  requireReferenceSolution: false,  // when true, every task must declare one
  taskPassThreshold: 1.0,           // threshold used by taskPassRate
);
```

`agentName` lives on the **suite**, not on individual tasks — a task
set is not generally reused across different agents. This boundary
matches the Anthropic blog's framing.

`kind` decides what `taskPassRate` means:

| kind | A task passes when… | Use it for |
|---|---|---|
| `capability` | At least one trial passes | "Can the agent do this at all?" Tolerates occasional misses |
| `regression` | Every trial passes | "Is the agent stable?" One miss blocks the PR |
| `mixed` | Same as regression | Suites that haven't been split yet |

### EvalEnvironment — set up the "exam room"

```dart
abstract class EvalEnvironment {
  Future<EvalContext> prepare({required Trial trial, required EvalTask task});
  Future<void> dispose(EvalContext context);
}
```

The runner guarantees `prepare`/`dispose` are called once per trial —
so you can freely create a temp directory, spin up an in-memory DB,
seed test users, **wrap the LLM client**, and tear it all down on
`dispose`.

`EvalContext` is what `prepare` returns:

| Field | Description |
|---|---|
| `workspaceDir` | The trial's temp workspace root. Files written by the agent should land here so `dispose` can recursively delete them. Nullable |
| `clock` | Time source (`SystemEvalClock` / `FixedEvalClock`). Agents should call `ctx.clock.now()` rather than `DateTime.now()` so time can be locked |
| `llmClient` | The LLM client for this trial. May be a real client or a `RecordingLLMClient` / `ReplayLLMClient` wrapper. Each trial gets its own to keep record/replay clean |
| `controller` | An `AgentController` with trace exporters already attached. The harness should **reuse** this — never `new AgentController()` — or trace events won't reach the exporters |
| `servicesMap` | Where the application stashes its own services (`CardRepo`, `UserStorage`, in-memory DB). The harness reads them via `ctx.services<T>()`. The framework doesn't peek inside |
| `metadata` | Free-form metadata; flows into the transcript |

> **EvalEnvironment doesn't know what your agent looks like** — it
> only sets up resources. One Environment can serve multiple Harness
> implementations (different agent classes). This is the difference
> from Harness that newcomers most often miss.

### AgentHarnessFactory / AgentHarnessSession — turn a model into an agent

```dart
abstract class AgentHarnessFactory {
  Future<AgentHarnessSession> create({
    required EvalTask task, required Trial trial, required EvalContext context,
  });
}

abstract class AgentHarnessSession {
  Future<({Transcript transcript, Outcome outcome})> run();
  Future<void> dispose();
}
```

The harness is the **only** layer that knows what your agent looks
like: it instantiates `StatefulAgent`, registers `Tool[]`, calls
`agent.run([UserMessage(task.input['prompt'])])`, and once it returns,
collects the final `Outcome` from the workspace or application
services. The generic execution trace is recorded automatically by the
`EvalRunner`'s built-in `EvalTranscriptRecorder` through
`context.controller`; harnesses must reuse that controller.

`run()` must return **two** things. In the common case, the business
harness only needs to fill `Outcome`; it can return an empty
`Transcript`, and the runner will replace it with the recorder
snapshot:

- `Transcript` — what the agent **did**: message sequence, tool calls,
  retry / error events, turns / token counters. The framework records
  this by default; construct it manually only when you need to override
  or add custom trace data. Graders should use it whenever the score is
  about process, tool use, messages, events, or metrics.
- `Outcome` — what the environment **ended up like**.
  `environmentState` is an arbitrary map whose schema is a contract
  between you and your graders. Graders should use it whenever the
  score is about final state.

Common mistakes when populating `Outcome.environmentState`:

| ❌ Wrong (what the agent said) | ✅ Right (what the world became) |
|---|---|
| `{'agent_said': 'I booked the flight'}` | `{'flight_booked': true, 'flight_id': 'AA123'}` |
| `{'response': 'Logged to Areas/Health.md'}` | `{'updated_files': ['Areas/Health.md'], 'fact_id': 'fact_001'}` |
| `{'declined': "Sorry, I can't answer that"}` | `{'declined': true, 'submitted_answer': false}` |

#### Outcome is the harness's "facts table" for graders

A common newcomer question: **how does a grader know which files the
agent wrote and what's inside them? Does it spawn a tiny agent to
list directories?**

It doesn't. **Graders never read disk and never call an LLM to
discover environment state.** All disk scanning, directory walking,
and fact extraction happen at the end of the harness's `run()`. The
results land in `Outcome.environmentState` and `Outcome.workspaceDiff`
— that pre-summarized snapshot is what graders consume.

A real example from the PKM agent demo
(`example/eval_demo/pkm_agent/harness.dart`):

```dart
// Fact-collection code at the end of Harness.run()
Outcome _capturePkmOutcome(Directory ws) {
  // 1. Walk the workspace
  final created = <String>[];
  final snippets = <String, String>{};
  final pkmRoot = Directory('${ws.path}/PKM');
  if (pkmRoot.existsSync()) {
    for (final entry in pkmRoot.listSync(recursive: true)) {
      if (entry is! File) continue;
      final rel = entry.path.replaceFirst('${pkmRoot.path}/', '');
      created.add(rel);
      snippets[rel] = entry.readAsStringSync();
    }
  }

  // 2. Pull key facts (e.g. fact_id) out of file contents via regex
  final factIds = <String>{};
  snippets.forEach((_, body) {
    final m = RegExp(r'fact_id\s*:\s*(\S+)').firstMatch(body);
    if (m != null) factIds.add(m.group(1)!);
  });

  // 3. Check sentinel files (some tools leave side-effect markers)
  final skipped = File('${ws.path}/skipped.txt').existsSync();
  final insightsDir = Directory('${ws.path}/insights');
  final updatedInsight =
      insightsDir.existsSync() && insightsDir.listSync().whereType<File>().isNotEmpty;

  return Outcome(
    environmentState: {
      'wrote_files': created,
      'fact_ids_in_files': factIds.toList(),
      'updated_insight': updatedInsight,
      'skipped': skipped,
    },
    workspaceDiff: WorkspaceDiff(created: created, contentSnippets: snippets),
  );
}
```

The matching grader touches the filesystem zero times:

```dart
class PkmOrganizedGrader extends CodeGrader {
  @override Future<List<Assertion>> computeAssertions({...required Outcome outcome, ...}) async {
    final wrote = (outcome.environmentState['wrote_files'] as List).cast<String>();
    final factIds = (outcome.environmentState['fact_ids_in_files'] as List).cast<String>();
    return [
      Assertion(
        description: 'wrote into Areas/',
        passed: wrote.any((p) => p.startsWith('Areas/')),
        actual: '$wrote', expected: 'starts with Areas/',
      ),
      Assertion(
        description: 'fact_id appears in file body',
        passed: factIds.contains(expectedFactId),
        actual: '$factIds', expected: 'contains $expectedFactId',
      ),
    ];
  }
}
```

Why it's structured this way:

| If you let graders read disk… | …you get |
|---|---|
| Outcome stops being self-contained | Persisted reports can't be inspected offline without the original workspace |
| Multiple graders re-scan | A task with 3 graders walks the workspace 3 times |
| Graders care about schema, not paths | Every grader has to know "PKM lives under this subdir, with this filename convention" — agent-implementation details leaking into scoring logic |
| Cross-run diff and SuiteHealth break | `EvalRunReport` only stores the outcome, not the workspace |

Same applies to LLM judges: a judge typically reads a few text fields
from `outcome.environmentState` (or `workspaceDiff.contentSnippets`)
and folds them into the rubric prompt. **Judges don't spawn agents to
explore the workspace.**

> **Edge case**: occasionally a grader genuinely needs cross-file,
> tool-augmented reasoning (e.g. auditing the consistency of an
> entire codebase the agent produced). The framework doesn't stop
> you — `EvalContext` exposes `workspaceDir` / `llmClient` /
> `servicesMap`, so you can spin up a small agent inside the grader.
> But this is an anti-pattern. 99% of the time, **first ask: should
> this collection logic move to the harness?**

### Grader — score it

```dart
abstract class Grader {
  String get name;
  double get passThreshold;
  Future<Score> grade({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  });
}
```

There are three base classes by scoring style: `CodeGrader`
(deterministic), `ModelGrader` (LLM-as-judge), `HumanGrader` (queue
for human review). See [Three ways to grade](#three-ways-to-grade).

`Score` fields:

| Field | Description |
|---|---|
| `value` | Continuous 0..1 (supports partial credit). `null` means "couldn't decide" (e.g. an LLM judge returning Unknown) |
| `passed` | Whether `value` clears `passThreshold`. `null` when `value` is null |
| `assertions` | Sub-checks (`description` / `passed` / `actual` / `expected`) so a human can see which sub-criterion failed |
| `rationale` | **Required on failure**: a human-readable explanation. Anthropic Step 5 emphasizes "failures should seem fair" |
| `metadata` | Free-form: judge raw response, diff details, etc. |

### EvalRunner — run it

You don't implement this — just call `runSuite(...)`:

```dart
final report = await runner.runSuite(
  runName: 'pr-${prNumber}',         // identifies this run in the store / Langfuse
  suite: mySuite,
  concurrency: 4,                    // parallel trial count
  filter: TaskFilter(...),           // optional: only run a subset
);
```

Internally it:

1. Spawns workers up to `concurrency`. Each worker takes one (task, trial)
2. For each trial: `env.prepare()` → `harness.create().run()` → graders score → `env.dispose()`
3. Streams events to all `exporters` (jsonl / Langfuse / custom)
4. Computes pass@k / pass^k / per-grader means / bucket pass rates
5. Persists `EvalRunReport` to `reportStore` for later diff / SuiteHealthAnalyzer

`EvalRunMode` (parsed from `--mode` via `parseEvalRunArgs`):

- `live` — real LLM calls every time, burns tokens
- `record` — real LLM calls plus persisting requests/responses to a `RecordingStore`
- `replay` — no LLM calls; replays from the store. Misses are errors

In CI, regression suites typically run in `replay` (millisecond-fast,
zero cost), and capability suites run nightly in `live`.

</br>


## Quick start

```bash
dart pub add dart_agent_core
```

A minimal runnable example. Full source: [`example/min_eval/main.dart`](../example/min_eval/main.dart).
Set `OPENAI_API_KEY` / `OPENAI_BASE_URL` / `OPENAI_MODEL` and `dart run`:

```dart
import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';

// ─── 1. A minimal agent that uses one `echo` tool ────────────────────────
const _systemPrompt = '''
You echo what the user says back through the `echo` tool exactly once.
Then your turn ends. Do not produce any free-form text.
''';

List<Tool> _buildTools(Directory ws) => [
  Tool(
    name: 'echo',
    description: 'Echo the input text. Call this exactly once.',
    parameters: const {
      'type': 'object',
      'properties': {'text': {'type': 'string'}},
      'required': ['text'],
    },
    executable: (String text) async {
      File('${ws.path}/echo.txt').writeAsStringSync(text);
      return AgentToolResult(content: TextPart('echoed'), stopFlag: true);
    },
  ),
];

// ─── 2. EvalEnvironment: one fresh temp dir per trial ────────────────────
class EchoEnv implements EvalEnvironment {
  final OpenAIClient Function() clientFactory;
  EchoEnv(this.clientFactory);

  @override
  Future<EvalContext> prepare({required Trial trial, required EvalTask task}) async {
    final dir = await Directory.systemTemp.createTemp('echo_eval_');
    return EvalContext(
      workspaceDir: dir,
      clock: const SystemEvalClock(),
      llmClient: clientFactory(),
      controller: AgentController(),
    );
  }

  @override
  Future<void> dispose(EvalContext ctx) async {
    final d = ctx.workspaceDir;
    if (d != null && await d.exists()) await d.delete(recursive: true);
    ctx.controller.close();
  }
}

// ─── 3. AgentHarnessFactory: wrap a model into an agent that uses tools ──
class EchoHarness implements AgentHarnessFactory {
  final ModelConfig modelConfig;
  EchoHarness(this.modelConfig);

  @override
  Future<AgentHarnessSession> create({
    required EvalTask task,
    required Trial trial,
    required EvalContext context,
  }) async => _EchoSession(task: task, ctx: context, modelConfig: modelConfig);
}

class _EchoSession implements AgentHarnessSession {
  final EvalTask task;
  final EvalContext ctx;
  final ModelConfig modelConfig;
  _EchoSession({required this.task, required this.ctx, required this.modelConfig});

  @override
  Future<({Transcript transcript, Outcome outcome})> run() async {
    final agent = StatefulAgent(
      name: 'echo_agent',
      client: ctx.llmClient,
      modelConfig: modelConfig,
      state: AgentState(sessionId: '${task.id}'),
      tools: _buildTools(ctx.workspaceDir!),
      systemPrompts: [_systemPrompt],
      controller: ctx.controller,
      withGeneralPrinciples: false,
      planMode: PlanMode.none,
      disableSubAgents: true,
      autoSaveStateFunc: (_) async {},
    );
    await agent.run([
      UserMessage([TextPart(task.input['prompt'] as String)]),
    ], useStream: false);

    final f = File('${ctx.workspaceDir!.path}/echo.txt');
    final echoed = f.existsSync() ? f.readAsStringSync() : null;

    return (
      transcript: Transcript(
        messages: const [],
        toolCalls: const [],
        metrics: const TranscriptMetrics(nTurns: 0, nToolCalls: 0, nTotalTokens: 0),
      ),
      outcome: Outcome(environmentState: {'echoed': ?echoed}),
    );
  }

  @override
  Future<void> dispose() async {}
}

// ─── 4. Grader: echoed value matches the expected text ───────────────────
class _EchoMatchesGrader extends CodeGrader {
  final String expected;
  _EchoMatchesGrader(this.expected);
  @override String get name => 'echo_matches';
  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async => [
    Assertion(
      description: 'echoed text matches expected',
      passed: outcome.environmentState['echoed'] == expected,
      actual: '${outcome.environmentState['echoed']}',
      expected: expected,
    ),
  ];
}

// ─── 5. EvalTask + EvalSuite ─────────────────────────────────────────────
class _EchoTask implements EvalTask {
  @override String get id => 'echo_hi';
  @override String get description => 'agent must echo "hi" verbatim';
  @override Map<String, dynamic> get input => {'prompt': 'echo this back: hi'};
  @override Map<String, String> get metadata => const {};
  @override ReferenceSolution? get referenceSolution => null;
  @override List<Grader> get graders => [_EchoMatchesGrader('hi')];
  @override int get trialsPerRun => 2;
  @override Duration? get timeout => const Duration(minutes: 1);
}

// ─── 6. main: wire it together and run ───────────────────────────────────
Future<void> main() async {
  final env = Platform.environment;
  OpenAIClient client() => OpenAIClient(
    apiKey: env['OPENAI_API_KEY']!,
    baseUrl: env['OPENAI_BASE_URL'] ?? 'https://api.openai.com/v1',
  );

  final runner = EvalRunner(
    environment: EchoEnv(client),
    harnessFactory: EchoHarness(ModelConfig(model: env['OPENAI_MODEL'] ?? 'gpt-4o-mini')),
    exporters: [JsonlTraceExporter(File('.eval_traces/echo.jsonl'))],
    reportStore: FileReportStore(Directory('.eval_reports')),
  );

  final report = await runner.runSuite(
    runName: 'echo_${DateTime.now().millisecondsSinceEpoch}',
    suite: EvalSuite(
      name: 'echo_capability',
      agentName: 'echo_agent',
      kind: SuiteKind.capability,
      tasks: [_EchoTask()],
    ),
    concurrency: 2,
  );

  stdout.writeln(report.toMarkdownSummary());
  exit(report.taskPassRate >= 1.0 ? 0 : 1);
}
```

What you get:

- `.eval_reports/<run_name>.json` — full run report, loadable by the transcripts CLI
- `.eval_reports/index.jsonl` — cross-run index
- `.eval_traces/echo.jsonl` — OTel-style trace stream
- stdout — Markdown report (task / trial pass rate, pass@k, per-grader means)

For richer scenarios (multiple graders, file fixtures, multiple tasks,
record/replay, cross-run diff), see the three demos under
[`example/eval_demo/`](../example/eval_demo/) (`calculator/`,
`card_agent/`, `pkm_agent/`).

</br>

## Two ways to define a suite

`dart_agent_core` supports both **code-defined** and **file-defined**
suites. They can coexist.

### Option A — code-defined (`EvalSuite(...)` + `EvalTask` subclasses)

Best when the task count is small, you want strong type safety, and
you want refactors to follow renames. `example/eval_demo/calculator/`
and `example/eval_demo/card_agent/` follow this style.

```dart
class _SimpleAdditionTask implements EvalTask {
  @override String get id => 'task_simple_addition';
  @override String get description => 'Single-step addition';
  @override Map<String, dynamic> get input => {'prompt': 'What is 2 + 3?'};
  @override List<Grader> get graders => [
    AnswerCorrectnessGrader(expected: 5),
    ToolUsageGrader(minArithmeticCalls: 1),
  ];
  @override int get trialsPerRun => 2;
  @override Duration? get timeout => const Duration(minutes: 2);
}

EvalSuite buildSuite() => EvalSuite(
  name: 'calculator_demo',
  agentName: 'calculator_demo_agent',  // ← suite-scope: the agent under test
  kind: SuiteKind.mixed,
  tasks: [_SimpleAdditionTask(), ...],
  requireReferenceSolution: true,
);
```

### Option B — file-defined (directory layout + `loadEvalSuiteFromDir`)

Best when the task set keeps growing, when product / QA folks need to
PR new cases, or when cases need to be grouped by failure category.
`example/eval_demo/pkm_agent/suites/` follows this style.

Layout:

```
suites/
  pkm_capability/
    suite.json                    ← suite metadata
    tasks/                        ← one JSON per task
      positive/                   ← optional sub-folders for grouping
        pkm_area_health.json
        pkm_resource_reading.json
        pkm_append_to_existing.json
      negative/
        pkm_skip_trivial.json
```

`suite.json`:

```json
{
  "name": "pkm_agent_demo",
  "agent_name": "pkm_agent_demo",
  "kind": "mixed",
  "requireReferenceSolution": true,
  "taskPassThreshold": 1.0
}
```

A task file:

```json
{
  "id": "pkm_area_health",
  "description": "Long-term health habit: should write under Areas/.",
  "trials_per_run": 2,
  "timeout_seconds": 180,
  "metadata": {"failure_bucket": "route_to_areas"},
  "input": {"prompt": "..."},
  "reference_solution": {
    "expected_outcome": {"updated_insight": true, "skipped": false},
    "source": "manual"
  },
  "graders": [
    {"name": "pkm_organized",
     "config": {"fact_id": "fact_pkm_001",
                "buckets": ["Areas/"],
                "must_contain": ["mobility"]}}
  ]
}
```

Loading:

```dart
final reg = GraderRegistry()
  ..register('pkm_organized', (cfg) => PkmOrganizedGrader(
        expectedFactId: cfg['fact_id'] as String,
        expectedBuckets: (cfg['buckets'] as List).cast<String>(),
        mustContainSubstrings:
            (cfg['must_contain'] as List?)?.cast<String>() ?? const [],
      ))
  ..register('pkm_skipped', (_) => PkmSkippedGrader())
  ..register('read_before_write', (_) => PkmReadBeforeWriteGrader());

final suite = loadEvalSuiteFromDir(
  Directory('suites/pkm_capability'),
  graderRegistry: reg,
);
```

| Dimension | Code-defined | File-defined |
|---|---|---|
| Fast to write | ✅ IDE completion, type safety | 🔶 hand-written JSON |
| Scales to many cases | 🔶 single file gets bloated | ✅ one task per file, git-diff friendly |
| Non-engineers can contribute | ❌ Dart only | ✅ JSON only |
| Refactors propagate | ✅ rename a grader and the compiler tells you | 🔶 update the grader name in JSON manually |
| When to use | Demos, framework tests, type-sensitive scenarios | Business case banks, cross-team contribution |

> **Recommendation**: use code definitions during early iteration, then
> export to JSON once the case set stabilizes. Graders should always be
> code (typed, debuggable); task data can be either.

</br>


## Three ways to grade

Anthropic categorizes graders into three families; the framework
provides a base class for each.

### 1. Code-based (`CodeGrader`) — deterministic, fastest

Best for: exact string match, numeric comparison, file existence,
JSON schema validation, tool-call counting — anything decidable in
code.

```dart
class AnswerCorrectnessGrader extends CodeGrader {
  final num expected;
  final double tolerance;
  AnswerCorrectnessGrader({required this.expected, this.tolerance = 1e-9});

  @override String get name => 'answer_correctness';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final actual = (outcome.environmentState['answer'] as num?)?.toDouble();
    return [
      Assertion(
        description: 'answer == $expected within $tolerance',
        passed: actual != null
            && (actual - expected.toDouble()).abs() <= tolerance,
        actual: '$actual',
        expected: '$expected',
      ),
    ];
  }
}
```

`CodeGrader` aggregates the `Assertion` list into a `Score(value,
passed)`:

- `value = passed_assertions / total_assertions`
- `passed = value >= passThreshold`, default `passThreshold = 1.0` (all must pass)
- The rationale is auto-generated from failed assertions

### 2. Model-based (`ModelGrader` / LLM-as-judge) — flexible, handles subjective tasks

Best for: open-ended response relevance, style consistency, safety,
and other dimensions code can't decide cleanly.

```dart
class StyleJudgeGrader extends ModelGrader {
  @override final LLMClient judgeClient;
  @override final String rubric;
  final ModelConfig modelConfig;
  @override final String name = 'style_quality';

  StyleJudgeGrader({
    required this.judgeClient,
    required this.rubric,
    required this.modelConfig,
  });

  @override double get passThreshold => 0.7;

  @override
  Future<Score> grade({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final prompt = '$rubric\n\nOutput: ${outcome.environmentState["text"]}\n'
        'Reply on a single line: "SCORE=<float 0-1>" or "SCORE=Unknown".';
    final reply = await judgeClient.generate(
      [UserMessage.text(prompt)],
      modelConfig: modelConfig,
    );
    final text = reply.textOutput?.trim() ?? '';
    final m = RegExp(r'SCORE=(Unknown|[\d.]+)').firstMatch(text);

    // Unknown escape hatch: when the judge can't decide, return null
    // rather than fabricating a score
    if (m == null || m.group(1) == 'Unknown') {
      return Score(
        graderName: name,
        value: null,
        passed: null,
        rationale: 'judge returned Unknown: $text',
      );
    }

    final v = double.parse(m.group(1)!).clamp(0.0, 1.0);
    return Score(
      graderName: name,
      value: v,
      passed: v >= passThreshold,
      rationale: 'judge=$v, raw="$text"',
    );
  }
}
```

**Anthropic Step 5 key point**: rubrics must always offer an
`Unknown` escape hatch. When the judge can't decide, return
`Score(value: null, passed: null)` rather than fabricating a number.
Null scores are excluded from grader means but tracked separately.

### 3. Human-based (`HumanGrader` + `HumanReviewQueue`) — gold standard, slowest

`HumanGrader` pushes trials onto a `HumanReviewQueue` (interface
implemented by you — wire it to a Langfuse Annotation Queue, your own
web UI, a Slack flow, whatever):

```dart
abstract class HumanReviewQueue {
  Future<void> enqueue({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    String? rubric,
    Map<String, dynamic> metadata,
  });
  Future<Score?> fetchVerdict(Trial trial);
}
```

The first `grade` call enqueues the trial and returns a pending null
score; once a reviewer scores it, a subsequent run picks up the
verdict. The primary use is **calibrating an LLM judge** (see [Judge
calibration](#judge-calibration)) — not scoring every run.

</br>

## Trial, Outcome, and Transcript

A trial produces a `TrialResult`:

```dart
class TrialResult {
  final Trial trial;            // run / suite / task / index / status / timestamps
  final Transcript transcript;  // messages + tool calls + events + perf
  final Outcome outcome;        // final environment state
  final List<Score> scores;     // per-grader output
}
```

### Transcript ("what the agent did")

```dart
class Transcript {
  final List<LLMMessage> messages;
  final List<ToolCallRecord> toolCalls;
  final List<String> reasoningSteps;
  final List<TranscriptEvent> events;       // retry / exception / custom
  final TranscriptMetrics metrics;          // turns / tokens / TTFT / TTLT
}
```

### Outcome ("what the environment ended up like")

```dart
class Outcome {
  final Map<String, dynamic> environmentState;  // app-defined schema
  final WorkspaceDiff? workspaceDiff;           // per-file diff
}
```

**Anthropic Step 5 hammers this point**: each grader evaluates the part
of the trial that contains the evidence it needs. Outcome graders check
final state; transcript graders check behavior over time, tool calls,
messages, reasoning/events, and performance metrics.

</br>

## Metrics and reports

`EvalRunReport` computes every metric Anthropic recommends.

### Pass-rate (semantics depend on suite kind)

- `trialPassRate` — passed trials / total trials
- `taskPassRate` —
  - `SuiteKind.capability`: a task counts as passed if at least one trial passes
  - `SuiteKind.regression`: a task counts as passed only if every trial passes
  - `SuiteKind.mixed`: same as regression

### pass@k (Codex unbiased estimator)

`pass@k = 1 − C(n−c, k) / C(n, k)`. The probability of at least one
success in k attempts. (`n` = total trials, `c` = passing trials.)

### pass^k (empirical estimator)

`pass^k = (c/n)^k`. The probability of all k attempts succeeding.
Anthropic recommends targeting **pass@1 close to 100% and as large a
k as possible for pass^k** — the latter measures sustained
reliability.

```dart
final passAt = report.passAtKByTask(ks: [1, 3, 5]);
final passCk = report.passCaretKByTask(ks: [1, 3, 5]);
```

### Bucket grouping

Group tasks by `metadata['failure_bucket']` to see which failure mode
dominates:

```dart
final byBucket = report.bucketPassRates({
  for (final t in suite.tasks)
    if (t.metadata['failure_bucket'] != null)
      t.id: t.metadata['failure_bucket']!,
});
// {tool_use: 0.92, intent_routing: 0.65, …}
```

### Classification metrics (`ClassificationMetrics`)

For binary tasks (should the Memory Agent write a memory? should the
Schedule Router refresh?), compute P / R / F1 directly:

```dart
const m = ClassificationMetrics(
  truePositives: 6, falsePositives: 2,
  trueNegatives: 8, falseNegatives: 4,
);
print(m.precision); // 0.75
print(m.recall);    // 0.6
print(m.f1);        // 0.6667
```

### Markdown reports + diff

```dart
// Single-run report
final md = report.toMarkdownSummary(taskBucketMap: {...});
File('report.md').writeAsStringSync(md);

// Cross-run diff (handy as a PR comment)
final baseline = await store.load('main');
final diff = report.diffWith(baseline!);
File('diff.md').writeAsStringSync(diff.toMarkdown());
```

</br>


## Recording / replay / rate limiting

Hitting the real LLM on every eval run is slow, expensive, and
flaky in CI. The framework provides two layers of infrastructure:
**deterministic replay** and **rate limiting**.

### Recording / replay

```dart
// First run: record
final store = FileRecordingStore(Directory('.eval_recordings'));
final llm = RecordingLLMClient(
  inner: OpenAIClient(...),
  store: store,
);

// Later in CI: replay (cache hit returns the recording, miss errors out)
final replay = ReplayLLMClient(
  store: FileRecordingStore(Directory('.eval_recordings')),
  strictReplay: true,  // CI must be strict
);
```

Request hashing is done by `Sha256LLMRequestHash` (default):

- Includes `messages` / `tools` / `modelConfig` / `jsonOutput` / `toolChoice` / `trialSalt`
- Use `stripMessageKeys` to ignore volatile fields (`timestamp`, etc.)
- Changing the prompt or tools → hash changes → cache misses → CI surfaces it as a re-record signal

#### Per-trial non-determinism — `trialSalt`

When `trialsPerRun > 1`, every trial of a given task sends a literally
identical request (same prompt, same tools, same model). If the hash
keyed off request content alone, N trials would collapse into one
cache entry, and **pass^k / pass@k would no longer measure model
non-determinism — they'd measure the cached replay**. That violates
Anthropic Step 6.

The framework's solution: per-trial salt mixed into the hash. Inside
`EvalEnvironment.prepare()`, take `trial.cacheSalt` (formatted as
`taskId#trialIndex`, **without** runName so recordings made in one
run can replay across runs) and pass it to `RecordingLLMClient` /
`ReplayLLMClient`'s `trialSalt` parameter. N trials become N
independent cache entries — record once, replay each one
independently.

```dart
// Inside EvalEnvironment.prepare:
final salt = trial.cacheSalt;
final llmClient = RecordingLLMClient(
  inner: liveClientFactory(),
  store: store,
  trialSalt: salt,           // ← key
);
// Or shorter: base.withTrialSalt(salt)
```

`trialSalt: null` (omitted) means cache is shared across all trials.
This is intentional — it's there for "logically the same call" cases
like a judge or ad-hoc analysis. It is **not** what you want for the
agent's main calls. All three built-in demos (calculator / card /
pkm) wire this correctly.

### Rate limiting

```dart
final gate = RpmRateLimitGate(requestsPerMinute: 120);
// Or token-based
final gate = TpmRateLimitGate(tokensPerMinute: 60000);

final llm = RecordingLLMClient(
  inner: ...,
  store: ...,
  rateLimitGate: gate,
);
```

`acquire()` blocks before a real LLM call. Replay hits **don't**
trigger rate limiting (they're local). This decouples concurrency
from rate limits: turn `concurrency` up to saturate CPU/IO, leave
the throughput cap to the gate.

</br>

## Langfuse export

Streaming every trial to [Langfuse](https://langfuse.com/) is built
in. Langfuse is the most popular open-source LLM observability
backend right now, with trace-tree views, filtering by user / session
/ tag, in-product scoring, prompt diffing, etc.

```dart
import 'package:dart_agent_core/eval.dart';

final exporter = LangfuseTraceExporter(LangfuseConfig.fromEnv());
// Or pass config explicitly:
//   LangfuseConfig(
//     host: 'https://cloud.langfuse.com',  // self-hosted? change this
//     publicKey: 'pk-...',
//     secretKey: 'sk-...',
//     environment: 'staging',
//   );

final runner = EvalRunner(
  environment: env,
  harnessFactory: harness,
  exporters: [
    JsonlTraceExporter(File('.eval_traces/run.jsonl')),
    exporter,           // local jsonl + Langfuse at the same time
  ],
  reportStore: FileReportStore(Directory('.eval_reports')),
);
```

Mapping:

| dart_agent_core | Langfuse |
|---|---|
| One `Trial` | One trace (`name = suite/task#trialIndex`, `userId = runName`, `sessionId = suiteName`) |
| Each LLM call | A `generation-create` observation (with `model` / `modelParameters` / `input` / `output` / `usage`) |
| Each tool call | A `span-create` observation (with `arguments` / `result`) |
| Each `Score` | A `score-create` (`dataType=NUMERIC`, `comment=rationale`, plus `assertions` / `metadata`) |
| `onRunEnd` aggregates | A `run-summary` trace plus one `score-create` per metric |

Implementation details:

- All HTTP runs in a background batched queue: defaults flush at 50
  events or every 1 second, so the eval run is barely affected
- HTTP 5xx triggers exponential-backoff retries (default 3); 4xx
  fails fast without retry
- Network blips / Langfuse downtime drop **at most a few events** —
  they never tank the eval run
- `dispose()` force-flushes anything still queued

Environment variables read by `LangfuseConfig.fromEnv`:

```bash
export LANGFUSE_PUBLIC_KEY='pk-...'
export LANGFUSE_SECRET_KEY='sk-...'
export LANGFUSE_HOST='https://cloud.langfuse.com'  # optional, defaults to cloud
export LANGFUSE_ENVIRONMENT='staging'              # optional, dashboard-side bucketing
```

</br>

## Cross-run health

`SuiteHealthAnalyzer` runs two checks across multiple eval runs
(Anthropic Step 7):

### Graduation

A task that has stayed at ≥ 95% pass rate for N consecutive runs is a
graduation candidate — move it from a capability suite to a
regression suite, and replace it in the capability suite with
something harder.

### Broken task

A task at ≤ 0% pass rate across multiple runs is **usually a
task-definition / grader-config bug**, not the agent failing the
behavior.

```dart
final analyzer = SuiteHealthAnalyzer(reportStore);
final health = await analyzer.analyze(
  suiteName: 'card_agent_capability',
  recentRunCount: 10,
);

for (final c in health.graduationCandidates) {
  print('graduate ${c.taskId}: '
        '${c.consecutiveMatureRuns} mature runs');
}
for (final c in health.brokenTaskCandidates) {
  print('broken task: ${c.taskId} '
        '${c.passedTrials}/${c.totalTrials}');
}
```

</br>

## Judge calibration

LLM judges are themselves non-deterministic and **must be calibrated
against human ground truth before going live** (Anthropic Step 5
threshold: Spearman ≥ 0.7).

```dart
final calibrator = JudgeCalibrator();
final report = await calibrator.calibrate(
  goldenSet: humanLabeledTrials,
  judgeScorer: (labeled) async {
    final r = await myLLMJudge.grade(labeled.input, labeled.output);
    return JudgeScore(value: r.score, rationale: r.reasoning);
  },
);

if (!report.meetsAnthropicBar) {
  throw StateError(
    'Judge correlation ${report.spearmanCorrelation.toStringAsFixed(2)} '
    'below 0.7. Top disagreements:\n${report.disagreements.take(5)}',
  );
}
```

Output: Spearman / Pearson correlation, agreement rate, MAE, and a
disagreement list sorted by |Δ| (the trials where judge and human
diverged most).

</br>

## CLI tools

```bash
# List all runs (newest first)
dart run dart_agent_core:transcripts list --store .eval_reports

# Inspect one trial
dart run dart_agent_core:transcripts show \
  --store .eval_reports \
  --trial pr-123/card_001#0

# Compare the same task across two runs
dart run dart_agent_core:transcripts diff \
  --store .eval_reports \
  --task card_001 --runs main,pr-123

# Export a whole run as Markdown
dart run dart_agent_core:transcripts export \
  --store .eval_reports --run pr-123 --format markdown
```

</br>

## Worked examples

There are three end-to-end runnable demos under `example/eval_demo/`:

| Demo | Suite definition | What it shows |
|---|---|---|
| `calculator/` | code | Basic `CodeGrader` + tool-call tracing + decline path |
| `card_agent/` | code | Multi-grader composition + template choice + substring containment |
| `pkm_agent/` | **file** | `loadEvalSuiteFromDir` + `GraderRegistry` + fixture files + read-before-write path check |

Run them:

```bash
export OPENAI_BASE_URL='https://...'
export OPENAI_API_KEY='sk-...'

dart run example/eval_demo/main.dart --suite calculator
dart run example/eval_demo/main.dart --suite card_agent
dart run example/eval_demo/main.dart --suite pkm_agent
dart run example/eval_demo/main.dart --suite all --concurrency 6
```

Outputs land in `.eval_reports/` and `.eval_traces/`; with
`--mode record|replay`, also `.eval_recordings/`.

</br>

## API cheat sheet

```dart
import 'package:dart_agent_core/eval.dart';
```

### Core data types

| Type | Purpose |
|---|---|
| `EvalTask` | Task interface; implement directly or use `JsonEvalTask` |
| `EvalSuite` | Task list + kind + thresholds |
| `Trial` / `TrialId` / `TrialStatus` | One attempt's metadata |
| `Transcript` / `ToolCallRecord` / `TranscriptMetrics` | "What the agent did" |
| `Outcome` / `WorkspaceDiff` | "Final environment state" |
| `TrialResult` | All of the above bundled |
| `ReferenceSolution` | Anthropic Step 2 known-good answer |

### Grader system

| Type | Purpose |
|---|---|
| `Grader` | Base class |
| `CodeGrader` | Code / deterministic scorer base |
| `ModelGrader` | LLM-as-judge base |
| `HumanGrader` / `HumanReviewQueue` | Human review |
| `Score` / `Assertion` / `GraderKind` | Score output |
| `GraderRegistry` | Register grader names for file-defined suites |

### Runner & context

| Type | Purpose |
|---|---|
| `EvalRunner` | Suite-runner entry point |
| `EvalRunConfig` / `parseEvalRunArgs` | CLI parsing (run name / concurrency / mode / filter / rpm / tpm / recording-dir) |
| `EvalRunMode` | `live` / `record` / `replay` |
| `TaskFilter` | Filter by agent / bucket / id |
| `EvalEnvironment` | Set up / tear down a trial |
| `EvalContext` / `EvalClock` | One trial's context: workspace + clock + LLM client + controller |
| `AgentHarnessFactory` / `AgentHarnessSession` | Agent-scaffolding interface (you implement) |
| `EvalRunReport` | Aggregated report + saturationStatus |

### Recording / replay / rate limiting

| Type | Purpose |
|---|---|
| `LLMRequestHash` / `Sha256LLMRequestHash` | Request hashing |
| `RecordingStore` / `InMemoryRecordingStore` / `FileRecordingStore` | Recording stores |
| `RecordingLLMClient` / `ReplayLLMClient` / `RecordingNotFoundException` | Record / replay wrappers |
| `RateLimitGate` / `RpmRateLimitGate` / `TpmRateLimitGate` / `NoopRateLimitGate` | Rate limits |

### Observability / reporting

| Type | Purpose |
|---|---|
| `TraceExporter` / `JsonlTraceExporter` / `CompositeTraceExporter` | Stream trial events |
| `LangfuseConfig` / `LangfuseClient` / `LangfuseTraceExporter` | Langfuse export (trace / generation / span / score) |
| `runTranscriptViewer` / `transcriptViewerUsage` | CLI entry points |
| `ReportStore` / `FileReportStore` | Persist run reports |
| `PersistedRunReport` / `SuiteSnapshot` / `RunIndexEntry` | Persistence models |
| `generateMarkdownReport` / `EvalRunReportReporting` | Markdown rendering |
| `diffRunReports` / `EvalRunReportDiff` / `EvalRunDiff` / `TaskTransition` | Cross-run diff |

### Metrics / health / calibration

| Type / function | Purpose |
|---|---|
| `passAtK` / `passCaretK` | Codex unbiased / empirical estimators |
| `ClassificationMetrics` | P / R / F1 / accuracy |
| `SaturationStatus` / `SaturationThresholds` / `GraduationCandidate` / `BrokenTaskCandidate` | Saturation |
| `SuiteHealthAnalyzer` / `SuiteHealthReport` | Cross-run health |
| `JudgeCalibrator` / `CalibrationReport` / `HumanLabeledTrial` / `TrialDisagreement` | Judge calibration |

### File loading

| Type / function | Purpose |
|---|---|
| `loadEvalSuiteFromDir` | Load a suite from a directory |
| `JsonEvalTask` | Data-driven task |
| `GraderRegistry` / `GraderFactoryFunction` | Map grader names → factories |

</br>

## References

- [Anthropic Engineering — Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
