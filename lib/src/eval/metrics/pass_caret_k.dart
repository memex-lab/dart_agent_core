/// Anthropic: probability that *all* k trials pass.
///
/// pass^k = (c / n)^k for the empirical estimator. Some references use the
/// unbiased combinatorial form C(c, k) / C(n, k). We provide the empirical
/// version because it's intuitive and consistent with how teams report
/// "X out of Y trials passed" in CI reports.
///
/// Returns 0.0 when k <= 0, n == 0, or k > n (cannot evaluate that many).
double passCaretK(List<bool> trialPasses, int k) {
  final n = trialPasses.length;
  if (k <= 0 || n == 0) return 0.0;
  if (k > n) return 0.0;
  final c = trialPasses.where((p) => p).length;
  if (c == 0) return 0.0;
  // (c/n)^k
  return _pow(c / n, k);
}

double _pow(double base, int exp) {
  var result = 1.0;
  for (var i = 0; i < exp; i++) {
    result *= base;
  }
  return result;
}
