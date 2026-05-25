import 'package:dart_agent_core/eval.dart';

/// Confirms that a timeline card was saved and that the basic shape
/// matches what the task asks for: same fact_id, expected template,
/// title is non-empty and short, and (optionally) at least one of the
/// expected tag candidates appears.
class CardSavedGrader extends CodeGrader {
  /// fact_id that the task input carries — must end up on the card.
  final String expectedFactId;

  /// The template the agent is expected to pick. Multiple values mean
  /// "any of these is acceptable" (e.g. "note" OR "task" both fine).
  final List<String> expectedTemplateIds;

  /// Optional set of acceptable tags. The card must include at least
  /// one if this list is non-empty.
  final List<String> expectedTagCandidates;

  /// Optional substrings that must all appear somewhere in the card's
  /// title or fields (case-insensitive).
  final List<String> mustContainSubstrings;

  /// Maximum allowed title length.
  final int maxTitleLength;

  CardSavedGrader({
    required this.expectedFactId,
    required this.expectedTemplateIds,
    this.expectedTagCandidates = const [],
    this.mustContainSubstrings = const [],
    this.maxTitleLength = 30,
  });

  @override
  String get name => 'card_saved';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final state = outcome.environmentState;
    final saved = state['card_saved'] == true;
    final declined = state['declined'] == true;
    final factId = state['fact_id'] as String?;
    final templateId = state['card_template_id'] as String?;
    final title = state['card_title'] as String?;
    final tags =
        (state['card_tags'] as List?)?.cast<String>() ?? const <String>[];
    final fields =
        (state['card_fields'] as Map?)?.cast<String, dynamic>() ?? const {};

    final assertions = <Assertion>[
      Assertion(
        description: 'agent saved a card and did not decline',
        passed: saved && !declined,
        actual: 'saved=$saved declined=$declined',
        expected: 'saved=true declined=false',
      ),
      Assertion(
        description: 'fact_id on the card matches the input fact_id',
        passed: factId == expectedFactId,
        actual: '$factId',
        expected: expectedFactId,
      ),
      Assertion(
        description: 'template_id is one of ${expectedTemplateIds.join(" / ")}',
        passed: templateId != null && expectedTemplateIds.contains(templateId),
        actual: '$templateId',
        expected: expectedTemplateIds.join('|'),
      ),
      Assertion(
        description: 'title is non-empty and ≤ $maxTitleLength chars',
        passed:
            title != null &&
            title.trim().isNotEmpty &&
            title.length <= maxTitleLength,
        actual: 'title="${title ?? ''}" len=${title?.length ?? 0}',
        expected: '0 < len ≤ $maxTitleLength',
      ),
    ];

    if (expectedTagCandidates.isNotEmpty) {
      final lowerTags = tags.map((t) => t.toLowerCase()).toSet();
      final lowerCandidates = expectedTagCandidates
          .map((t) => t.toLowerCase())
          .toSet();
      final overlap = lowerTags.intersection(lowerCandidates);
      assertions.add(
        Assertion(
          description:
              'at least one tag from {${expectedTagCandidates.join(", ")}} '
              'is present',
          passed: overlap.isNotEmpty,
          actual: 'tags=$tags',
          expected: 'overlap with ${expectedTagCandidates.join(",")}',
        ),
      );
    }

    if (mustContainSubstrings.isNotEmpty) {
      final blob = '${title ?? ''} ${fields.values.join(" ")}'.toLowerCase();
      for (final needle in mustContainSubstrings) {
        assertions.add(
          Assertion(
            description: 'card text contains "$needle"',
            passed: blob.contains(needle.toLowerCase()),
            actual: blob.length > 100 ? '${blob.substring(0, 100)}…' : blob,
            expected: 'contains "$needle"',
          ),
        );
      }
    }

    return assertions;
  }
}

/// Grader for negative cases: the input should NOT become a card.
/// Verifies the agent called `decline` and did not save anything.
class DeclineCardGrader extends CodeGrader {
  @override
  String get name => 'declined_garbage_input';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final state = outcome.environmentState;
    final saved = state['card_saved'] == true;
    final declined = state['declined'] == true;
    return [
      Assertion(
        description: 'agent declined and did not save a card',
        passed: declined && !saved,
        actual: 'saved=$saved declined=$declined',
        expected: 'saved=false declined=true',
      ),
    ];
  }
}

/// Verifies that the agent did NOT skip the metadata-discovery step.
/// The system prompt says to call `get_card_metadata` once. This grader
/// checks the transcript directly for that tool call.
class CalledGetCardMetadataGrader extends CodeGrader {
  @override
  String get name => 'called_get_card_metadata';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final n = transcript.toolCalls
        .where((tc) => tc.toolName == 'get_card_metadata')
        .length;
    return [
      Assertion(
        description: 'agent called get_card_metadata at least once',
        passed: n >= 1,
        actual: '$n calls',
        expected: '>= 1',
      ),
    ];
  }
}
