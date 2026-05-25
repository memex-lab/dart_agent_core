import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import 'langfuse_config.dart';
import 'langfuse_event.dart';

/// 把 [LangfuseEvent] 批量发到 `POST /api/public/ingestion`。
///
/// 行为对齐 Langfuse 官方 SDK：
///   - 内部维护一个事件 queue
///   - 满 [LangfuseConfig.flushAt] 条立刻 flush
///   - 否则最长 [LangfuseConfig.flushInterval] flush 一次
///   - HTTP 失败按指数退避重试，最多 [LangfuseConfig.maxRetries] 次
///   - 关闭时 [shutdown] 强制 flush 完所有积压
///
/// 仅暴露 [enqueue] / [flush] / [shutdown] 三个口子，TraceExporter 不
/// 需要关心 HTTP / 重试 / 批处理。
class LangfuseClient {
  static final _log = Logger('LangfuseClient');

  final LangfuseConfig config;
  final Dio _dio;

  final List<LangfuseEvent> _queue = [];
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

  /// 把一条 event 放入队列。线程安全：只在 isolate-local 内调用。
  void enqueue(LangfuseEvent event) {
    if (_closed) return;
    _queue.add(event);
    if (_queue.length >= config.flushAt) {
      // 立即触发；不 await，flush 自己串行化
      unawaited(flush());
    } else {
      _scheduleFlush();
    }
  }

  /// 多条版本，避免单条 enqueue 多次 schedule timer。
  void enqueueAll(Iterable<LangfuseEvent> events) {
    if (_closed) return;
    _queue.addAll(events);
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
      final batch = List<LangfuseEvent>.from(_queue);
      _queue.clear();
      await _send(batch);
    } finally {
      _inFlight = null;
      completer.complete();
    }
  }

  Future<void> _send(List<LangfuseEvent> events) async {
    if (events.isEmpty) return;
    final body = {'batch': events.map((e) => e.toJson()).toList()};

    var attempt = 0;
    while (true) {
      attempt++;
      try {
        final resp = await _dio.post<dynamic>(config.ingestionUrl, data: body);
        // Langfuse 在部分 event 失败时会返回 207（Multi-Status）。
        // 200 / 201 / 207 全算成功；只要有一部分被接收就放过。
        final status = resp.statusCode ?? -1;
        if (status >= 200 && status < 300) {
          if (status == 207) {
            _log.warning(
              'Langfuse partial-success (207): ${_truncate(resp.data)}',
            );
          }
          return;
        }
        // 4xx 不可恢复（鉴权 / schema 问题），扔出去
        if (status >= 400 && status < 500) {
          throw StateError(
            'Langfuse rejected batch with $status: ${_truncate(resp.data)}',
          );
        }
        // 5xx 才进入重试
        throw _Retryable('Langfuse $status: ${_truncate(resp.data)}');
      } on _Retryable catch (e) {
        if (attempt > config.maxRetries) {
          _log.severe(
            'Langfuse flush failed after $attempt attempts (${events.length} events dropped): $e',
          );
          return; // 放弃，不让 eval run 因为可观测性挂掉
        }
        await Future.delayed(_backoff(attempt));
      } on DioException catch (e) {
        // 网络层失败也走重试
        if (attempt > config.maxRetries) {
          _log.severe(
            'Langfuse flush failed after $attempt attempts (${events.length} events dropped): ${e.message}',
          );
          return;
        }
        await Future.delayed(_backoff(attempt));
      } catch (e) {
        _log.severe('Langfuse flush hit non-retryable error: $e');
        return;
      }
    }
  }

  Duration _backoff(int attempt) {
    // 100ms, 200ms, 400ms, 800ms, ...
    final ms = 100 * (1 << (attempt - 1));
    return Duration(milliseconds: ms.clamp(100, 5000));
  }

  /// flush 剩余事件 + 释放定时器。调用后 [enqueue] 静默 no-op。
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

class _Retryable implements Exception {
  final String message;
  _Retryable(this.message);
  @override
  String toString() => 'Retryable: $message';
}
