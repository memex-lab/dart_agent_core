import '../core/eval_suite.dart';
import '../core/eval_task.dart';

/// Run mode controlled by CLI / env.
enum EvalRunMode { record, replay, live }

/// Filter applied to suites and tasks at runtime.
///
/// `agents` filters at the **suite** level (a suite belongs to one agent
/// — see [EvalSuite.agentName]). `buckets` and `taskIds` filter at the
/// **task** level inside an already-selected suite.
class TaskFilter {
  final Set<String>? agents;
  final Set<String>? buckets;
  final Set<String>? taskIds;

  const TaskFilter({this.agents, this.buckets, this.taskIds});

  /// Whether the given suite passes the agent filter.
  bool matchesSuite(EvalSuite suite) {
    if (agents != null && !agents!.contains(suite.agentName)) return false;
    return true;
  }

  /// Whether the given task passes the task-level filters.
  ///
  /// Note: this does NOT check the agent filter — see [matchesSuite].
  /// Callers that want a single predicate for [EvalRunner.runSuite]
  /// should pre-check the suite once and then use [matchesTask] for
  /// each task.
  bool matchesTask(EvalTask task) {
    if (taskIds != null && !taskIds!.contains(task.id)) return false;
    if (buckets != null) {
      final b = task.metadata['failure_bucket'];
      if (b == null || !buckets!.contains(b)) return false;
    }
    return true;
  }

  bool get isEmpty => agents == null && buckets == null && taskIds == null;
}

/// Parsed L2 (runner-level) configuration. Sources: CLI args, env vars.
/// Applications instantiate one in `main()` and pass fields to the runner.
class EvalRunConfig {
  final String runName;
  final int concurrency;
  final int? trialsOverride;
  final EvalRunMode mode;
  final TaskFilter filter;
  final int? rpm;
  final int? tpm;
  final String? recordingDir;
  final bool langfuseEnabled;
  final String? langfuseHost;

  const EvalRunConfig({
    required this.runName,
    this.concurrency = 8,
    this.trialsOverride,
    this.mode = EvalRunMode.replay,
    this.filter = const TaskFilter(),
    this.rpm,
    this.tpm,
    this.recordingDir,
    this.langfuseEnabled = true,
    this.langfuseHost,
  });
}

/// Tiny CLI parser. Avoids pulling in `package:args` to keep deps lean.
///
/// Supported flags:
/// ```
/// --run-name NAME
/// --concurrency N
/// --trials-override N
/// --mode (record|replay|live)
/// --filter-agent A,B,C
/// --filter-bucket A,B,C
/// --filter-task-id A,B,C
/// --rpm N
/// --tpm N
/// --recording-dir PATH
/// --no-langfuse
/// --langfuse-host URL
/// ```
EvalRunConfig parseEvalRunArgs(
  List<String> args, {
  Map<String, String>? env,
  String? defaultRunName,
}) {
  String? runName = defaultRunName;
  var concurrency = 8;
  int? trials;
  var mode = EvalRunMode.replay;
  Set<String>? agents;
  Set<String>? buckets;
  Set<String>? taskIds;
  int? rpm;
  int? tpm;
  String? recordingDir;
  var langfuseEnabled = true;
  String? langfuseHost = env?['LANGFUSE_HOST'];

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String next() {
      if (i + 1 >= args.length) {
        throw ArgumentError('flag $a requires a value');
      }
      return args[++i];
    }

    switch (a) {
      case '--run-name':
        runName = next();
        break;
      case '--concurrency':
        concurrency = int.parse(next());
        break;
      case '--trials-override':
        trials = int.parse(next());
        break;
      case '--mode':
        final v = next();
        mode = EvalRunMode.values.firstWhere((m) => m.name == v);
        break;
      case '--filter-agent':
        agents = next().split(',').map((s) => s.trim()).toSet();
        break;
      case '--filter-bucket':
        buckets = next().split(',').map((s) => s.trim()).toSet();
        break;
      case '--filter-task-id':
        taskIds = next().split(',').map((s) => s.trim()).toSet();
        break;
      case '--rpm':
        rpm = int.parse(next());
        break;
      case '--tpm':
        tpm = int.parse(next());
        break;
      case '--recording-dir':
        recordingDir = next();
        break;
      case '--no-langfuse':
        langfuseEnabled = false;
        break;
      case '--langfuse-host':
        langfuseHost = next();
        break;
      default:
        // Unknown flags are tolerated to allow downstream apps to extend.
        break;
    }
  }

  return EvalRunConfig(
    runName: runName ?? 'run_${DateTime.now().millisecondsSinceEpoch}',
    concurrency: concurrency,
    trialsOverride: trials,
    mode: mode,
    filter: TaskFilter(agents: agents, buckets: buckets, taskIds: taskIds),
    rpm: rpm,
    tpm: tpm,
    recordingDir: recordingDir,
    langfuseEnabled: langfuseEnabled,
    langfuseHost: langfuseHost,
  );
}
