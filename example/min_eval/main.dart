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
      'properties': {
        'text': {'type': 'string'},
      },
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
  Future<EvalContext> prepare({
    required Trial trial,
    required EvalTask task,
  }) async {
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
  _EchoSession({
    required this.task,
    required this.ctx,
    required this.modelConfig,
  });

  @override
  Future<({Transcript transcript, Outcome outcome})> run() async {
    final agent = StatefulAgent(
      name: 'echo_agent',
      client: ctx.llmClient,
      modelConfig: modelConfig,
      state: AgentState(sessionId: task.id),
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
        messages: List.unmodifiable(agent.state.history.messages),
        toolCalls: const [],
        metrics: const TranscriptMetrics(
          nTurns: 0,
          nToolCalls: 0,
          nTotalTokens: 0,
        ),
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
  @override
  String get name => 'echo_matches';

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
  @override
  String get id => 'echo_hi';
  @override
  String get description => 'agent must echo "hi" verbatim';
  @override
  Map<String, dynamic> get input => {'prompt': 'echo this back: hi'};
  @override
  Map<String, String> get metadata => const {};
  @override
  ReferenceSolution? get referenceSolution => null;
  @override
  List<Grader> get graders => [_EchoMatchesGrader('hi')];
  @override
  int get trialsPerRun => 2;
  @override
  Duration? get timeout => const Duration(minutes: 1);
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
    harnessFactory: EchoHarness(
      ModelConfig(model: env['OPENAI_MODEL'] ?? 'gpt-4o-mini'),
    ),
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
