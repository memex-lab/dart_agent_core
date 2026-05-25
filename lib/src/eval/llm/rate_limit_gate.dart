import 'dart:async';
import 'dart:collection';

/// Throttles outgoing LLM calls. Independent from runner concurrency.
///
/// [acquire] suspends the caller until the call is allowed. Implementations
/// must be safe to call concurrently from many trials.
abstract class RateLimitGate {
  Future<void> acquire({int estimatedTokens = 0});
}

/// Permits up to N requests per minute (token bucket, refill at +N/60s).
class RpmRateLimitGate implements RateLimitGate {
  final int requestsPerMinute;
  final double _refillPerSec;
  double _tokens;
  DateTime _lastRefill;
  final Queue<Completer<void>> _waiters = Queue();

  RpmRateLimitGate({required this.requestsPerMinute})
    : _refillPerSec = requestsPerMinute / 60.0,
      _tokens = requestsPerMinute.toDouble(),
      _lastRefill = DateTime.now();

  @override
  Future<void> acquire({int estimatedTokens = 0}) async {
    _refill();
    if (_tokens >= 1.0 && _waiters.isEmpty) {
      _tokens -= 1.0;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    _scheduleWake();
    return c.future;
  }

  void _refill() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastRefill).inMilliseconds / 1000.0;
    if (elapsed <= 0) return;
    _lastRefill = now;
    _tokens = (_tokens + elapsed * _refillPerSec).clamp(
      0,
      requestsPerMinute.toDouble(),
    );
  }

  void _scheduleWake() {
    if (_waiters.isEmpty) return;
    final missing = 1.0 - _tokens;
    final waitMs = (missing / _refillPerSec * 1000).ceil().clamp(10, 60000);
    Timer(Duration(milliseconds: waitMs), _wake);
  }

  void _wake() {
    _refill();
    while (_waiters.isNotEmpty && _tokens >= 1.0) {
      _tokens -= 1.0;
      _waiters.removeFirst().complete();
    }
    if (_waiters.isNotEmpty) _scheduleWake();
  }
}

/// Permits up to N tokens per minute (token-aware, refills similarly).
///
/// Note: callers must pass a reasonable [estimatedTokens] to [acquire];
/// underestimating leaks throughput, overestimating wastes capacity.
class TpmRateLimitGate implements RateLimitGate {
  final int tokensPerMinute;
  final double _refillPerSec;
  double _budget;
  DateTime _lastRefill;
  final Queue<_TpmWaiter> _waiters = Queue();

  TpmRateLimitGate({required this.tokensPerMinute})
    : _refillPerSec = tokensPerMinute / 60.0,
      _budget = tokensPerMinute.toDouble(),
      _lastRefill = DateTime.now();

  @override
  Future<void> acquire({int estimatedTokens = 0}) async {
    final cost = estimatedTokens > 0 ? estimatedTokens.toDouble() : 1.0;
    _refill();
    if (_budget >= cost && _waiters.isEmpty) {
      _budget -= cost;
      return;
    }
    final c = Completer<void>();
    _waiters.add(_TpmWaiter(cost, c));
    _scheduleWake();
    return c.future;
  }

  void _refill() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastRefill).inMilliseconds / 1000.0;
    if (elapsed <= 0) return;
    _lastRefill = now;
    _budget = (_budget + elapsed * _refillPerSec).clamp(
      0,
      tokensPerMinute.toDouble(),
    );
  }

  void _scheduleWake() {
    if (_waiters.isEmpty) return;
    final next = _waiters.first.cost - _budget;
    final waitMs = next <= 0
        ? 10
        : (next / _refillPerSec * 1000).ceil().clamp(10, 60000);
    Timer(Duration(milliseconds: waitMs), _wake);
  }

  void _wake() {
    _refill();
    while (_waiters.isNotEmpty && _budget >= _waiters.first.cost) {
      final w = _waiters.removeFirst();
      _budget -= w.cost;
      w.completer.complete();
    }
    if (_waiters.isNotEmpty) _scheduleWake();
  }
}

class _TpmWaiter {
  final double cost;
  final Completer<void> completer;
  _TpmWaiter(this.cost, this.completer);
}

/// No-op gate. Default when callers don't configure rate limiting.
class NoopRateLimitGate implements RateLimitGate {
  const NoopRateLimitGate();

  @override
  Future<void> acquire({int estimatedTokens = 0}) async {}
}
