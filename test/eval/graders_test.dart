// ignore_for_file: unused_element_parameter
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';
import 'package:test/test.dart';

import '_helpers.dart';

// ─── Code grader ────────────────────────────────────────────────────────────

class _AllPassGrader extends CodeGrader {
  @override
  String get name => 'all_pass';
  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async => const [
    Assertion(description: 'a', passed: true),
    Assertion(description: 'b', passed: true),
  ];
}

class _PartialGrader extends CodeGrader {
  @override
  String get name => 'partial';

  @override
  double get passThreshold => 0.5; // partial credit at 50%

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async => const [
    Assertion(description: 'half-pass-1', passed: true),
    Assertion(description: 'half-fail', passed: false),
  ];
}

class _AllFailGrader extends CodeGrader {
  @override
  String get name => 'all_fail';
  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async => const [
    Assertion(
      description: 'will fail',
      passed: false,
      actual: 'x',
      expected: 'y',
    ),
  ];
}

class _EmptyAssertionGrader extends CodeGrader {
  @override
  String get name => 'empty';
  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async => const [];
}

// ─── Model grader (LLM-as-judge) ────────────────────────────────────────────

/// Minimal LLM-as-judge grader for testing. Calls the [judgeClient] with
/// a rubric prompt and parses a numeric score from the reply.
class _NumericJudgeGrader extends ModelGrader {
  @override
  final LLMClient judgeClient;
  @override
  final String rubric;
  final ModelConfig modelConfig;
  @override
  final String name;

  _NumericJudgeGrader({
    required this.judgeClient,
    required this.rubric,
    required this.modelConfig,
    this.name = 'numeric_judge',
  });

  @override
  double get passThreshold => 0.7;

  @override
  Future<Score> grade({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final prompt =
        '$rubric\n\nOutcome: ${outcome.environmentState}\n'
        'Reply with one line: SCORE=<float between 0 and 1> or SCORE=Unknown';
    final reply = await judgeClient.generate([
      UserMessage.text(prompt),
    ], modelConfig: modelConfig);
    final text = (reply.textOutput ?? '').trim();
    final m = RegExp(r'SCORE=([0-9]*\.?[0-9]+|Unknown)').firstMatch(text);
    if (m == null) {
      return Score(
        graderName: name,
        value: null,
        passed: null,
        rationale: 'judge reply unparseable: $text',
      );
    }
    final v = m.group(1)!;
    if (v == 'Unknown') {
      return Score(
        graderName: name,
        value: null,
        passed: null,
        rationale: text,
      );
    }
    final value = double.parse(v);
    return Score(
      graderName: name,
      value: value,
      passed: value >= passThreshold,
      rationale: text,
    );
  }
}

// ─── Human grader queue ─────────────────────────────────────────────────────

class _MemoryHumanReviewQueue implements HumanReviewQueue {
  final Map<String, Score> _verdicts = {};
  final List<TrialId> enqueued = [];

  @override
  Future<void> enqueue({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    String? rubric,
    Map<String, dynamic> metadata = const {},
  }) async {
    enqueued.add(trial.id);
  }

  @override
  Future<Score?> fetchVerdict(Trial trial) async =>
      _verdicts[trial.id.toString()];

