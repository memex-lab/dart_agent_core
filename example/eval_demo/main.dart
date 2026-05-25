import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';
import 'package:logging/logging.dart';

import 'calculator/environment.dart';
import 'calculator/harness.dart';
import 'calculator/tasks.dart';
import 'card_agent/environment.dart';
import 'card_agent/harness.dart';
import 'card_agent/tasks.dart';
import 'pkm_agent/environment.dart';
import 'pkm_agent/harness.dart';
import 'pkm_agent/tasks.dart';

/// End-to-end demo of the eval harness against multiple realistic
/// agent scenarios:
///
/// ```bash
/// export OPENAI_BASE_URL='https://...'
/// export OPENAI_API_KEY='sk-...'
///
/// # Pick which suite to run:
/// dart run example/eval_demo/main.dart --suite calculator
/// dart run example/eval_demo/main.dart --suite card_agent
/// dart run example/eval_demo/main.dart --suite pkm_agent
/// dart run example/eval_demo/main.dart --suite all
///
/// # Common options:
/// dart run example/eval_demo/main.dart \
///   --suite all --concurrency 4 --mode live
/// ```
///
/// Reports (markdown + JSON) land in `./.eval_reports/`, JSONL traces in
/// `./.eval_traces/`, recordings (record/replay modes) in
/// `./.eval_recordings/`. The exit code is the worst-case task pass
/// rate across all suites: 0 only if every suite saw 100%.
Future<void> main(List<String> argv) async {
  _setupLogging();

  final env = Platform.environment;
  final suiteArg = _readArg(argv, '--suite') ?? 'calculator';

  final config = parseEvalRunArgs(
    argv,
    env: env,
    defaultRunName: '${suiteArg}_${DateTime.now().millisecondsSinceEpoch}',
  );

  final baseUrl = env['OPENAI_BASE_URL'];
  final apiKey = env['OPENAI_API_KEY'];
  if (config.mode != EvalRunMode.replay) {
    if (baseUrl == null || baseUrl.isEmpty) {
      stderr.writeln('OPENAI_BASE_URL is not set');
      exit(2);
    }
    if (apiKey == null || apiKey.isEmpty) {
      stderr.writeln('OPENAI_API_KEY is not set');
      exit(2);
    }
  }

  final modelName = env['EVAL_MODEL'] ?? 'anthropic/claude-opus-4.7';
  final modelConfig = ModelConfig(model: modelName, temperature: 0.0);

  final tracesDir = Directory('.eval_traces')..createSync(recursive: true);
  final reportsRoot = Directory('.eval_reports')..createSync(recursive: true);
  final recordingDir = config.recordingDir ?? '.eval_recordings';

  RateLimitGate gate = const NoopRateLimitGate();
  if (config.rpm != null) {
    gate = RpmRateLimitGate(requestsPerMinute: config.rpm!);
  }
  final replayOnly = config.mode == EvalRunMode.replay;

  OpenAIClient liveClientFactory() => OpenAIClient(
    apiKey: apiKey ?? '',
    baseUrl: baseUrl ?? 'https://api.openai.com/v1',
  );

  RecordingStore? buildStore() {
    switch (config.mode) {
      case EvalRunMode.record:
      case EvalRunMode.replay:
        return FileRecordingStore(Directory(recordingDir));
      case EvalRunMode.live:
        return null;
    }
  }

  final reportStore = FileReportStore(reportsRoot);

  // ─── Resolve which suite(s) to run ──────────────────────────────────────
  final selected = <_DemoSuite>[];
  switch (suiteArg) {
    case 'calculator':
      selected.add(
        _calculatorDemo(modelConfig, liveClientFactory, gate, replayOnly),
      );
      break;
    case 'card_agent':
    case 'card':
      selected.add(
        _cardAgentDemo(modelConfig, liveClientFactory, gate, replayOnly),
      );
      break;
    case 'pkm_agent':
    case 'pkm':
      selected.add(
        _pkmAgentDemo(modelConfig, liveClientFactory, gate, replayOnly),
      );
      break;
    case 'all':
      selected.addAll([
        _calculatorDemo(modelConfig, liveClientFactory, gate, replayOnly),
        _cardAgentDemo(modelConfig, liveClientFactory, gate, replayOnly),
        _pkmAgentDemo(modelConfig, liveClientFactory, gate, replayOnly),
      ]);
      break;
    default:
      stderr.writeln(
        'Unknown --suite "$suiteArg". '
        'Use one of: calculator | card_agent | pkm_agent | all',
      );
      exit(2);
  }

  // ─── Run each selected suite ────────────────────────────────────────────
  final allReports = <EvalRunReport>[];
  for (final demo in selected) {
    if (!config.filter.matchesSuite(demo.suite)) {
      stdout.writeln(
        '\n• skipping suite=${demo.suite.name} '
        '(agent=${demo.suite.agentName} filtered out)',
      );
      continue;
    }

    final runName = selected.length == 1
        ? config.runName
        : '${demo.suite.name}_${DateTime.now().millisecondsSinceEpoch}';

    final tracesFile = File('${tracesDir.path}/${_safeName(runName)}.jsonl');
    final exporter = JsonlTraceExporter(tracesFile);
    final store = buildStore();

    final runner = EvalRunner(
      environment: demo.environmentBuilder(store),
      harnessFactory: demo.harnessFactory,
      exporters: [exporter],
      recordingStore: store,
      reportStore: reportStore,
      rateLimitGate: gate,
    );

    stdout.writeln(
      '\n• run_name=$runName suite=${demo.suite.name} '
      'agent=${demo.suite.agentName} '
      'mode=${config.mode.name} concurrency=${config.concurrency} '
      'model=$modelName',
    );

    final report = await runner.runSuite(
      runName: runName,
      suite: demo.suite,
      concurrency: config.concurrency,
      trialsOverride: config.trialsOverride,
      filter: config.filter.isEmpty ? null : config.filter.matchesTask,
    );
    allReports.add(report);

    final taskBucketMap = <String, String>{
      for (final t in demo.suite.tasks)
        if (t.metadata['failure_bucket'] != null)
          t.id: t.metadata['failure_bucket']!,
    };
    final md = generateMarkdownReport(
      report,
      taskBucketMap: taskBucketMap,
      ksToReport: const [1, 2],
    );
    final mdFile = File('${reportsRoot.path}/${_safeName(runName)}.md');
    await mdFile.writeAsString(md);
    stdout.writeln('\n=== Markdown summary (${demo.suite.name}) ===\n');
    stdout.writeln(md);
    stdout.writeln('=== Saved to: ${mdFile.path} ===');
  }

  // ─── Combined summary ───────────────────────────────────────────────────
  if (allReports.length > 1) {
    stdout.writeln('\n=== All suites ===');
    stdout.writeln('| Suite | Tasks | Trials | Task pass | Trial pass |');
    stdout.writeln('|---|---|---|---|---|');
    for (final r in allReports) {
      stdout.writeln(
        '| ${r.suite.name} | ${r.trialsByTask().length} | '
        '${r.trials.length} | '
        '${(r.taskPassRate * 100).toStringAsFixed(1)}% | '
        '${(r.trialPassRate * 100).toStringAsFixed(1)}% |',
      );
    }
  }

  // Exit code: 0 iff every suite passed 100% of tasks.
  final allPassed = allReports.every((r) => r.taskPassRate >= 1.0);
  exit(allPassed ? 0 : 1);
}

