import 'package:dart_agent_core/eval.dart';
import 'package:test/test.dart';

void main() {
  test('passCaretK returns 0 when k exceeds trial count', () {
    expect(passCaretK([true, true, false], 5), 0.0);
    expect(passAtK([true, true, false], 5), 0.0);
  });

  test('passCaretK matches empirical estimator when k <= n', () {
    expect(passCaretK([true, true, false], 2), closeTo(4 / 9, 1e-9));
  });
}
