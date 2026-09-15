import '../graders/score.dart';
import 'outcome.dart';
import 'transcript.dart';
import 'trial.dart';

/// All artifacts produced by one trial.
class TrialResult {
  final Trial trial;
  final Transcript transcript;
  final Outcome outcome;
  final List<Score> scores;

  const TrialResult({
    required this.trial,
    required this.transcript,
    required this.outcome,
    required this.scores,
  });

  /// True if every score (excluding null-valued ones) reports passed=true.
  /// Null-valued scores (e.g. judge returned Unknown) are ignored.
  /// Returns false when no grader decided (all scores null / empty list).
  bool get allGradersPassed => scoresIndicatePass(scores);

  /// Whether [scores] indicate a passing trial.
  ///
  /// Same rules as [allGradersPassed]: ignore `passed == null`, and treat
  /// "no grader decided" as not passed.
  static bool scoresIndicatePass(Iterable<Score> scores) {
    final decided = scores.where((s) => s.passed != null);
    if (decided.isEmpty) return false;
    return decided.every((s) => s.passed == true);
  }

  /// Mean of non-null score values. Returns null if all scores are null.
  double? get meanScoreValue {
    final values = scores.map((s) => s.value).whereType<double>().toList();
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  Map<String, dynamic> toJson() => {
    'trial': trial.toJson(),
    'transcript': transcript.toJson(),
    'outcome': outcome.toJson(),
    'scores': scores.map((s) => s.toJson()).toList(),
  };
}
