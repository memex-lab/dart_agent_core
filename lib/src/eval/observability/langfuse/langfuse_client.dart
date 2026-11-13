import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import 'langfuse_config.dart';
import 'langfuse_otlp.dart';

/// 把已经结束的 span 批量发到 `POST /api/public/otel/v1/traces`，把 score
/// 以 JSON 数组发到 `POST /api/public/scores`。
///
/// 自托管需要 Langfuse 4.55.0 或更新。Score 即使只有一条也按数组提交，
/// 这个批量接口是 4.55.0 才有的。
///
/// 行为对齐 Langfuse 官方 SDK：
///   - 内部维护一个 queue
///   - 满 [LangfuseConfig.flushAt] 条立刻 flush
///   - 否则最长 [LangfuseConfig.flushInterval] flush 一次
///   - HTTP 失败按指数退避重试，最多 [LangfuseConfig.maxRetries] 次
///   - 关闭时 [shutdown] 强制 flush 完所有积压
///
/// Trace 请求带 `x-langfuse-ingestion-version: 4`。同一个 span 只应
/// [enqueueSpan] 一次；OTLP 不合并 create / update。
class LangfuseClient {
  static final _log = Logger('LangfuseClient');

  final LangfuseConfig config;
  final Dio _dio;

  final List<_Pending> _queue = [];
  Timer? _flushTimer;

  /// 串行化 flush，避免并发请求重复发同一批 event。
  Future<void>? _inFlight;
  bool _closed = false;

  LangfuseClient(this.config, {Dio? dio}) : _dio = dio ?? _defaultDio(config);

  static Dio _defaultDio(LangfuseConfig config) {
    final auth =
        'Basic ${base64.encode(utf8.encode('${config.publicKey}:${config.secretKey}'))}';
    return Dio(
      BaseOptions(
        connectTimeout: config.requestTimeout,
        sendTimeout: config.requestTimeout,
        receiveTimeout: config.requestTimeout,
        headers: {'Content-Type': 'application/json', 'Authorization': auth},
        // 4xx/5xx 自己处理，不要让 Dio 抛出
        validateStatus: (_) => true,
      ),
    );
  }

  /// 一条已经结束的 OTLP span。同一个 span id 只应入队一次。
  void enqueueSpan(Map<String, dynamic> span) {
    _add(_Pending.span(span));
  }

  /// 一条 score。flush 时和同批其它 score 组成 JSON 数组，走
  /// [LangfuseConfig.scoresUrl]，不进 OTLP body。
  void enqueueScore(Map<String, dynamic> score) {
    _add(_Pending.score(score));
  }

  void _add(_Pending pending) {
    if (_closed) return;
    _queue.add(pending);
    if (_queue.length >= config.flushAt) {
      unawaited(flush());
    } else {
      _scheduleFlush();
    }
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(config.flushInterval, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  /// 把当前队列里的所有 event 发出去。**串行化**：同一时刻只有一个
  /// 在飞的 flush，避免重复发送。
  Future<void> flush() async {
    if (_inFlight != null) {
      await _inFlight;
      // 等上一次完成后，如果队列里还有新的（在那期间 enqueue 的），递归
      // flush 一次。但只递归一层，避免无限。
      if (_queue.isNotEmpty) return _doFlushOnce();
      return;
    }
    return _doFlushOnce();
  }

  Future<void> _doFlushOnce() async {
    if (_queue.isEmpty) return;
    final completer = Completer<void>();
    _inFlight = completer.future;
    try {
      _flushTimer?.cancel();
      _flushTimer = null;
      final batch = List<_Pending>.from(_queue);
      _queue.clear();
      await _send(batch);
    } finally {
      _inFlight = null;
      completer.complete();
    }
  }

  Future<void> _send(List<_Pending> pending) async {
    if (pending.isEmpty) return;
    final spans = [
      for (final item in pending)
        if (!item.isScore) item.body,
    ];
    final scores = [
      for (final item in pending)
        if (item.isScore) item.body,
    ];
    if (spans.isNotEmpty) {
      final ok = await _post(config.otelTracesUrl, otlpExport(spans), const {
        'x-langfuse-ingestion-version': '4',
      }, spans.length);
      if (!ok) {
        if (scores.isNotEmpty) {
          _log.warning(
            'Dropped ${scores.length} Langfuse scores after the trace batch failed',
          );
        }
        return;
      }
    }
    if (scores.isNotEmpty) {
      await _post(config.scoresUrl, scores, const {}, scores.length);
    }
  }

  /// 返回 `false` 表示这批已经放弃（4xx，或重试耗尽）。不向调用方抛。
  Future<bool> _post(
    String url,
    Object body,
    Map<String, String> headers,
    int count,
  ) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        final resp = await _dio.post<dynamic>(
          url,
          data: body,
          options: Options(headers: headers),
        );
        // OTLP 正常是 200。批量 score 接受时是 202，部分失败是 207。
        // 207 不再重试：服务端已经处理过这批。
        final status = resp.statusCode ?? -1;
        if (status >= 200 && status < 300) {
          if (status == 207) {
            _log.warning(
              'Langfuse partial-success (207): ${_truncate(resp.data)}',
            );
          }
          return true;
        }
        if (status >= 400 && status < 500) {
          throw StateError(
            'Langfuse rejected batch with $status: ${_truncate(resp.data)}',
          );
        }
        throw _Retryable('Langfuse $status: ${_truncate(resp.data)}');
      } on _Retryable catch (e) {
        if (attempt > config.maxRetries) {
          _log.severe(
            'Langfuse flush failed after $attempt attempts ($count items dropped): $e',
          );
          return false;
        }
        await Future.delayed(_backoff(attempt));
      } on DioException catch (e) {
        if (attempt > config.maxRetries) {
          _log.severe(
            'Langfuse flush failed after $attempt attempts ($count items dropped): ${e.message}',
          );
          return false;
        }
        await Future.delayed(_backoff(attempt));
      } catch (e) {
        _log.severe('Langfuse flush hit non-retryable error: $e');
        return false;
      }
    }
  }

  Duration _backoff(int attempt) {
    // 100ms, 200ms, 400ms, 800ms, ...
    final ms = 100 * (1 << (attempt - 1));
    return Duration(milliseconds: ms.clamp(100, 5000));
  }

  /// flush 剩余事件 + 释放定时器。调用后 [enqueueSpan] 和
  /// [enqueueScore] 静默 no-op。
  Future<void> shutdown() async {
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
    if (_inFlight != null) await _inFlight;
    _dio.close(force: true);
  }

  String _truncate(Object? data) {
    final s = data?.toString() ?? '';
    return s.length > 500 ? '${s.substring(0, 500)}...' : s;
  }
}

class _Pending {
  final bool isScore;
  final Map<String, dynamic> body;

  const _Pending.span(this.body) : isScore = false;
  const _Pending.score(this.body) : isScore = true;
}

class _Retryable implements Exception {
  final String message;
  _Retryable(this.message);
  @override
  String toString() => 'Retryable: $message';
}