class _DemoSuite {
  final EvalSuite suite;
  final EvalEnvironment Function(RecordingStore? store) environmentBuilder;
  final AgentHarnessFactory harnessFactory;
  const _DemoSuite({
    required this.suite,
    required this.environmentBuilder,
    required this.harnessFactory,
  });
}

_DemoSuite _calculatorDemo(
  ModelConfig modelConfig,
  LLMClient Function() liveClientFactory,
  RateLimitGate gate,
  bool replayOnly,
) {
  return _DemoSuite(
    suite: buildCalculatorDemoSuite(),
    harnessFactory: CalculatorAgentHarnessFactory(modelConfig: modelConfig),
    environmentBuilder: (store) => CalculatorEvalEnvironment(
      liveClientFactory: liveClientFactory,
      recordingStore: store,
      replayOnly: replayOnly,
      rateLimitGate: gate,
    ),
  );
}

_DemoSuite _cardAgentDemo(
  ModelConfig modelConfig,
  LLMClient Function() liveClientFactory,
  RateLimitGate gate,
  bool replayOnly,
) {
  return _DemoSuite(
    suite: buildCardAgentDemoSuite(),
    harnessFactory: CardAgentHarnessFactory(modelConfig: modelConfig),
    environmentBuilder: (store) => CardAgentEnvironment(
      liveClientFactory: liveClientFactory,
      recordingStore: store,
      replayOnly: replayOnly,
      rateLimitGate: gate,
    ),
  );
}

_DemoSuite _pkmAgentDemo(
  ModelConfig modelConfig,
  LLMClient Function() liveClientFactory,
  RateLimitGate gate,
  bool replayOnly,
) {
  return _DemoSuite(
    suite: buildPkmAgentDemoSuite(),
    harnessFactory: PkmAgentHarnessFactory(modelConfig: modelConfig),
    environmentBuilder: (store) => PkmAgentEnvironment(
      liveClientFactory: liveClientFactory,
      recordingStore: store,
      replayOnly: replayOnly,
      rateLimitGate: gate,
    ),
  );
}

void _setupLogging() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((rec) {
    stderr.writeln('[${rec.level.name}] ${rec.loggerName}: ${rec.message}');
    if (rec.error != null) stderr.writeln('  err: ${rec.error}');
  });
}

String? _readArg(List<String> args, String key) {
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == key) return args[i + 1];
  }
  return null;
}

String _safeName(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');
