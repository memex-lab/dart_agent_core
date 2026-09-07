import 'package:dart_agent_core/eval.dart';
import 'package:test/test.dart';

void main() {
  group('passAtK', () {
    test('all-pass yields 1.0 for any k <= n', () {
      final passes = [true, true, true, true];
      expect(passAtK(passes, 1), closeTo(1.0, 1e-9));
      expect(passAtK(passes, 4), closeTo(1.0, 1e-9));
    });

    test('all-fail yields 0.0 for any k', () {
      final passes = [false, false, false, false];
      expect(passAtK(passes, 1), 0.0);
      expect(passAtK(passes, 4), 0.0);
    });

    test('Codex unbiased formula: 1 success in 4 trials, k=1', () {
      // n=4, c=1, k=1 → 1 - C(3,1)/C(4,1) = 1 - 3/4 = 0.25
      expect(passAtK([true, false, false, false], 1), closeTo(0.25, 1e-9));
    });

    test('Codex unbiased formula: 2 successes in 4 trials, k=2', () {
      // n=4, c=2, k=2 → 1 - C(2,2)/C(4,2) = 1 - 1/6 ≈ 0.8333
      expect(
        passAtK([true, true, false, false], 2),
        closeTo(1.0 - 1.0 / 6.0, 1e-9),
      );
    });

    test('Codex unbiased formula: 3 successes in 5 trials, k=3', () {
      // n=5, c=3, k=3 → 1 - C(2,3)/C(5,3) -- C(2,3)=0 → 1.0
      expect(passAtK([true, true, true, false, false], 3), closeTo(1.0, 1e-9));
    });

    test('k > n returns 0.0', () {
      expect(passAtK([true, false], 3), 0.0);
    });

    test('k <= 0 returns 0.0', () {
      expect(passAtK([true, true], 0), 0.0);
      expect(passAtK([true, true], -1), 0.0);
    });

    test('empty list returns 0.0', () {
      expect(passAtK(<bool>[], 1), 0.0);
    });
  });

  group('passCaretK', () {
    test('all-pass yields 1.0 for any k', () {
      final passes = [true, true, true];
      expect(passCaretK(passes, 1), closeTo(1.0, 1e-9));
      expect(passCaretK(passes, 3), closeTo(1.0, 1e-9));
    });

    test('half-pass: empirical (c/n)^k', () {
      // c=2, n=4, k=2 → (0.5)^2 = 0.25
      expect(passCaretK([true, true, false, false], 2), closeTo(0.25, 1e-9));
    });

    test('any failure makes k=n yield 0 < (c/n)^k < 1', () {
      // 3 of 4 pass, k=4 → (0.75)^4 ≈ 0.3164
      expect(
        passCaretK([true, true, true, false], 4),
        closeTo(0.31640625, 1e-9),
      );
    });

    test('zero successes returns 0.0', () {
      expect(passCaretK([false, false], 1), 0.0);
    });

    test('k <= 0 or empty returns 0.0', () {
      expect(passCaretK([true], 0), 0.0);
      expect(passCaretK(<bool>[], 1), 0.0);
    });

    test('k > n remains a valid empirical estimate', () {
      expect(passCaretK([true, false], 5), closeTo(0.03125, 1e-9));
    });
  });

  group('ClassificationMetrics', () {
    test('precision/recall/f1/accuracy on perfect classifier', () {
      const m = ClassificationMetrics(
        truePositives: 10,
        falsePositives: 0,
        trueNegatives: 10,
        falseNegatives: 0,
      );
      expect(m.precision, 1.0);
      expect(m.recall, 1.0);
      expect(m.f1, 1.0);
      expect(m.accuracy, 1.0);
    });

    test('precision/recall/f1 with mixed errors', () {
      const m = ClassificationMetrics(
        truePositives: 6,
        falsePositives: 2,
        trueNegatives: 8,
        falseNegatives: 4,
      );
      // P = 6/8 = 0.75; R = 6/10 = 0.6; F1 = 2*0.75*0.6/(0.75+0.6) = 0.6667
      expect(m.precision, closeTo(0.75, 1e-9));
      expect(m.recall, closeTo(0.6, 1e-9));
      expect(m.f1, closeTo(2 * 0.75 * 0.6 / (0.75 + 0.6), 1e-9));
      expect(m.accuracy, closeTo(14 / 20, 1e-9));
    });

    test('division-by-zero guards', () {
      const empty = ClassificationMetrics(
        truePositives: 0,
        falsePositives: 0,
        trueNegatives: 0,
        falseNegatives: 0,
      );
      expect(empty.precision, 0.0);
      expect(empty.recall, 0.0);
      expect(empty.f1, 0.0);
      expect(empty.accuracy, 0.0);
    });

    test('toJson contains the four counts and derived metrics', () {
      const m = ClassificationMetrics(
        truePositives: 1,
        falsePositives: 1,
        trueNegatives: 1,
        falseNegatives: 1,
      );
      final j = m.toJson();
      expect(j['truePositives'], 1);
      expect(j['falsePositives'], 1);
      expect(j['trueNegatives'], 1);
      expect(j['falseNegatives'], 1);
      expect(j['precision'], 0.5);
      expect(j['recall'], 0.5);
      expect(j['f1'], 0.5);
      expect(j['accuracy'], 0.5);
    });
  });
}
