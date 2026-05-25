import 'package:dart_agent_core/eval.dart';

import 'graders.dart';

const _agentName = 'card_agent_demo';

String _userPrompt({
  required String factId,
  required String text,
  String? capturedAt,
  String? location,
  List<String> assets = const [],
}) {
  final b = StringBuffer();
  b.writeln('Process the following user input into a timeline card.');
  b.writeln();
  b.writeln('fact_id: $factId');
  if (capturedAt != null) b.writeln('captured_at: $capturedAt');
  if (location != null) b.writeln('location: $location');
  if (assets.isNotEmpty) {
    b.writeln('assets:');
    for (final a in assets) {
      b.writeln('  - $a');
    }
  }
  b.writeln();
  b.writeln('text:');
  b.writeln(text);
  return b.toString();
}

/// Positive case 1: a clearly-event input. We expect template "event"
/// and at least one of the {meeting, work} tags.
class _EventCardTask implements EvalTask {
  @override
  String get id => 'card_event_meeting';
  @override
  String get description =>
      'Calendar-style input: should pick "event" template.';
  @override
  Map<String, dynamic> get input => {
    'prompt': _userPrompt(
      factId: 'fact_001',
      text:
          'Sync with Alice tomorrow 3pm to review the Q3 launch plan. '
          'Conference room B.',
      capturedAt: '2025-09-01T10:30:00+08:00',
      location: 'Office',
    ),
  };
  @override
  ReferenceSolution? get referenceSolution => const ReferenceSolution(
    expectedOutcome: {
      'card_saved': true,
      'declined': false,
      'card_template_id': 'event',
    },
    source: ReferenceSolutionSource.manual,
  );
  @override
  Map<String, String> get metadata => const {
    'failure_bucket': 'template_event',
    'difficulty': 'easy',
  };
  @override
  List<Grader> get graders => [
    CardSavedGrader(
      expectedFactId: 'fact_001',
      expectedTemplateIds: const ['event'],
      expectedTagCandidates: const ['meeting', 'work'],
      mustContainSubstrings: const ['Alice'],
    ),
    CalledGetCardMetadataGrader(),
  ];
  @override
  int get trialsPerRun => 2;
  @override
  Duration? get timeout => const Duration(minutes: 2);
}

/// Positive case 2: actionable item. Expect "task" template, priority
/// keyword should land in the fields.
class _TaskCardTask implements EvalTask {
  @override
  String get id => 'card_task_followup';
  @override
  String get description => 'Actionable to-do: should pick "task" template.';
  @override
  Map<String, dynamic> get input => {
    'prompt': _userPrompt(
      factId: 'fact_002',
      text:
          'Need to send the contract draft to the legal team by '
          'Friday. High priority.',
      capturedAt: '2025-09-01T11:00:00+08:00',
    ),
  };
  @override
  ReferenceSolution? get referenceSolution => const ReferenceSolution(
    expectedOutcome: {'card_saved': true, 'card_template_id': 'task'},
    source: ReferenceSolutionSource.manual,
  );
  @override
  Map<String, String> get metadata => const {
    'failure_bucket': 'template_task',
    'difficulty': 'medium',
  };
  @override
  List<Grader> get graders => [
    CardSavedGrader(
      expectedFactId: 'fact_002',
      expectedTemplateIds: const ['task'],
      mustContainSubstrings: const ['contract'],
    ),
  ];
  @override
  int get trialsPerRun => 2;
  @override
  Duration? get timeout => const Duration(minutes: 2);
}

/// Positive case 3: free-form reflection. Expect "note" template.
class _NoteCardTask implements EvalTask {
  @override
  String get id => 'card_note_reflection';
  @override
  String get description =>
      'Free-form reflection: should pick "note" template.';
  @override
  Map<String, dynamic> get input => {
    'prompt': _userPrompt(
      factId: 'fact_003',
      text:
          'Realized I do my best deep work in the morning. Should '
          'protect that time on my calendar going forward.',
    ),
  };
  @override
  Map<String, String> get metadata => const {
    'failure_bucket': 'template_note',
    'difficulty': 'easy',
  };
  @override
  ReferenceSolution? get referenceSolution => const ReferenceSolution(
    expectedOutcome: {'card_saved': true, 'card_template_id': 'note'},
    source: ReferenceSolutionSource.manual,
  );
  @override
  List<Grader> get graders => [
    CardSavedGrader(
      expectedFactId: 'fact_003',
      expectedTemplateIds: const ['note'],
      mustContainSubstrings: const ['morning'],
    ),
  ];
  @override
  int get trialsPerRun => 2;
  @override
  Duration? get timeout => const Duration(minutes: 2);
}

/// Negative case: garbage input. Agent should call `decline`.
class _DeclineCardTask implements EvalTask {
  @override
  String get id => 'card_decline_garbage';
  @override
  String get description => 'Empty / garbage input: should be declined.';
  @override
  Map<String, dynamic> get input => {
    'prompt': _userPrompt(factId: 'fact_004', text: 'test 123'),
  };
  @override
  Map<String, String> get metadata => const {
    'failure_bucket': 'decline_garbage',
    'difficulty': 'easy',
  };
  @override
  ReferenceSolution? get referenceSolution => const ReferenceSolution(
    expectedOutcome: {'card_saved': false, 'declined': true},
    source: ReferenceSolutionSource.manual,
  );
  @override
  List<Grader> get graders => [DeclineCardGrader()];
  @override
  int get trialsPerRun => 2;
  @override
  Duration? get timeout => const Duration(minutes: 2);
}

EvalSuite buildCardAgentDemoSuite() {
  return EvalSuite(
    name: 'card_agent_demo',
    agentName: _agentName,
    kind: SuiteKind.mixed,
    tasks: [
      _EventCardTask(),
      _TaskCardTask(),
      _NoteCardTask(),
      _DeclineCardTask(),
    ],
    requireReferenceSolution: true,
  );
}
