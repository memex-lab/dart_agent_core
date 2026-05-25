import 'package:dart_agent_core/eval.dart';

/// Verifies that the agent submitted a numeric answer matching [expected].
/// Tolerant of small floating-point error.
class AnswerCorrectnessGrader extends CodeGrader {
  /// Expected numeric answer for this task.
  final num expected;

  /// Maximum absolute error allowed when comparing doubles.
  final double tolerance;

  AnswerCorrectnessGrader({required this.expected, this.tolerance = 1e-9});

  @override
  String get name => 'answer_correctness';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final assertions = <Assertion>[];
    final state = outcome.environmentState;
    final submitted = state['submitted'] == true;
    final declined = state['declined'] == true;

    assertions.add(
      Assertion(
        description: 'agent submitted an answer (and did not decline)',
        passed: submitted && !declined,
        actual: 'submitted=$submitted declined=$declined',
        expected: 'submitted=true declined=false',
      ),
    );

    if (!submitted) {
      // No answer to check — fail fast on the second assertion too.
      assertions.add(
        Assertion(
          description: 'submitted answer equals $expected within tolerance',
          passed: false,
          actual: 'no answer',
          expected: '$expected',
        ),
      );
      return assertions;
    }

    final raw = state['answer'];
    final actualNum = raw is num ? raw.toDouble() : double.tryParse('$raw');
    final ok =
        actualNum != null &&
        (actualNum - expected.toDouble()).abs() <= tolerance;

    assertions.add(
      Assertion(
        description: 'submitted answer equals $expected within tolerance',
        passed: ok,
        actual: '$raw',
        expected: '$expected',
      ),
    );

    return assertions;
  }
}

/// Verifies that the agent declined (did not submit a numeric answer) for
/// off-topic prompts.
class DeclineGrader extends CodeGrader {
  @override
  String get name => 'declined_off_topic';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final state = outcome.environmentState;
    final submitted = state['submitted'] == true;
    final declined = state['declined'] == true;

    return [
      Assertion(
        description: 'agent declined the off-topic prompt',
        passed: declined && !submitted,
        actual: 'submitted=$submitted declined=$declined',
        expected: 'submitted=false declined=true',
      ),
    ];
  }
}

/// Verifies that the agent actually used at least [minArithmeticCalls]
/// arithmetic tools and did not "compute mentally".
class ToolUsageGrader extends CodeGrader {
  /// Minimum number of arithmetic tool calls expected.
  final int minArithmeticCalls;

  ToolUsageGrader({this.minArithmeticCalls = 1});

  static const _arithmetic = {'add', 'subtract', 'multiply', 'divide'};

  @override
  String get name => 'used_arithmetic_tools';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final calls = transcript.toolCalls
        .where((tc) => _arithmetic.contains(tc.toolName))
        .length;

    return [
      Assertion(
        description: 'agent invoked >= $minArithmeticCalls arithmetic tool(s)',
        passed: calls >= minArithmeticCalls,
        actual: '$calls calls',
        expected: '>= $minArithmeticCalls',
      ),
    ];
  }
}
