/// One specific check inside a [Score]. Holds enough detail that a human can
/// understand why it passed or failed without re-running the trial.
class Assertion {
  final String description;
  final bool passed;

  /// Observed value (stringified for human readability).
  final String? actual;

  /// Expected value.
  final String? expected;

  const Assertion({
    required this.description,
    required this.passed,
    this.actual,
    this.expected,
  });

  Map<String, dynamic> toJson() => {
    'description': description,
    'passed': passed,
    if (actual != null) 'actual': actual,
    if (expected != null) 'expected': expected,
  };

  factory Assertion.fromJson(Map<String, dynamic> json) {
    return Assertion(
      description: json['description'] as String,
      passed: json['passed'] as bool,
      actual: json['actual'] as String?,
      expected: json['expected'] as String?,
    );
  }
}

/// The output of a [Grader] for one trial.
///
/// Anthropic Step 5: graders should support partial credit (`value` is a
/// double in [0.0, 1.0]) and must explain failures clearly (`rationale`).
class Score {
  /// Stable name of the grader that produced this score.
  final String graderName;

  /// 0.0 .. 1.0 with partial credit. `null` means the grader could not
  /// evaluate (e.g. an LLM judge returned "Unknown"). `null` scores are
  /// reported separately and do not contribute to averages.
  final double? value;

  /// Whether [value] crosses the grader's pass threshold. `null` if [value]
  /// is null. Aggregated by [EvalRunReport] into pass@k and pass^k.
  final bool? passed;

  /// Sub-checks that contributed to [value].
  final List<Assertion> assertions;

  /// Human-readable explanation. Required when `passed == false` or
  /// `value == null`. Anthropic Step 5: "failures should seem fair".
  final String? rationale;

  /// Free-form metadata (e.g. judge response, diff details).
  final Map<String, dynamic> metadata;

  const Score({
    required this.graderName,
    required this.value,
    this.passed,
    this.assertions = const [],
    this.rationale,
    this.metadata = const {},
  });

  Map<String, dynamic> toJson() => {
    'graderName': graderName,
    'value': value,
    if (passed != null) 'passed': passed,
    'assertions': assertions.map((a) => a.toJson()).toList(),
    if (rationale != null) 'rationale': rationale,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  factory Score.fromJson(Map<String, dynamic> json) {
    return Score(
      graderName: json['graderName'] as String,
      value: (json['value'] as num?)?.toDouble(),
      passed: json['passed'] as bool?,
      assertions: ((json['assertions'] as List?) ?? [])
          .map((a) => Assertion.fromJson(a as Map<String, dynamic>))
          .toList(),
      rationale: json['rationale'] as String?,
      metadata:
          ((json['metadata'] as Map?)?.cast<String, dynamic>()) ?? const {},
    );
  }
}
