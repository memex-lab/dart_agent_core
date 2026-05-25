/// Anthropic: probability of at least one success in [k] independent trials.
///
/// Uses the unbiased combinatorial formula from Codex paper:
///
///   pass@k = 1 − C(n − c, k) / C(n, k)
///
/// where n = total trials, c = successes among them, k ≤ n.
///
/// Returns 0.0 when k > trialPasses.length (cannot evaluate that many).
double passAtK(List<bool> trialPasses, int k) {
  final n = trialPasses.length;
  if (k <= 0 || n == 0) return 0.0;
  if (k > n) return 0.0;
  final c = trialPasses.where((p) => p).length;
  if (n - c < k) return 1.0;

  // log-domain product to avoid overflow on big n.
  // 1 - prod_{i=0..k-1} (n - c - i) / (n - i)
  var prob = 1.0;
  for (var i = 0; i < k; i++) {
    prob *= (n - c - i) / (n - i);
  }
  return 1.0 - prob;
}
