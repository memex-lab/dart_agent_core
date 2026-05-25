import 'dart:convert';

import '../../core/message.dart';

/// Anthropic: a transcript is the complete record of a trial — messages,
/// tool calls, reasoning, intermediate results, etc.
class Transcript {
  /// Full LLM message sequence in order.
  final List<LLMMessage> messages;

  /// Tool calls in order.
  final List<ToolCallRecord> toolCalls;

  /// Reasoning chunks, if the model emits them.
  final List<String> reasoningSteps;

  /// Streaming events, retries, errors.
  final List<TranscriptEvent> events;

  /// Quantitative metrics.
  final TranscriptMetrics metrics;

  Transcript({
    required this.messages,
    required this.toolCalls,
    this.reasoningSteps = const [],
    this.events = const [],
    required this.metrics,
  });

  Map<String, dynamic> toJson() => {
    'messages': messages.map((m) => m.toJson()).toList(),
    'toolCalls': toolCalls.map((t) => t.toJson()).toList(),
    'reasoningSteps': reasoningSteps,
    'events': events.map((e) => e.toJson()).toList(),
    'metrics': metrics.toJson(),
  };

  factory Transcript.fromJson(Map<String, dynamic> json) {
    return Transcript(
      messages: (json['messages'] as List)
          .map((m) => LLMMessage.fromJson(m as Map<String, dynamic>))
          .toList(),
      toolCalls: (json['toolCalls'] as List)
          .map((t) => ToolCallRecord.fromJson(t as Map<String, dynamic>))
          .toList(),
      reasoningSteps: ((json['reasoningSteps'] as List?) ?? []).cast<String>(),
      events: ((json['events'] as List?) ?? [])
          .map((e) => TranscriptEvent.fromJson(e as Map<String, dynamic>))
          .toList(),
      metrics: TranscriptMetrics.fromJson(
        json['metrics'] as Map<String, dynamic>,
      ),
    );
  }

  String toJsonString() => jsonEncode(toJson());
}

/// Record of a single tool invocation during a trial.
class ToolCallRecord {
  final String callId;
  final String toolName;
  final Map<String, dynamic> arguments;

  /// Strongly-typed execution result. May be null when the tool errored
  /// before producing one; details should still appear in [errorMessage]
  /// in that case.
  final FunctionExecutionResult? result;

  final DateTime startedAt;
  final DateTime endedAt;
  final bool isError;
  final String? errorMessage;

  ToolCallRecord({
    required this.callId,
    required this.toolName,
    required this.arguments,
    this.result,
    required this.startedAt,
    required this.endedAt,
    this.isError = false,
    this.errorMessage,
  });

  Duration get duration => endedAt.difference(startedAt);

  Map<String, dynamic> toJson() => {
    'callId': callId,
    'toolName': toolName,
    'arguments': arguments,
    if (result != null) 'result': result!.toJson(),
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
    'isError': isError,
    if (errorMessage != null) 'errorMessage': errorMessage,
  };

  factory ToolCallRecord.fromJson(Map<String, dynamic> json) {
    return ToolCallRecord(
      callId: json['callId'] as String,
      toolName: json['toolName'] as String,
      arguments: (json['arguments'] as Map).cast<String, dynamic>(),
      result: json['result'] == null
          ? null
          : FunctionExecutionResult.fromJson(
              (json['result'] as Map).cast<String, dynamic>(),
            ),
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: DateTime.parse(json['endedAt'] as String),
      isError: json['isError'] as bool? ?? false,
      errorMessage: json['errorMessage'] as String?,
    );
  }
}

/// Lightweight log of additional events that don't fit neatly into messages
/// or tool calls (e.g. retries, plan changes, exceptions).
class TranscriptEvent {
  final DateTime at;
  final String kind; // e.g. 'llm_retry', 'plan_changed', 'exception'
  final String message;
  final Map<String, dynamic> details;

  TranscriptEvent({
    required this.at,
    required this.kind,
    required this.message,
    this.details = const {},
  });

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'kind': kind,
    'message': message,
    if (details.isNotEmpty) 'details': details,
  };

  factory TranscriptEvent.fromJson(Map<String, dynamic> json) {
    return TranscriptEvent(
      at: DateTime.parse(json['at'] as String),
      kind: json['kind'] as String,
      message: json['message'] as String,
      details: ((json['details'] as Map?)?.cast<String, dynamic>()) ?? const {},
    );
  }
}

/// Quantitative metrics about a trial.
class TranscriptMetrics {
  final int nTurns;
  final int nToolCalls;
  final int nTotalTokens;
  final Duration? timeToFirstToken;
  final Duration? timeToLastToken;
  final double? outputTokensPerSec;

  const TranscriptMetrics({
    required this.nTurns,
    required this.nToolCalls,
    required this.nTotalTokens,
    this.timeToFirstToken,
    this.timeToLastToken,
    this.outputTokensPerSec,
  });

  Map<String, dynamic> toJson() => {
    'nTurns': nTurns,
    'nToolCalls': nToolCalls,
    'nTotalTokens': nTotalTokens,
    if (timeToFirstToken != null)
      'timeToFirstTokenMs': timeToFirstToken!.inMilliseconds,
    if (timeToLastToken != null)
      'timeToLastTokenMs': timeToLastToken!.inMilliseconds,
    if (outputTokensPerSec != null) 'outputTokensPerSec': outputTokensPerSec,
  };

  factory TranscriptMetrics.fromJson(Map<String, dynamic> json) {
    return TranscriptMetrics(
      nTurns: json['nTurns'] as int? ?? 0,
      nToolCalls: json['nToolCalls'] as int? ?? 0,
      nTotalTokens: json['nTotalTokens'] as int? ?? 0,
      timeToFirstToken: json['timeToFirstTokenMs'] == null
          ? null
          : Duration(milliseconds: json['timeToFirstTokenMs'] as int),
      timeToLastToken: json['timeToLastTokenMs'] == null
          ? null
          : Duration(milliseconds: json['timeToLastTokenMs'] as int),
      outputTokensPerSec: (json['outputTokensPerSec'] as num?)?.toDouble(),
    );
  }
}
