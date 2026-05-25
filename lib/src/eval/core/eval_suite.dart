import 'eval_task.dart';

/// Anthropic: capability evals start at low pass rates and improve over
/// time; regression evals stay near 100% and any decline is a red flag.
enum SuiteKind {
  /// "What can this agent do well?" Saturation triggers a graduation
  /// suggestion (move stable tasks into a regression suite).
  capability,

  /// "Does the agent still handle all the tasks it used to?"
  regression,

  /// Mixed-purpose suite without a strong type contract.
  mixed,
}

/// Anthropic: a collection of tasks measuring specific capabilities or
/// behaviors. Tasks in a suite typically share a broad goal.
class EvalSuite {
  final String name;

  /// The agent these tasks are aimed at, e.g. `card_agent` /
  /// `pkm_agent`. Drives routing to the right [AgentHarnessFactory] and
  /// is the natural unit for filtering across multi-suite runs.
  ///
  /// In rare "cross-agent pipeline" suites where different tasks would
  /// hit different agents, leave this as the pipeline name (e.g.
  /// `card_to_pkm_pipeline`) and let your harness factory dispatch
  /// internally based on `task.metadata`.
  final String agentName;

  final SuiteKind kind;
  final List<EvalTask> tasks;

  /// If true, every task must declare a [referenceSolution]. Strongly
  /// recommended for capability suites.
  final bool requireReferenceSolution;

  /// If a task's mean score across its non-null graders meets or exceeds
  /// this threshold, the task is considered "passed" for this suite. The
  /// default is 1.0 (binary). Lower values let suites accept partial
  /// credit when grading multi-component tasks.
  final double taskPassThreshold;

  const EvalSuite({
    required this.name,
    required this.agentName,
    required this.kind,
    required this.tasks,
    this.requireReferenceSolution = false,
    this.taskPassThreshold = 1.0,
  });

  /// Validates the suite at construction time: ids unique, reference
  /// solutions present if required. Returns the list of problems (empty
  /// if valid).
  List<String> validate() {
    final problems = <String>[];
    final seen = <String>{};
    for (final t in tasks) {
      if (!seen.add(t.id)) {
        problems.add('duplicate task id "${t.id}"');
      }
      if (t.graders.isEmpty) {
        problems.add('task "${t.id}" has no graders');
      }
      if (requireReferenceSolution && t.referenceSolution == null) {
        problems.add('task "${t.id}" missing referenceSolution');
      }
      if (t.trialsPerRun <= 0) {
        problems.add('task "${t.id}" has trialsPerRun <= 0');
      }
    }
    return problems;
  }
}
