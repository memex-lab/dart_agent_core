import 'calibration_report.dart';

/// 业务方提供的 judge 评分回调。
///
/// 输入是 [HumanLabeledTrial.input] + [HumanLabeledTrial.output]，输出
/// 是 judge 给出的分值（与人工同刻度）和可选解释。如果 judge 无法判断，
/// 返回 null（被排除在相关性计算之外，但会单独统计）。
typedef JudgeScorer = Future<JudgeScore?> Function(HumanLabeledTrial labeled);

class JudgeScore {
  final double value;
  final String? rationale;
  const JudgeScore({required this.value, this.rationale});
}

/// 默认配置：超过 0.15 的差距视为"不同意"，并报告 top 20 个最严重的偏差。
class CalibrationConfig {
  /// |humanScore - judgeScore| 在此阈值内视为"同意"。
  final double agreementTolerance;

  /// 报告中显示前 N 个偏差最大的 trial。
  final int topDisagreements;

  const CalibrationConfig({
    this.agreementTolerance = 0.15,
    this.topDisagreements = 20,
  });
}

/// 度量 LLM judge 与人工评分的一致性。
///
/// 用法：
/// ```dart
/// final calibrator = JudgeCalibrator();
/// final report = await calibrator.calibrate(
///   goldenSet: humanLabeledTrials,
///   judgeScorer: (labeled) async {
///     final r = await myLLMJudge.grade(labeled.input, labeled.output);
///     return JudgeScore(value: r.score, rationale: r.reasoning);
///   },
/// );
/// if (!report.meetsAnthropicBar) {
///   throw StateError('judge correlation too low: ${report.spearmanCorrelation}');
/// }
/// ```
class JudgeCalibrator {
  final CalibrationConfig config;

  const JudgeCalibrator({this.config = const CalibrationConfig()});
}

extension JudgeCalibratorOps on JudgeCalibrator {
  Future<CalibrationReport> calibrate({
    required List<HumanLabeledTrial> goldenSet,
    required JudgeScorer judgeScorer,
    int concurrency = 4,
  }) async {
    if (goldenSet.isEmpty) {
      throw ArgumentError('goldenSet must not be empty');
    }

    // 并发拉 judge 分数（每个 trial 最多一次 judge 调用）。
    final results = List<_PairedScore?>.filled(goldenSet.length, null);
    final iterator = goldenSet.asMap().entries.iterator;

    Future<void> worker() async {
      while (iterator.moveNext()) {
        final entry = iterator.current;
        final i = entry.key;
        final labeled = entry.value;
        try {
          final js = await judgeScorer(labeled);
          if (js != null) {
            results[i] = _PairedScore(
              labeled: labeled,
              judgeValue: js.value,
              judgeRationale: js.rationale,
            );
          }
        } catch (e, st) {
          // 失败的样本被忽略（不计入相关性）。
          // 业务方可在 scorer 内做容错或返回 null。
          assert(() {
            print('judge scorer failed for ${labeled.trialId}: $e\n$st');
            return true;
          }());
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));

    final valid = results.whereType<_PairedScore>().toList();
    if (valid.length < 2) {
      throw StateError(
        'Need at least 2 valid (judge, human) pairs to compute correlation. '
        'Got ${valid.length}.',
      );
    }

    final humanValues = valid.map((p) => p.labeled.humanScore).toList();
    final judgeValues = valid.map((p) => p.judgeValue).toList();

    final spearman = _spearman(humanValues, judgeValues);
    final pearson = _pearson(humanValues, judgeValues);

    final tolerance = config.agreementTolerance;
    final agreementCount = valid
        .where((p) => (p.labeled.humanScore - p.judgeValue).abs() <= tolerance)
        .length;
    final mae =
        valid
            .map((p) => (p.labeled.humanScore - p.judgeValue).abs())
            .fold<double>(0, (a, b) => a + b) /
        valid.length;

    final disagreements =
        valid
            .map(
              (p) => TrialDisagreement(
                trialId: p.labeled.trialId,
                humanScore: p.labeled.humanScore,
                judgeScore: p.judgeValue,
                absoluteDelta: (p.labeled.humanScore - p.judgeValue).abs(),
                humanRationale: p.labeled.humanRationale,
                judgeRationale: p.judgeRationale,
              ),
            )
            .toList()
          ..sort((a, b) => b.absoluteDelta.compareTo(a.absoluteDelta));

    final topDisagreements = disagreements
        .take(config.topDisagreements)
        .toList();

    return CalibrationReport(
      spearmanCorrelation: spearman,
      pearsonCorrelation: pearson,
      agreementRate: agreementCount / valid.length,
      meanAbsoluteError: mae,
      samples: valid.length,
      agreementCount: agreementCount,
      disagreementCount: valid.length - agreementCount,
      disagreements: topDisagreements,
    );
  }
}

class _PairedScore {
  final HumanLabeledTrial labeled;
  final double judgeValue;
  final String? judgeRationale;
  const _PairedScore({
    required this.labeled,
    required this.judgeValue,
    this.judgeRationale,
  });
}

double _pearson(List<double> xs, List<double> ys) {
  assert(xs.length == ys.length);
  final n = xs.length;
  if (n < 2) return 0.0;
  final meanX = xs.reduce((a, b) => a + b) / n;
  final meanY = ys.reduce((a, b) => a + b) / n;
  double num = 0, denX = 0, denY = 0;
  for (var i = 0; i < n; i++) {
    final dx = xs[i] - meanX;
    final dy = ys[i] - meanY;
    num += dx * dy;
    denX += dx * dx;
    denY += dy * dy;
  }
  if (denX == 0 || denY == 0) return 0.0;
  return num / _sqrt(denX * denY);
}

/// Spearman = Pearson on the rank-transformed values. 用平均秩处理并列。
double _spearman(List<double> xs, List<double> ys) {
  return _pearson(_ranks(xs), _ranks(ys));
}

/// 平均秩：[3, 1, 1, 2] → [4, 1.5, 1.5, 3]
List<double> _ranks(List<double> values) {
  final indexed = List.generate(values.length, (i) => MapEntry(i, values[i]));
  indexed.sort((a, b) => a.value.compareTo(b.value));
  final ranks = List<double>.filled(values.length, 0);
  var i = 0;
  while (i < indexed.length) {
    var j = i;
    while (j + 1 < indexed.length && indexed[j + 1].value == indexed[i].value) {
      j++;
    }
    // 索引区间 [i, j] 同分，平均秩 = (i + j) / 2 + 1
    final avgRank = (i + j) / 2.0 + 1.0;
    for (var k = i; k <= j; k++) {
      ranks[indexed[k].key] = avgRank;
    }
    i = j + 1;
  }
  return ranks;
}

double _sqrt(double v) {
  // dart:math 的 sqrt 在很多场景已经导入；这里我们只需要一个稳的开方。
  // 使用牛顿迭代避免拉额外 import 仅为 sqrt。
  if (v <= 0) return 0;
  var x = v;
  for (var i = 0; i < 32; i++) {
    x = 0.5 * (x + v / x);
  }
  return x;
}
