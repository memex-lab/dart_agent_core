import '../core/trial.dart';

/// 一个被人工标过的 trial。用于校准 LLM judge。
class HumanLabeledTrial {
  /// trial 的标识符，便于关联回原始数据。
  final TrialId trialId;

  /// 人工给出的"正确"分值（与 judge 同一刻度）。
  final double humanScore;

  /// 人工评注（可选，便于后续审视）。
  final String? humanRationale;

  /// 评估对象的输入摘要（让 judge 复跑用的最小信息）。
  final Map<String, dynamic> input;

  /// 被评估的输出（judge 判分的对象）。
  final String output;

  const HumanLabeledTrial({
    required this.trialId,
    required this.humanScore,
    this.humanRationale,
    required this.input,
    required this.output,
  });
}

/// LLM judge 与人工评分的相关性。
class CalibrationReport {
  /// Spearman 等级相关系数 ∈ [-1, 1]。Anthropic 推荐 ≥ 0.7 才上线。
  final double spearmanCorrelation;

  /// Pearson 线性相关系数 ∈ [-1, 1]。
  final double pearsonCorrelation;

  /// "judge 与人工差 ≤ tolerance"的样本占比 ∈ [0, 1]。
  final double agreementRate;

  /// 平均绝对误差（MAE）。
  final double meanAbsoluteError;

  final int samples;
  final int agreementCount;
  final int disagreementCount;

  /// 不一致最严重的 trial，由 judge - human 绝对差降序排列，前 N 个。
  final List<TrialDisagreement> disagreements;

  const CalibrationReport({
    required this.spearmanCorrelation,
    required this.pearsonCorrelation,
    required this.agreementRate,
    required this.meanAbsoluteError,
    required this.samples,
    required this.agreementCount,
    required this.disagreementCount,
    required this.disagreements,
  });

  /// Anthropic Step 5 的"上线门槛"：Spearman ≥ 0.7。
  bool get meetsAnthropicBar => spearmanCorrelation >= 0.7;

  Map<String, dynamic> toJson() => {
    'spearmanCorrelation': spearmanCorrelation,
    'pearsonCorrelation': pearsonCorrelation,
    'agreementRate': agreementRate,
    'meanAbsoluteError': meanAbsoluteError,
    'samples': samples,
    'agreementCount': agreementCount,
    'disagreementCount': disagreementCount,
    'meetsAnthropicBar': meetsAnthropicBar,
    'disagreements': disagreements.map((d) => d.toJson()).toList(),
  };
}

class TrialDisagreement {
  final TrialId trialId;
  final double humanScore;
  final double judgeScore;
  final double absoluteDelta;
  final String? humanRationale;
  final String? judgeRationale;

  const TrialDisagreement({
    required this.trialId,
    required this.humanScore,
    required this.judgeScore,
    required this.absoluteDelta,
    this.humanRationale,
    this.judgeRationale,
  });

  Map<String, dynamic> toJson() => {
    'trialId': trialId.toJson(),
    'humanScore': humanScore,
    'judgeScore': judgeScore,
    'absoluteDelta': absoluteDelta,
    'humanRationale': humanRationale,
    'judgeRationale': judgeRationale,
  };
}
