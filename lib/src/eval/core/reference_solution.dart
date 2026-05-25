import 'transcript.dart';

/// How the reference solution was produced.
enum ReferenceSolutionSource { manual, captured, synthesized }

/// Anthropic Step 2: a known working solution that passes all graders.
/// Useful for proving a task is solvable and that graders are configured
/// correctly.
class ReferenceSolution {
  /// Expected environment state. Schema mirrors [Outcome.environmentState].
  final Map<String, dynamic>? expectedOutcome;

  /// Optional sample transcript captured from a known-good run.
  final Transcript? sampleTranscript;

  /// Provenance of this reference solution.
  final ReferenceSolutionSource source;

  const ReferenceSolution({
    this.expectedOutcome,
    this.sampleTranscript,
    required this.source,
  });

  Map<String, dynamic> toJson() => {
    if (expectedOutcome != null) 'expectedOutcome': expectedOutcome,
    if (sampleTranscript != null)
      'sampleTranscript': sampleTranscript!.toJson(),
    'source': source.name,
  };

  factory ReferenceSolution.fromJson(Map<String, dynamic> json) {
    return ReferenceSolution(
      expectedOutcome: json['expectedOutcome'] as Map<String, dynamic>?,
      sampleTranscript: json['sampleTranscript'] == null
          ? null
          : Transcript.fromJson(
              json['sampleTranscript'] as Map<String, dynamic>,
            ),
      source: ReferenceSolutionSource.values.firstWhere(
        (e) => e.name == json['source'],
      ),
    );
  }
}
