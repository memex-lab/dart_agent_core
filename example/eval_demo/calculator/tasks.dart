import 'package:dart_agent_core/eval.dart';

import 'graders.dart';

const _agentName = 'calculator_demo_agent';

/// Single-step arithmetic. Tests that the agent uses at least one tool
/// call and produces the correct numeric answer.
class _SimpleAdditionTask implements EvalTask {
  @override
  String get id => 'task_simple_addition';

  @override
  String get description =>
      'Single-step addition: should use the add tool and answer 5.';

  @override
  Map<String, dynamic> get input => {'prompt': 'What is 2 + 3?'};

  @override
  ReferenceSolution? get referenceSolution => const ReferenceSolution(
    expectedOutcome: {'submitted': true, 'declined': false, 'answer': '5'},
    source: ReferenceSolutionSource.manual,
  );

  @override
  Map<String, String> get metadata => const {
    'failure_bucket': 'arithmetic_basic',
    'difficulty': 'easy',
  };

  @override
  List<Grader> get graders => [
    AnswerCorrectnessGrader(expected: 5),
    ToolUsageGrader(minArithmeticCalls: 1),
  ];

  @override
  int get trialsPerRun => 2;

  @override
  Duration? get timeout => const Duration(minutes: 2);
}

/// Multi-step arithmetic. Requires the agent to compose tool calls
/// (multiply then subtract). Expected answer: (12*7) - 18 = 66.
class _MultiStepTask implements EvalTask {
  @override
  String get id => 'task_multi_step';

  @override
  String get description =>
      'Multi-step arithmetic: should chain at least two tool calls.';

  @override
  Map<String, dynamic> get input => {'prompt': 'What is (12 * 7) - 18?'};

  @override
  ReferenceSolution? get referenceSolution => const ReferenceSolution(
    expectedOutcome: {'submitted': true, 'declined': false, 'answer': '66'},
    source: ReferenceSolutionSource.manual,
  );

  @override
  Map<String, String> get metadata => const {
    'failure_bucket': 'arithmetic_compose',
    'difficulty': 'medium',
  };

  @override
  List<Grader> get graders => [
    AnswerCorrectnessGrader(expected: 66),
    ToolUsageGrader(minArithmeticCalls: 2),
  ];

  @override
  int get trialsPerRun => 2;

  @override
  Duration? get timeout => const Duration(minutes: 2);
}

/// Negative case: prompt is not arithmetic. Agent MUST decline rather than
/// fabricate a numeric answer. Anthropic Step 3: balanced suites need both
/// positive and negative cases.
class _OffTopicTask implements EvalTask {
  @override
  String get id => 'task_off_topic';

  @override
  String get description =>
      'Off-topic prompt: agent should decline and not submit an answer.';

  @override
  Map<String, dynamic> get input => {
    'prompt': 'What should I eat for dinner tomorrow?',
  };

  @override
  ReferenceSolution? get referenceSolution => const ReferenceSolution(
    expectedOutcome: {'submitted': false, 'declined': true},
    source: ReferenceSolutionSource.manual,
  );

  @override
  Map<String, String> get metadata => const {
    'failure_bucket': 'off_topic_refusal',
    'difficulty': 'easy',
  };

  @override
  List<Grader> get graders => [DeclineGrader()];

  @override
  int get trialsPerRun => 2;

  @override
  Duration? get timeout => const Duration(minutes: 2);
}

/// The full demo suite. Mixed kind because it covers both basic capability
/// (arithmetic) and a refusal case.
EvalSuite buildCalculatorDemoSuite() {
  return EvalSuite(
    name: 'calculator_demo',
    agentName: _agentName,
    kind: SuiteKind.mixed,
    tasks: [_SimpleAdditionTask(), _MultiStepTask(), _OffTopicTask()],
    requireReferenceSolution: true,
  );
}
