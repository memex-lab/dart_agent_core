import 'dart:async';
import 'dart:convert';

import '../../agent/controller.dart';
import '../../agent/events.dart';
import '../../core/message.dart';
import 'transcript.dart';

/// Records a trial transcript from the shared [AgentController].
///
/// Agent harnesses should focus on running the agent and collecting the final
/// [Outcome]. This recorder captures the generic execution trace: messages,
/// tool calls, retry/error events, reasoning text, and token/turn metrics.
class EvalTranscriptRecorder {
  final AgentController controller;
  final DateTime startedAt;
  final DateTime Function() now;

  final List<LLMMessage> _messages = [];
  final List<ToolCallRecord> _toolCalls = [];
  final List<String> _reasoningSteps = [];
  final List<TranscriptEvent> _events = [];
  final Map<String, _ToolCallStart> _pendingToolCalls = {};
  final List<StreamSubscription<Object?>> _subscriptions = [];

  DateTime? _firstLLMReplyAt;
  DateTime? _lastLLMReplyAt;
  int _nTurns = 0;
  int _totalTokens = 0;
  bool _disposed = false;

  EvalTranscriptRecorder({
    required this.controller,
    required this.startedAt,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    _listen();
  }

  /// Current transcript snapshot. Safe to call multiple times.
  Transcript snapshot() {
    final ttft = _firstLLMReplyAt;
    final ttlt = _lastLLMReplyAt;
    return Transcript(
      messages: List.unmodifiable(_messages),
      toolCalls: List.unmodifiable(_toolCalls),
      reasoningSteps: List.unmodifiable(_reasoningSteps),
      events: List.unmodifiable(_events),
      metrics: TranscriptMetrics(
        nTurns: _nTurns,
        nToolCalls: _toolCalls.length,
        nTotalTokens: _totalTokens,
        timeToFirstToken: ttft?.difference(startedAt),
        timeToLastToken: ttlt?.difference(startedAt),
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
  }

  void _listen() {
    _subscriptions.add(
      controller.listen<BeforeCallLLMEvent>().listen((e) {
        _messages
          ..clear()
          ..addAll(e.params.messages);
      }),
    );
    _subscriptions.add(
      controller.listen<AfterCallLLMEvent>().listen((e) {
        final at = now();
        _nTurns += 1;
        _firstLLMReplyAt ??= at;
        _lastLLMReplyAt = at;
        final usage = e.response.usage;
        if (usage != null) {
          _totalTokens += usage.totalTokens;
        }
        final thought = e.response.thought;
        if (thought != null && thought.trim().isNotEmpty) {
          _reasoningSteps.add(thought);
        }
        _messages
          ..clear()
          ..addAll(e.params.messages)
          ..add(e.response);
      }),
    );
    _subscriptions.add(
      controller.listen<BeforeToolCallEvent>().listen((e) {
        _pendingToolCalls[e.functionCall.id] = _ToolCallStart(
          startedAt: now(),
          toolName: e.functionCall.name,
          arguments: _decodeArgs(e.functionCall.arguments),
        );
      }),
    );
    _subscriptions.add(
      controller.listen<AfterToolCallEvent>().listen((e) {
        final endedAt = now();
        final start = _pendingToolCalls.remove(e.result.id);
        _toolCalls.add(
          ToolCallRecord(
            callId: e.result.id,
            toolName: e.result.name,
            arguments: start?.arguments ?? _decodeArgs(e.result.arguments),
            result: e.result,
            startedAt: start?.startedAt ?? endedAt,
            endedAt: endedAt,
            isError: e.result.isError,
          ),
        );
        _appendToolResultMessage(e.result);
      }),
    );
    _subscriptions.add(
      controller.listen<LLMRetryingEvent>().listen((e) {
        _events.add(
          TranscriptEvent(at: now(), kind: 'llm_retry', message: e.reason),
        );
      }),
    );
    _subscriptions.add(
      controller.listen<OnAgentExceptionEvent>().listen((e) {
        _events.add(
          TranscriptEvent(
            at: now(),
            kind: 'agent_exception',
            message: e.error.toString(),
          ),
        );
      }),
    );
    _subscriptions.add(
      controller.listen<OnAgentErrorEvent>().listen((e) {
        _events.add(
          TranscriptEvent(at: now(), kind: 'agent_error', message: e.error),
        );
      }),
    );
    _subscriptions.add(
      controller.listen<OnAgentCancelEvent>().listen((e) {
        _events.add(
          TranscriptEvent(
            at: now(),
            kind: 'agent_cancel',
            message: e.reason ?? e.exception.toString(),
          ),
        );
      }),
    );
    _subscriptions.add(
      controller.listen<PlanChangedEvent>().listen((e) {
        _events.add(
          TranscriptEvent(
            at: now(),
            kind: 'plan_changed',
            message: 'Plan changed',
            details: {'plan': e.plan.toJson()},
          ),
        );
      }),
    );
  }

  void _appendToolResultMessage(FunctionExecutionResult result) {
    if (_messages.isNotEmpty &&
        _messages.last is FunctionExecutionResultMessage) {
      final last = _messages.removeLast() as FunctionExecutionResultMessage;
      _messages.add(
        FunctionExecutionResultMessage(results: [...last.results, result]),
      );
      return;
    }
    _messages.add(FunctionExecutionResultMessage(results: [result]));
  }

  Map<String, dynamic> _decodeArgs(String raw) {
    if (raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
      return const {};
    } catch (_) {
      return const {};
    }
  }
}

class _ToolCallStart {
  final DateTime startedAt;
  final String toolName;
  final Map<String, dynamic> arguments;

  const _ToolCallStart({
    required this.startedAt,
    required this.toolName,
    required this.arguments,
  });
}