  void postVerdict(Trial trial, Score score) {
    _verdicts[trial.id.toString()] = score;
  }
}

class _StubHumanGrader extends HumanGrader {
  @override
  final HumanReviewQueue queue;
  @override
  final String name;
  _StubHumanGrader({required this.queue, this.name = 'human'});
}

// ─── Helpers ────────────────────────────────────────────────────────────────

EvalContext _ctx() => EvalContext(
  clock: const SystemEvalClock(),
  llmClient: FakeLLMClient([textReply('unused')]),
  controller: AgentController(),
);

Future<Score> _grade(Grader g) async {
  final ctx = _ctx();
  return g.grade(
    trial: makeTrial(runName: 'r', suiteName: 's', taskId: 't'),
    transcript: emptyTranscript(),
    outcome: const Outcome(environmentState: {'k': 'v'}),
    context: ctx,
  );
}

void main() {
  group('CodeGrader', () {
    test('all-pass assertions → value=1.0, passed=true', () async {
      final s = await _grade(_AllPassGrader());
      expect(s.value, 1.0);
      expect(s.passed, true);
      expect(s.assertions, hasLength(2));
      expect(s.rationale, isNull);
    });

    test(
      'all-fail assertions → value=0.0, passed=false, rationale present',
      () async {
        final s = await _grade(_AllFailGrader());
        expect(s.value, 0.0);
        expect(s.passed, false);
        expect(s.rationale, contains('will fail'));
        expect(s.assertions.first.actual, 'x');
        expect(s.assertions.first.expected, 'y');
      },
    );

    test(
      'partial assertions with passThreshold=0.5 → value=0.5, passed=true',
      () async {
        final s = await _grade(_PartialGrader());
        expect(s.value, closeTo(0.5, 1e-9));
        expect(s.passed, true);
        // Even when crossing threshold, rationale lists the failed assertion.
        expect(s.rationale, contains('half-fail'));
      },
    );

    test(
      'empty assertions → value=0.0, passed=false (default threshold 1.0)',
      () async {
        final s = await _grade(_EmptyAssertionGrader());
        expect(s.value, 0.0);
        expect(s.passed, false);
      },
    );

    test('Score round-trips through JSON', () async {
      final s = await _grade(_AllFailGrader());
      final j = s.toJson();
      final s2 = Score.fromJson(j);
      expect(s2.graderName, s.graderName);
      expect(s2.value, s.value);
      expect(s2.passed, s.passed);
      expect(s2.assertions.length, s.assertions.length);
      expect(s2.assertions.first.actual, s.assertions.first.actual);
    });
  });

  group('ModelGrader (LLM-as-judge)', () {
    test('parses SCORE=0.85 as a passing score', () async {
      final client = FakeLLMClient([textReply('Looks good. SCORE=0.85')]);
      final g = _NumericJudgeGrader(
        judgeClient: client,
        rubric: 'Rate quality 0–1.',
        modelConfig: ModelConfig(model: 'judge'),
      );
      final s = await _grade(g);
      expect(s.value, closeTo(0.85, 1e-9));
      expect(s.passed, true);
      expect(client.generateCalls, 1);
    });

    test('parses SCORE=0.3 as failing under threshold 0.7', () async {
      final client = FakeLLMClient([textReply('Eh. SCORE=0.3')]);
      final g = _NumericJudgeGrader(
        judgeClient: client,
        rubric: 'Rate quality 0–1.',
        modelConfig: ModelConfig(model: 'judge'),
      );
      final s = await _grade(g);
      expect(s.value, closeTo(0.3, 1e-9));
      expect(s.passed, false);
    });

    test('returns null score when judge replies "Unknown" '
        '(Anthropic Step 5 escape hatch)', () async {
      final client = FakeLLMClient([
        textReply('Cannot evaluate. SCORE=Unknown'),
      ]);
      final g = _NumericJudgeGrader(
        judgeClient: client,
        rubric: 'Rate quality 0–1.',
        modelConfig: ModelConfig(model: 'judge'),
      );
      final s = await _grade(g);
      expect(s.value, isNull);
      expect(s.passed, isNull);
      expect(s.rationale, contains('Unknown'));
    });

    test('returns null score on unparseable judge output', () async {
      final client = FakeLLMClient([textReply('lalala no score here')]);
      final g = _NumericJudgeGrader(
        judgeClient: client,
        rubric: '',
        modelConfig: ModelConfig(model: 'judge'),
      );
      final s = await _grade(g);
      expect(s.value, isNull);
      expect(s.passed, isNull);
      expect(s.rationale, contains('unparseable'));
    });

    test('reports kind = model', () {
      final g = _NumericJudgeGrader(
        judgeClient: FakeLLMClient([textReply('SCORE=1')]),
        rubric: '',
        modelConfig: ModelConfig(model: 'judge'),
      );
      expect(g.kind, GraderKind.model);
    });
  });

  group('HumanGrader', () {
    test('returns pending null score when no verdict yet', () async {
      final q = _MemoryHumanReviewQueue();
      final g = _StubHumanGrader(queue: q);
      final s = await _grade(g);
      expect(s.value, isNull);
      expect(s.passed, isNull);
      expect(s.rationale, 'pending human review');
      expect(q.enqueued, hasLength(1));
    });

    test('returns posted verdict on next grade call', () async {
      final q = _MemoryHumanReviewQueue();
      final g = _StubHumanGrader(queue: q);
      final t = makeTrial(runName: 'r', suiteName: 's', taskId: 't');

      // First call enqueues and returns pending
      final pending = await g.grade(
        trial: t,
        transcript: emptyTranscript(),
        outcome: const Outcome(environmentState: {}),
        context: _ctx(),
      );
      expect(pending.value, isNull);

      // Reviewer posts a verdict
      q.postVerdict(t, okScore('human', value: 0.9));

      // Second call gets the verdict
      final final_ = await g.grade(
        trial: t,
        transcript: emptyTranscript(),
        outcome: const Outcome(environmentState: {}),
        context: _ctx(),
      );
      expect(final_.value, 0.9);
      expect(final_.passed, true);
      expect(q.enqueued, hasLength(2)); // enqueue is unconditional
    });

    test('reports kind = human', () {
      final g = _StubHumanGrader(queue: _MemoryHumanReviewQueue());
      expect(g.kind, GraderKind.human);
    });
  });
}
