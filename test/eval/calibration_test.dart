import 'package:dart_agent_core/eval.dart';
import 'package:test/test.dart';

void main() {
  HumanLabeledTrial labeled(double human, String id) => HumanLabeledTrial(
    trialId: TrialId(runName: 'r', taskId: id, trialIndex: 0),
    humanScore: human,
    input: const {},
    output: 'output for $id',
  );

  group('JudgeCalibrator', () {
    test('perfect agreement → Spearman/Pearson = 1.0, MAE = 0', () async {
      final golden = [
        labeled(0.0, 't0'),
        labeled(0.25, 't1'),
        labeled(0.5, 't2'),
        labeled(0.75, 't3'),
        labeled(1.0, 't4'),
      ];
      const calibrator = JudgeCalibrator();
      final report = await calibrator.calibrate(
        goldenSet: golden,
        judgeScorer: (l) async => JudgeScore(value: l.humanScore),
      );
      expect(report.spearmanCorrelation, closeTo(1.0, 1e-9));
      expect(report.pearsonCorrelation, closeTo(1.0, 1e-9));
      expect(report.meanAbsoluteError, closeTo(0.0, 1e-9));
      expect(report.agreementRate, 1.0);
      expect(report.samples, 5);
      expect(report.disagreementCount, 0);
      expect(report.meetsAnthropicBar, isTrue);
    });

    test('perfectly inverted → Spearman = -1.0, fails Anthropic bar', () async {
      // judge always reports 1 - human
      final golden = [
        labeled(0.0, 't0'),
        labeled(0.25, 't1'),
        labeled(0.5, 't2'),
        labeled(0.75, 't3'),
        labeled(1.0, 't4'),
      ];
      const calibrator = JudgeCalibrator();
      final report = await calibrator.calibrate(
        goldenSet: golden,
        judgeScorer: (l) async => JudgeScore(value: 1.0 - l.humanScore),
      );
      expect(report.spearmanCorrelation, closeTo(-1.0, 1e-9));
      expect(report.meetsAnthropicBar, isFalse);
    });

    test(
      'null judge scores are excluded from correlation but counted',
      () async {
        // 3 valid, 1 null
        final golden = [
          labeled(0.0, 't0'),
          labeled(0.5, 't1'),
          labeled(1.0, 't2'),
          labeled(0.5, 't3'),
        ];
        const calibrator = JudgeCalibrator();
        final report = await calibrator.calibrate(
          goldenSet: golden,
          judgeScorer: (l) async {
            if (l.trialId.taskId == 't3') return null;
            return JudgeScore(value: l.humanScore);
          },
        );
        expect(report.samples, 3);
        expect(report.spearmanCorrelation, closeTo(1.0, 1e-9));
      },
    );

    test('throws if golden set empty', () async {
      const calibrator = JudgeCalibrator();
      await expectLater(
        calibrator.calibrate(
          goldenSet: const [],
          judgeScorer: (l) async => null,
        ),
        throwsArgumentError,
      );
    });

    test('throws if too few valid pairs (< 2)', () async {
      const calibrator = JudgeCalibrator();
      await expectLater(
        calibrator.calibrate(
          goldenSet: [labeled(0.5, 't0'), labeled(0.5, 't1')],
          judgeScorer: (l) async => null, // both null → 0 valid
        ),
        throwsStateError,
      );
    });

    test('disagreements are sorted by absolute delta descending', () async {
      // Force big disagreement on one entry
      final golden = [
        labeled(0.0, 't0'),
        labeled(0.25, 't1'),
        labeled(0.5, 't2'),
        labeled(0.75, 't3'),
        labeled(1.0, 't4'),
      ];
      const calibrator = JudgeCalibrator();
      final report = await calibrator.calibrate(
        goldenSet: golden,
        judgeScorer: (l) async {
          if (l.trialId.taskId == 't0') return const JudgeScore(value: 1.0);
          return JudgeScore(value: l.humanScore);
        },
      );
      expect(report.disagreements.first.trialId.taskId, 't0');
      expect(report.disagreements.first.absoluteDelta, closeTo(1.0, 1e-9));
    });
  });
}
