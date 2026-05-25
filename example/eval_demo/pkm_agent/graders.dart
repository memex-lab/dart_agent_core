import 'package:dart_agent_core/eval.dart';

/// Verifies the happy-path PKM organization:
/// 1. Wrote at least one file under [expectedBuckets] (e.g. "Areas/")
/// 2. The fact_id appears inside one of those files
/// 3. update_card_insight was called with the same fact_id
/// 4. Optional substring(s) appear in the written file content
class PkmOrganizedGrader extends CodeGrader {
  /// The fact_id from the user input.
  final String expectedFactId;

  /// Acceptable PARA buckets for THIS task. Eg ['Areas/'] for a
  /// long-term-responsibility input, ['Resources/'] for a reading note.
  final List<String> expectedBuckets;

  /// Substrings that must appear (case-insensitive) in at least one of
  /// the written files.
  final List<String> mustContainSubstrings;

  PkmOrganizedGrader({
    required this.expectedFactId,
    required this.expectedBuckets,
    this.mustContainSubstrings = const [],
  });

  @override
  String get name => 'pkm_organized';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final state = outcome.environmentState;
    final wrote =
        (state['wrote_files'] as List?)?.cast<String>() ?? const <String>[];
    final factIdsInFiles =
        (state['fact_ids_in_files'] as List?)?.cast<String>() ?? const [];
    final updatedInsight = state['updated_insight'] == true;
    final insightFactId = state['insight_for_fact_id'] as String?;
    final skipped = state['skipped'] == true;

    final assertions = <Assertion>[
      Assertion(
        description: 'agent did not skip and wrote at least one file',
        passed: !skipped && wrote.isNotEmpty,
        actual: 'skipped=$skipped wrote=$wrote',
        expected: 'skipped=false wrote.length>=1',
      ),
      Assertion(
        description: 'wrote into one of ${expectedBuckets.join(" / ")}',
        passed: wrote.any((p) => expectedBuckets.any(p.startsWith)),
        actual: '$wrote',
        expected: 'starts-with one of ${expectedBuckets.join(",")}',
      ),
      Assertion(
        description: 'fact_id $expectedFactId is referenced in the file body',
        passed: factIdsInFiles.contains(expectedFactId),
        actual: '$factIdsInFiles',
        expected: 'contains $expectedFactId',
      ),
      Assertion(
        description: 'update_card_insight was called for $expectedFactId',
        passed: updatedInsight && insightFactId == expectedFactId,
        actual: 'updated=$updatedInsight insight_fact_id=$insightFactId',
        expected: 'updated=true insight_fact_id=$expectedFactId',
      ),
    ];

    if (mustContainSubstrings.isNotEmpty) {
      final diff = outcome.workspaceDiff;
      final blob = (diff?.contentSnippets.values.join('\n') ?? '')
          .toLowerCase();
      for (final needle in mustContainSubstrings) {
        assertions.add(
          Assertion(
            description: 'PKM file content contains "$needle"',
            passed: blob.contains(needle.toLowerCase()),
            actual: blob.length > 120 ? '${blob.substring(0, 120)}…' : blob,
            expected: 'contains "$needle"',
          ),
        );
      }
    }

    return assertions;
  }
}

/// Verifies the negative path: agent should call skip_pkm_organization
/// AND must not write any PKM files.
class PkmSkippedGrader extends CodeGrader {
  @override
  String get name => 'pkm_skipped';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final state = outcome.environmentState;
    final wrote =
        (state['wrote_files'] as List?)?.cast<String>() ?? const <String>[];
    final skipped = state['skipped'] == true;
    final updated = state['updated_insight'] == true;

    return [
      Assertion(
        description: 'skip_pkm_organization was called',
        passed: skipped,
        actual: 'skipped=$skipped',
        expected: 'skipped=true',
      ),
      Assertion(
        description: 'no PKM files were written',
        passed: wrote.isEmpty,
        actual: '$wrote',
        expected: '[]',
      ),
      Assertion(
        description: 'update_card_insight was NOT called',
        passed: !updated,
        actual: 'updated_insight=$updated',
        expected: 'updated_insight=false',
      ),
    ];
  }
}

/// Verifies that when a relevant file already existed, the agent
/// chose to read it before writing (i.e. did not blindly overwrite).
class PkmReadBeforeWriteGrader extends CodeGrader {
  @override
  String get name => 'read_before_write';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    int firstWriteAt = -1;
    int firstReadAt = -1;
    for (var i = 0; i < transcript.toolCalls.length; i++) {
      final n = transcript.toolCalls[i].toolName;
      if (n == 'read_file' && firstReadAt < 0) firstReadAt = i;
      if (n == 'write_file' && firstWriteAt < 0) firstWriteAt = i;
    }
    final ok =
        firstReadAt >= 0 && (firstWriteAt < 0 || firstReadAt < firstWriteAt);
    return [
      Assertion(
        description:
            'agent called read_file before its first write_file (when '
            'a fixture file existed)',
        passed: ok,
        actual: 'read_at=$firstReadAt write_at=$firstWriteAt',
        expected: 'read_at < write_at (or no write at all)',
      ),
    ];
  }
}
