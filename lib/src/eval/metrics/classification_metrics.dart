/// Precision/Recall/F1 for binary classification tasks (e.g. Memory Agent).
class ClassificationMetrics {
  final int truePositives;
  final int falsePositives;
  final int trueNegatives;
  final int falseNegatives;

  const ClassificationMetrics({
    required this.truePositives,
    required this.falsePositives,
    required this.trueNegatives,
    required this.falseNegatives,
  });

  double get precision {
    final denom = truePositives + falsePositives;
    if (denom == 0) return 0.0;
    return truePositives / denom;
  }

  double get recall {
    final denom = truePositives + falseNegatives;
    if (denom == 0) return 0.0;
    return truePositives / denom;
  }

  double get f1 {
    final p = precision;
    final r = recall;
    if (p + r == 0) return 0.0;
    return 2 * p * r / (p + r);
  }

  double get accuracy {
    final total =
        truePositives + falsePositives + trueNegatives + falseNegatives;
    if (total == 0) return 0.0;
    return (truePositives + trueNegatives) / total;
  }

  Map<String, dynamic> toJson() => {
    'truePositives': truePositives,
    'falsePositives': falsePositives,
    'trueNegatives': trueNegatives,
    'falseNegatives': falseNegatives,
    'precision': precision,
    'recall': recall,
    'f1': f1,
    'accuracy': accuracy,
  };
}
