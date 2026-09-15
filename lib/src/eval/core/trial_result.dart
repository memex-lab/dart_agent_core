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

  /// True when this trial counts as a metric pass: execution completed
  /// ([TrialStatus.passed] or [TrialStatus.failed]) and every non-null score
  /// reports passed=true.
  ///
  /// [TrialStatus.errored], [TrialStatus.timedOut], and [TrialStatus.skipped]
  /// never count as passes, even if graders would accept a placeholder outcome.
  /// Null-valued scores (e.g. judge returned Unknown) are ignored.
  /// Returns false when no grader decided (all scores null / empty list).
  bool get allGradersPassed {
    switch (trial.status) {
      case TrialStatus.errored:
      case TrialStatus.timedOut:
      case TrialStatus.skipped:
        return false;
      case TrialStatus.passed:
      case TrialStatus.failed:
        break;
    }
    return scoresIndicatePass(scores);
  }

  /// Whether the scores alone indicate a pass, independent of trial status.
  /// Ignores `passed == null`; no decided scores means not passed.
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
