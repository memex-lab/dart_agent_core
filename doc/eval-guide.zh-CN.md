# dart_agent_core Eval Guide

> 给 Dart Agent 加评估的实操指南。

`dart_agent_core` 内置了一套基于 [Anthropic "Demystifying evals for AI
agents"](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
方法论的评估子系统。它和 OpenAI Evals / Inspect AI / DeepEval / Promptfoo
对应同一类工具，但是 Dart-first、本地优先、零外部依赖。

- [核心概念](#核心概念)
- [组件细节](#组件细节)
- [快速上手](#快速上手)
- [两种 suite 定义方式](#两种-suite-定义方式)
- [三种评分方式](#三种评分方式)
- [Trial、Outcome 和 Transcript](#trialoutcome-和-transcript)
- [指标与报告](#指标与报告)
- [录制 / 回放 / 限流](#录制--回放--限流)
- [跨 run 健康度](#跨-run-健康度)
- [Judge 校准](#judge-校准)
- [CLI 工具](#cli-工具)
- [完整示例](#完整示例)
- [API 速查表](#api-速查表)
- [设计参考](#设计参考)

</br>

## 核心概念

严格对齐 Anthropic 博客术语：

| 概念 | 类型 | 说明 |
|---|---|---|
| **Task** | `EvalTask` | 一个测试用例：明确的输入和成功标准 |
| **Trial** | `Trial` | 一次任务尝试。同一个 task 通常跑多次以观察非确定性 |
| **Grader** | `Grader` | 给某个 trial 的某一面打分（一个 task 可挂多个 grader） |
| **Score** / **Assertion** | `Score` / `Assertion` | grader 的输出，含 0–1 数值 + 子检查 + 解释 |
| **Transcript** | `Transcript` | 一次 trial 的完整运行记录：消息、工具调用、思考、事件、性能指标 |
| **Outcome** | `Outcome` | trial 结束时**环境状态**（不是它说了啥，是它做了啥） |
| **Evaluation Harness** | `EvalRunner` | 端到端跑评估的基础设施 |
| **Agent Harness** | `AgentHarnessFactory` / `AgentHarnessSession` | 让模型像 Agent 一样行动的脚手架（你提供） |
| **Evaluation Suite** | `EvalSuite` | 一组围绕同一能力/行为的 task |

设计原则（Anthropic Step 5）：**按指标选择正确证据**。终态问题看
`Outcome`（例如 "flight booked" 应当看数据库里有没有航班记录，而不是
Agent 是否说了 "Your flight has been booked"）；过程问题看
`Transcript`（例如是否先读后写、是否调用了必需工具）。

</br>

## 组件细节

跑一次评估涉及 5 个角色：

```
EvalSuite
  └─ EvalTask × N
      └─ Trial × trialsPerRun
          ├─ EvalEnvironment.prepare → EvalContext（工作区/clock/llmClient/controller）
          ├─ AgentHarnessFactory.create → AgentHarnessSession
          │      ↓ session.run()
          │  ┌── Transcript：agent 做了什么（消息/工具调用/事件/性能）
          │  └── Outcome：环境最终是什么状态
          ├─ Graders 各自打分 → Score[]
          └─ EvalEnvironment.dispose
                  ↓
          EvalRunReport（pass@k / pass^k / 各 grader 均值 / bucket 分组）
```

下面把每个角色单独讲一层，**只讲框架本身的契约和字段**。怎么把一个真
StatefulAgent 接进来，看下一节"快速上手"。

### EvalTask — 一道测试题

接口（每个字段都必填，没有默认值）：

```dart
abstract class EvalTask {
  String get id;                          // 全局唯一
  String get description;                 // 给人看的一句话
  Map<String, dynamic> get input;         // 任意 JSON，Harness 自己解释
  Map<String, String> get metadata;       // failure_bucket 等标签
  ReferenceSolution? get referenceSolution; // 可选：已知正解
  List<Grader> get graders;               // 这道题挂哪些 grader
  int get trialsPerRun;                   // 同一道题跑几次（≥2 才能算 pass^k）
  Duration? get timeout;                  // 单 trial 超时
}
```

| 字段 | 注意 |
|---|---|
| `id` | **task 含义变了 = 新 id**（如 `card_001` → `card_001_v2`），不要原地改语义。`SuiteHealthAnalyzer` 跨 run 比较时按 id 对齐，复用 id 会污染 graduation / broken-task 判定 |
| `input` | 不要把 prompt 写死在这里再硬塞给 LLM。让 Harness 决定怎么把 `input` 转成 messages，同一个 task 才能在不同 agent 之间复用 |
| `metadata['failure_bucket']` | 框架会自动按这个值聚合 bucket pass rate，方便看"哪类失败模式最严重" |
| `graders` | 一道题可挂多个 grader（"答对" + "用了正确的工具"），每个 grader 独立打分；trial 只有所有 grader 都过线才算 `passed` |
| `trialsPerRun` | 给 capability suite 用 2–5；regression suite 一般 1。`trialsPerRun=1` 时 pass^k 退化成 pass@1，没意义 |

也支持**不写 Dart 类**，用 JSON 文件 + `JsonEvalTask` 加载，
[详见后面的章节](#两种-suite-定义方式)。

### EvalSuite — 一组围绕同一 Agent 的 task

```dart
EvalSuite(
  name: 'card_capability',
  agentName: 'card_agent',          // ← suite 维度：这个 suite 测的是哪个 agent
  kind: SuiteKind.capability,       // capability / regression / mixed
  tasks: [task1, task2, ...],
  requireReferenceSolution: false,  // true 时构造期校验所有 task 都有 reference
  taskPassThreshold: 1.0,           // taskPassRate 算"通过"的阈值
);
```

`agentName` **是 suite 维度**而不是 task 维度——同一组 task 不会被
"换一个 agent" 来复用，这是 Anthropic 博客明确的概念边界。

`kind` 影响 `taskPassRate` 的语义：

| kind | 一个 task 算"通过"的条件 | 用途 |
|---|---|---|
| `capability` | 所有 trial 至少有一个通过 | 衡量"会不会"。允许偶尔翻车 |
| `regression` | 所有 trial 全部通过 | 衡量"稳不稳"。一翻车就 block PR |
| `mixed` | 同 regression | 还没分级或在过渡 |

### EvalEnvironment — 准备"考场"

```dart
abstract class EvalEnvironment {
  Future<EvalContext> prepare({required Trial trial, required EvalTask task});
  Future<void> dispose(EvalContext context);
}
```

Runner 保证**每个 trial 单独调一次 prepare/dispose**——所以你可以在
prepare 里随便建临时目录、起内存 DB、生成测试用户、**包装 LLM client**，
dispose 里清掉。

`EvalContext` 是 prepare 的产物：

| 字段 | 说明 |
|---|---|
| `workspaceDir` | 该 trial 的临时工作区根。Agent 写文件应该全部在这里面，dispose 删整棵树就行。可以为 `null` |
| `clock` | 时间源（`SystemEvalClock` / `FixedEvalClock`）。Agent 应读 `ctx.clock.now()` 而不是 `DateTime.now()`，方便锁时间 |
| `llmClient` | 这次 trial 用的 LLM client。可以是真客户端，也可以是 `RecordingLLMClient` / `ReplayLLMClient` 包装。每个 trial 用独立 client，避免 record/replay 串味 |
| `controller` | 已经挂好 trace exporter 的 `AgentController`。Harness 必须**复用**它，不要自己 `new AgentController()`，否则 trace 流不到 exporter 上 |
| `servicesMap` | 应用自己塞 service（`CardRepo` / `UserStorage` / 内存 DB），Harness 用 `ctx.services<T>()` 取。框架不关心里面是什么 |
| `metadata` | 自由 metadata，会进 transcript |

> **EvalEnvironment 不知道 agent 长什么样**——它只负责准备资源。一个
> Environment 可以服务多种 Harness（不同 agent 类）。这是它和 Harness
> 的根本区别，新人最常混淆的就是这里。

### AgentHarnessFactory / AgentHarnessSession — 把模型变成 Agent

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

Harness 是**唯一**知道你 agent 长什么样的层：实例化 `StatefulAgent`、
注册 `Tool[]`、调 `agent.run([UserMessage(task.input['prompt'])])`，
然后从工作区或业务服务里采集最终 `Outcome`。通用运行轨迹由
`EvalRunner` 内置的 `EvalTranscriptRecorder` 从 `context.controller`
自动录制；Harness 必须复用这个 controller。

`run()` 必须返回**两件**东西。通常业务 Harness 只需要认真填
`Outcome`，`Transcript` 可以返回空对象，Runner 会用自动录制的 snapshot
补上：

- `Transcript` — agent **做了什么**：消息序列、工具调用、retry / error
  事件、turns / tokens 计数。默认由框架录制；只有需要覆盖或补充自定义
  轨迹时才手动构造。凡是评估过程、工具使用、消息、事件或指标的 grader
  都应该读它。
- `Outcome` — 环境**最终是什么状态**：`environmentState` 是任意 Map，
  schema 由你和 grader 约定。凡是评估最终状态的 grader 都应该读它。

`Outcome.environmentState` 的常见错误：

| ❌ 错（agent 说了什么） | ✅ 对（世界变成了什么） |
|---|---|
| `{'agent_said': 'I booked the flight'}` | `{'flight_booked': true, 'flight_id': 'AA123'}` |
| `{'response': '已记入 Areas/Health.md'}` | `{'updated_files': ['Areas/Health.md'], 'fact_id': 'fact_001'}` |
| `{'declined': '我不能回答'}` | `{'declined': true, 'submitted_answer': false}` |

#### Outcome 是 Harness 摘要给 Grader 的"事实表"

新人常问的一个问题：**Grader 是怎么知道 agent 写了哪些文件、文件内容
是什么的？里面跑了一个小 agent 去 list 目录吗？**

不是。**Grader 不读盘、不调 LLM 拿环境信息**。读盘、扫目录、提取事实
全部在 Harness 的 `run()` 收尾时干完，结果摆进 `Outcome.environmentState`
和 `Outcome.workspaceDiff` 里——Grader 拿到的就是这份**已经摘要好的快照**。

PKM agent 真实例子（节选自 `example/eval_demo/pkm_agent/harness.dart`）：

```dart
// Harness.run() 末尾的"事实采集"代码
Outcome _capturePkmOutcome(Directory ws) {
  // ① 扫工作区目录
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

  // ② 从写过的文件里正则抽出 fact_id 之类的关键事实
  final factIds = <String>{};
  snippets.forEach((_, body) {
    final m = RegExp(r'fact_id\s*:\s*(\S+)').firstMatch(body);
    if (m != null) factIds.add(m.group(1)!);
  });

  // ③ 检查哨兵文件（agent 调用某些工具会触发副作用文件）
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

对应的 Grader 完全不碰文件系统：

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

为什么这样设计：

| 如果让 Grader 自己读盘 | 后果 |
|---|---|
| Outcome 失去自包含性 | report 持久化后想离线看也得拖着工作区文件 |
| 多 grader 重复扫盘 | 一道题挂 3 个 grader，每个都 `listSync`，IO 三遍 |
| Grader 关心 schema 而不是路径 | 每个 grader 都要懂"PKM 在哪个子目录、用什么文件名约定"——这是 agent 实现细节，不该泄漏到打分逻辑 |
| 跨 run diff / SuiteHealth 没法做 | `EvalRunReport` 只存 outcome，不存工作区文件 |

LLM judge 同理：judge 也只读 `outcome.environmentState` 的某些字段
（通常是文本字段或 `workspaceDiff.contentSnippets`），把它塞进 rubric
prompt 里去问模型，**不会自己开 agent 去探索工作区**。

> **极端情况**：少数场景 grader 真的要"跨多个文件 + 工具 + 推理"
> （比如审计 agent 写出的整个项目代码一致性）。框架不拦你——grader
> 拿到的 `EvalContext` 里有 `workspaceDir` / `llmClient` / `servicesMap`，
> 完全可以在 grader 里再起一个小 agent 去探索。但这是 anti-pattern。
> 99% 的情况，**先问一遍"是不是该把这部分采集逻辑挪到 Harness 里"**。

### Grader — 评卷

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

按"怎么算分"分三种基类：`CodeGrader`（确定性代码）、`ModelGrader`
（LLM-as-judge）、`HumanGrader`（推到 review queue 等人评）。
[详见后面的章节](#三种评分方式)。

输出 `Score`：

| 字段 | 说明 |
|---|---|
| `value` | 0..1 的连续分（支持 partial credit）。`null` 表示判不了（如 LLM judge 返回 Unknown） |
| `passed` | 是否过 `passThreshold`。`null` 当 `value=null` |
| `assertions` | 子检查列表（`description` / `passed` / `actual` / `expected`），方便人看是哪个子项挂了 |
| `rationale` | 失败时**必填**：人能看懂的解释。Anthropic Step 5 强调"failures should seem fair" |
| `metadata` | 自由：可以放 judge 原始回复、diff 详情等 |

### EvalRunner — 跑

不用你实现，调 `runSuite(...)` 就行：

```dart
final report = await runner.runSuite(
  runName: 'pr-${prNumber}',         // 这次 run 的标识，进 store / langfuse
  suite: mySuite,
  concurrency: 4,                    // 并行 trial 数
  filter: TaskFilter(...),           // 可选：只跑某些 task
);
```

它内部会：

1. 按 `concurrency` 并行起 worker，每个 worker 拿一个 (task, trial) 跑
2. 每个 trial 单独 `env.prepare()` → `harness.create().run()` → 各 grader 打分 → `env.dispose()`
3. 把 trial 事件实时推给所有 `exporters`（jsonl / Langfuse / 自定义）
4. 跑完算 pass@k / pass^k / 各 grader 均值 / bucket 通过率
5. 把 `EvalRunReport` 落地到 `reportStore`，供后续 diff / SuiteHealthAnalyzer 用

`EvalRunMode`（在 `parseEvalRunArgs` 里读 `--mode` 参数）：

- `live` — 真打 LLM，每次都烧 token
- `record` — 真打 LLM 同时把请求/响应写入 `RecordingStore`
- `replay` — 不打 LLM，命中 store 里的录像；不命中报错

CI 上 regression suite 一般 `replay`（毫秒级 + 零成本），capability
suite nightly 跑 `live`。

</br>

## 快速上手

```bash
dart pub add dart_agent_core
```

最小可跑示例。完整源码见 [`example/min_eval/main.dart`](../example/min_eval/main.dart)。
配置 `OPENAI_API_KEY` / `OPENAI_BASE_URL` / `OPENAI_MODEL` 后 `dart run`：

```dart
import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';

// ─── 1. 写一个最小的 Agent（只会用 echo 工具回话） ──────────────────────
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

// ─── 2. EvalEnvironment：给每个 trial 一个临时工作目录 ──────────────────
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

// ─── 3. AgentHarnessFactory：把模型包装成一个会调工具的 Agent ────────────
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

// ─── 4. Grader：echoed == 期望的文本 ─────────────────────────────────────
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

// ─── 6. main：拼起来跑 ────────────────────────────────────────────────────
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

输出：

- `.eval_reports/<run_name>.json` — 完整 run report，可被 transcripts CLI 加载
- `.eval_reports/index.jsonl` — 跨 run 索引
- `.eval_traces/echo.jsonl` — OTel 风格的 trace 流
- stdout — Markdown 报告（task / trial pass rate、pass@k、各 grader 均值）

更复杂场景（多 grader、文件 fixture、多 task、record/replay、跨 run
diff）见 [`example/eval_demo/`](../example/eval_demo/) 下的三个 demo
（`calculator/`、`card_agent/`、`pkm_agent/`）。

</br>

## 两种 suite 定义方式

`dart_agent_core` 同时支持**代码定义**和**文件定义**两种 suite。
两种方式可以混用。

### 方式 A — 代码定义（`EvalSuite(...)` + `EvalTask` 子类）

适合 task 数量少、强类型校验、需要重构跟随的场景。`example/eval_demo/calculator/`
和 `example/eval_demo/card_agent/` 都是这种风格。

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
  agentName: 'calculator_demo_agent',  // ← suite-level: 这个 suite 里所有 task 都打的是同一个 agent
  kind: SuiteKind.mixed,
  tasks: [_SimpleAdditionTask(), ...],
  requireReferenceSolution: true,
);
```

### 方式 B — 文件定义（目录布局 + `loadEvalSuiteFromDir`）

适合 task 集会持续扩张、产品同学/QA 想直接 PR 加 case、case 需要按
故障类别分目录的场景。`example/eval_demo/pkm_agent/suites/` 是这种风格。

目录布局：

```
suites/
  pkm_capability/
    suite.json                    ← 元数据
    tasks/                        ← 一个 task 一个 JSON
      positive/                   ← 子目录可选，仅做组织
        pkm_area_health.json
        pkm_resource_reading.json
        pkm_append_to_existing.json
      negative/
        pkm_skip_trivial.json
```

`suite.json`：

```json
{
  "name": "pkm_agent_demo",
  "agent_name": "pkm_agent_demo",
  "kind": "mixed",
  "requireReferenceSolution": true,
  "taskPassThreshold": 1.0
}
```

每个 task 文件：

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

加载：

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

| 维度 | 代码定义 | 文件定义 |
|---|---|---|
| 写起来快 | ✅ IDE 补全、类型安全 | 🔶 要手动编 JSON |
| 大规模维护 | 🔶 case 多了文件会臃肿 | ✅ 一个 task 一个文件，git diff 友好 |
| 非工程师能否参与 | ❌ 必须懂 Dart | ✅ 写 JSON 即可 |
| 重构跟随 | ✅ rename grader 编译器报错 | 🔶 要手动改 JSON 里的 grader name |
| 何时用 | demo / 框架内部测试 / 类型敏感场景 | 业务方 case 库 / 跨团队协作 |

> **建议**：开发期用代码定义快速迭代，case 集稳定后导出成 JSON。
> grader 永远是代码（强类型 + 可调试），task 数据可以是代码也可以是文件。

</br>

## 三种评分方式

Anthropic 把评分器分为三类，框架都内置了基类。

### 1. Code-based（`CodeGrader`）—— 确定性、最快

适合：精确字符串匹配、数值比较、文件存在性、JSON schema 校验、tool call
出现次数等可以用代码精确判定的检查。

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

`CodeGrader` 把 `Assertion` 列表自动聚合成 `Score(value, passed)`：

- `value = 通过的 assertion 数 / 总 assertion 数`
- `passed = value >= passThreshold`，默认 `passThreshold = 1.0`（全部通过）
- 失败时自动生成包含失败 assertion 的 rationale

### 2. Model-based（`ModelGrader` / LLM-as-judge）—— 灵活、可处理主观任务

适合：开放式回答的相关性、风格一致性、安全性等 code-based 难以判定的维度。

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
        'Reply: SCORE=<float 0-1> or SCORE=Unknown';
    final reply = await judgeClient.generate(
      [UserMessage.text(prompt)],
      modelConfig: modelConfig,
    );
    // 解析回复并返回 Score（含 Unknown escape hatch）
    ...
  }
}
```

**Anthropic Step 5 关键点**：rubric 必须留 `Unknown` 退路。如果 judge
拿不准，应当返回 `Score(value: null, passed: null)` 而不是硬编一个分数。
这种 null score 会从 grader mean 中排除，但单独统计。

### 3. Human-based（`HumanGrader` + `HumanReviewQueue`）—— 标准、最慢

`HumanGrader` 把 trial 推到一个 `HumanReviewQueue`（接口由你实现，
对接 Langfuse Annotation Queue / 自建 Web / Slack 工作流均可）：

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

第一次 grade 时入队 + 返回 pending null score；评审员打完分后下次
跑 grade 拿到结果。主要用途是**校准 LLM judge**（见 [Judge 校准](#judge-校准)），
而不是给每次 run 打分。

</br>

## Trial、Outcome 和 Transcript

每次 trial 的产出是 `TrialResult`：

```dart
class TrialResult {
  final Trial trial;            // run / suite / task / index / status / 时间
  final Transcript transcript;  // 消息 + 工具调用 + 事件 + 性能指标
  final Outcome outcome;        // 环境最终状态
  final List<Score> scores;     // 各 grader 的输出
}
```

### Transcript（"Agent 做了什么"）

```dart
class Transcript {
  final List<LLMMessage> messages;
  final List<ToolCallRecord> toolCalls;
  final List<String> reasoningSteps;
  final List<TranscriptEvent> events;       // retry / exception / 自定义
  final TranscriptMetrics metrics;          // turns / tokens / TTFT / TTLT
}
```

### Outcome（"环境最终是什么状态"）

```dart
class Outcome {
  final Map<String, dynamic> environmentState;  // 应用自定义 schema
  final WorkspaceDiff? workspaceDiff;           // 文件级别 diff
}
```

**Anthropic Step 5 反复强调**：每个 grader 应该评估 trial 中与指标相关的
那部分证据。终态 grader 看 `outcome`；过程 grader 看 `transcript`，包括
工具调用、消息、reasoning / events 和性能指标。

</br>

## 指标与报告

`EvalRunReport` 自动算所有 Anthropic 推荐的指标。

### Pass-rate（按 suite kind 分语义）

- `trialPassRate` —— 通过 trial 数 / 总 trial 数
- `taskPassRate` ——
  - `SuiteKind.capability`: 一个 task 至少有一个 trial 通过即算通过
  - `SuiteKind.regression`: 一个 task 所有 trial 都通过才算通过
  - `SuiteKind.mixed`: 同 regression

### pass@k（Codex 无偏估计）

`pass@k = 1 − C(n−c, k) / C(n, k)`。"k 次尝试至少成功一次"的概率。

### pass^k（经验估计）

`pass^k = (c/n)^k`。"k 次尝试全部成功"的概率。Anthropic 推荐
**pass@1 接近 100%、pass^k 的 k 越大越好**（连续稳定通过的能力）。

当 `k` 大于实际 trial 数 `n` 时，Markdown 报告会将 `pass@k` 显示为
`N/A`，并把 `pass^k` 标记为低置信度的经验估计。

```dart
final passAt = report.passAtKByTask(ks: [1, 3, 5]);
final passCk = report.passCaretKByTask(ks: [1, 3, 5]);
```

### Bucket 分组

按 `metadata['failure_bucket']` 看每个失败模式的通过率：

```dart
final byBucket = report.bucketPassRates({
  for (final t in suite.tasks)
    if (t.metadata['failure_bucket'] != null)
      t.id: t.metadata['failure_bucket']!,
});
// {tool_use: 0.92, intent_routing: 0.65, …}
```

### 分类指标（`ClassificationMetrics`）

二分类任务（Memory Agent 应不应该写记忆、Schedule Router 应不应该刷新）
直接用 P/R/F1：

```dart
const m = ClassificationMetrics(
  truePositives: 6, falsePositives: 2,
  trueNegatives: 8, falseNegatives: 4,
);
print(m.precision); // 0.75
print(m.recall);    // 0.6
print(m.f1);        // 0.6667
```

### Markdown 报告 + Diff

```dart
// 单 run 报告
final md = report.toMarkdownSummary(taskBucketMap: {...});
File('report.md').writeAsStringSync(md);

// 跨 run diff（PR 评论用）
final baseline = await store.load('main');
final diff = report.diffWith(baseline!);
File('diff.md').writeAsStringSync(diff.toMarkdown());
```

</br>

## 录制 / 回放 / 限流

每次跑评估都打真实 LLM 既慢又贵，CI 还会被网络抖动搞挂。框架提供
**确定性回放**和**速率限制**两层基础设施。

### 录制 / 回放

```dart
// 第一次跑：录制
final store = FileRecordingStore(Directory('.eval_recordings'));
final llm = RecordingLLMClient(
  inner: OpenAIClient(...),
  store: store,
);

// 后续 CI：回放（命中即返回缓存，不命中报错）
final replay = ReplayLLMClient(
  store: FileRecordingStore(Directory('.eval_recordings')),
  strictReplay: true,  // CI 必须严格
);
```

请求 hash 由 `Sha256LLMRequestHash` 计算（默认）：

- 包含 `messages` / `tools` / `modelConfig` / `jsonOutput` / `trialSalt`
- 可通过 `stripMessageKeys` 跳过易变字段（`timestamp` 等）
- prompt 或 tools 改了 → hash 变 → 缓存自动失效，CI 报错提示 re-record

#### 多 trial 的非确定性 — `trialSalt`

`trialsPerRun > 1` 时，同一个 task 的所有 trial 发出去的请求字面意义
上完全一样（同 prompt、同 tools、同 model）。如果 hash 只看请求内容，
N 个 trial 会塌成 1 份缓存，**pass^k / pass@k 测的就不再是模型的非确
定性而是缓存的回放结果**，违背 Anthropic Step 6。

框架的解法：每个 trial 独立 salt 进 hash。`EvalEnvironment.prepare()`
拿到 `Trial` 之后，把 `trial.cacheSalt`（形如 `taskId#trialIndex`，
**不**含 runName，这样录的时候和回放时跨 run 仍能命中）传给
`RecordingLLMClient` / `ReplayLLMClient` 的 `trialSalt`。N 个 trial
在缓存里就是 N 个独立条目，录的时候录 N 份不同响应，回放的时候每个
trial 拿到对应 trial 的那一份。

```dart
// EvalEnvironment.prepare 内部：
final salt = trial.cacheSalt;
final llmClient = RecordingLLMClient(
  inner: liveClientFactory(),
  store: store,
  trialSalt: salt,           // ← 关键
);
// 或者：base.withTrialSalt(salt)，更省一行
```

`trialSalt: null`（不传）则 cache 在所有 trial 之间共享。这种行为是
为了 judge / ad-hoc analysis 这种"逻辑上同一个调用"的场景准备的，
通常**不**是 agent 主调用想要的。三个内置 demo（calculator / card /
pkm）的 environment 都示范了正确做法。

### 限流

```dart
final gate = RpmRateLimitGate(requestsPerMinute: 120);
// 或 token 维度
final gate = TpmRateLimitGate(tokensPerMinute: 60000);

final llm = RecordingLLMClient(
  inner: ...,
  store: ...,
  rateLimitGate: gate,
);
```

`acquire()` 在调真实 LLM 前阻塞，回放命中时**不**触发限流（已经是
本地操作了）——这样 concurrency 和 rate-limit 解耦：可以把
`concurrency` 调大充分压榨 CPU / IO，速率上限交给闸门控制。

</br>

## Langfuse 上报

把每个 trial 实时上报到 [Langfuse](https://langfuse.com/) 是开箱即用的。
Langfuse 是当下最主流的开源 LLM observability 后端，自带 trace 树视图、
按 user/session/tag 过滤、在线 score 评分、prompt diff 等功能。

```dart
import 'package:dart_agent_core/eval.dart';

final exporter = LangfuseTraceExporter(LangfuseConfig.fromEnv());
// 或显式传配置：
//   LangfuseConfig(
//     host: 'https://cloud.langfuse.com',  // 自托管时改成你的地址
//     publicKey: 'pk-...',
//     secretKey: 'sk-...',
//     environment: 'staging',
//   );

final runner = EvalRunner(
  environment: env,
  harnessFactory: harness,
  exporters: [
    JsonlTraceExporter(File('.eval_traces/run.jsonl')),
    exporter,           // 同时本地落盘 + 上报 Langfuse
  ],
  reportStore: FileReportStore(Directory('.eval_reports')),
);
```

映射规则：

| dart_agent_core | Langfuse |
|---|---|
| 一个 `Trial` | 一个 trace（`name = suite/task#trialIndex`，`userId = runName`，`sessionId = suiteName`） |
| 每次 LLM 调用 | `generation-create` observation，含 `model` / `modelParameters` / `input` / `output` / `usage` |
| 每次 tool 调用 | `span-create` observation，含 `arguments` / `result` |
| 每个 `Score` | `score-create`（`dataType=NUMERIC`，`comment=rationale`，`assertions`/`metadata` 一并挂上） |
| `onRunEnd` 的 aggregate | 一个 `run-summary` trace + 每个指标一条 `score-create` |

实现细节：

- 全部走后台批量队列：默认满 50 条 event 或每 1 秒 flush 一次，eval run
  几乎感知不到上报开销
- HTTP 5xx 自动指数退避重试（默认 3 次），4xx 直接放弃不重试
- 网络抖动 / langfuse 临时挂掉时**最多丢几条 event，不会拖垮 eval run**
- 跑 `dispose()` 强制 flush 完所有积压

环境变量约定（`LangfuseConfig.fromEnv` 读这些）：

```bash
export LANGFUSE_PUBLIC_KEY='pk-...'
export LANGFUSE_SECRET_KEY='sk-...'
export LANGFUSE_HOST='https://cloud.langfuse.com'  # 可选，默认 cloud
export LANGFUSE_ENVIRONMENT='staging'              # 可选，dashboard 上分桶用
```

</br>

## 跨 run 健康度

`SuiteHealthAnalyzer` 跨多次 run 算两件事（Anthropic Step 7）：

### Graduation（毕业）

某个 task 连续 N 次 run 都通过率 ≥ 95%，建议从 capability suite
"毕业"到 regression suite，并在 capability suite 里换上更难的 task。

### Broken task（破损 task）

某个 task 跨多次 run 都通过率 ≤ 0%，**通常是 task 定义/grader
配置有 bug**，不是 Agent 真做不到。

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

## Judge 校准

LLM judge 自己也是非确定的，必须**用人工评分校准**才能上线（Anthropic
Step 5 上线门槛：Spearman ≥ 0.7）。

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

输出：Spearman / Pearson 相关系数、agreement rate、MAE、按 |Δ| 降序的
disagreement 列表（哪些 trial 上 judge 和人工最分歧）。

</br>

## CLI 工具

```bash
# 列出所有 run（按时间倒序）
dart run dart_agent_core:transcripts list --store .eval_reports

# 查看某次 trial 的细节
dart run dart_agent_core:transcripts show \
  --store .eval_reports \
  --trial pr-123/card_001#0

# 同一个 task 跨两次 run 对比
dart run dart_agent_core:transcripts diff \
  --store .eval_reports \
  --task card_001 --runs main,pr-123

# 把整个 run 导出成 markdown
dart run dart_agent_core:transcripts export \
  --store .eval_reports --run pr-123 --format markdown
```

</br>

## 完整示例

`example/eval_demo/` 里有三个端到端可运行的 demo：

| Demo | Suite 定义方式 | 演示内容 |
|---|---|---|
| `calculator/` | 代码 | 基础 `CodeGrader` + 工具调用追踪 + decline 路径 |
| `card_agent/` | 代码 | 多 grader 组合 + 模板选择 + 字符串包含检查 |
| `pkm_agent/` | **文件** | `loadEvalSuiteFromDir` + `GraderRegistry` + fixture 文件 + read-before-write 路径检查 |

跑：

```bash
export OPENAI_BASE_URL='https://...'
export OPENAI_API_KEY='sk-...'

dart run example/eval_demo/main.dart --suite calculator
dart run example/eval_demo/main.dart --suite card_agent
dart run example/eval_demo/main.dart --suite pkm_agent
dart run example/eval_demo/main.dart --suite all --concurrency 6
```

输出会落到 `.eval_reports/`、`.eval_traces/`，
`--mode record|replay` 时还会用 `.eval_recordings/`。

</br>

## API 速查表

```dart
import 'package:dart_agent_core/eval.dart';
```

### 核心数据类型

| 类型 | 用途 |
|---|---|
| `EvalTask` | task 定义接口；自实现或用 `JsonEvalTask` |
| `EvalSuite` | task 列表 + kind + 阈值 |
| `Trial` / `TrialId` / `TrialStatus` | 一次尝试的元数据 |
| `Transcript` / `ToolCallRecord` / `TranscriptMetrics` | "Agent 做了什么" |
| `Outcome` / `WorkspaceDiff` | "环境最终状态" |
| `TrialResult` | 上面三件套的合体 |
| `ReferenceSolution` | Anthropic Step 2 已知正解 |

### Grader 体系

| 类型 | 用途 |
|---|---|
| `Grader` | 基类 |
| `CodeGrader` | 代码 / 确定性评分基类 |
| `ModelGrader` | LLM-as-judge 基类 |
| `HumanGrader` / `HumanReviewQueue` | 人工评分 |
| `Score` / `Assertion` / `GraderKind` | 评分输出 |
| `GraderRegistry` | 文件定义 suite 时按名字注册 grader |

### Runner 与上下文

| 类型 | 用途 |
|---|---|
| `EvalRunner` | 跑 suite 的入口 |
| `EvalRunConfig` / `parseEvalRunArgs` | CLI 参数解析（run name / concurrency / mode / filter / rpm / tpm / recording-dir） |
| `EvalRunMode` | `live` / `record` / `replay` |
| `TaskFilter` | 按 agent / bucket / id 过滤 |
| `EvalEnvironment` | 准备 / 销毁 trial 上下文 |
| `EvalContext` / `EvalClock` | 单 trial 上下文：workspace + clock + LLM client + controller |
| `AgentHarnessFactory` / `AgentHarnessSession` | Agent 脚手架接口（你实现） |
| `EvalRunReport` | 聚合报告 + saturationStatus |

### 录制 / 回放 / 限流

| 类型 | 用途 |
|---|---|
| `LLMRequestHash` / `Sha256LLMRequestHash` | 请求哈希 |
| `RecordingStore` / `InMemoryRecordingStore` / `FileRecordingStore` | 录制存储 |
| `RecordingLLMClient` / `ReplayLLMClient` / `RecordingNotFoundException` | 录 / 回 包装 |
| `RateLimitGate` / `RpmRateLimitGate` / `TpmRateLimitGate` / `NoopRateLimitGate` | 限流 |

### 观测 / 报告

| 类型 | 用途 |
|---|---|
| `TraceExporter` / `JsonlTraceExporter` / `CompositeTraceExporter` | 流式导出 trial 事件 |
| `LangfuseConfig` / `LangfuseClient` / `LangfuseTraceExporter` | Langfuse 上报（trace / generation / span / score） |
| `runTranscriptViewer` / `transcriptViewerUsage` | CLI 入口 |
| `ReportStore` / `FileReportStore` | run report 持久化 |
| `PersistedRunReport` / `SuiteSnapshot` / `RunIndexEntry` | 持久化模型 |
| `generateMarkdownReport` / `EvalRunReportReporting` | Markdown 渲染 |
| `diffRunReports` / `EvalRunReportDiff` / `EvalRunDiff` / `TaskTransition` | 跨 run diff |

### 指标 / 健康度 / 校准

| 类型 / 函数 | 用途 |
|---|---|
| `passAtK` / `passCaretK` | Codex / 经验估计 |
| `ClassificationMetrics` | P / R / F1 / accuracy |
| `SaturationStatus` / `SaturationThresholds` / `GraduationCandidate` / `BrokenTaskCandidate` | 饱和度 |
| `SuiteHealthAnalyzer` / `SuiteHealthReport` | 跨 run 健康度 |
| `JudgeCalibrator` / `CalibrationReport` / `HumanLabeledTrial` / `TrialDisagreement` | judge 校准 |

### 文件加载

| 类型 / 函数 | 用途 |
|---|---|
| `loadEvalSuiteFromDir` | 从目录加载 suite |
| `JsonEvalTask` | 数据驱动 task |
| `GraderRegistry` / `GraderFactoryFunction` | grader 名字 → 工厂 |

</br>

## 设计参考

- [Anthropic Engineering — Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
