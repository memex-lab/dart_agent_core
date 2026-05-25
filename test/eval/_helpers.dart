/// Shared test helpers for eval subsystem tests.
library;

import 'dart:async';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';
import 'package:dio/dio.dart';

// ─── Fake LLM client ────────────────────────────────────────────────────────

/// Returns a canned [ModelMessage] for each call. Cycles when out of canned.
class FakeLLMClient extends LLMClient {
  final List<ModelMessage> canned;
  final List<int> tokensUsed;
  int generateCalls = 0;
  int streamCalls = 0;

  FakeLLMClient(this.canned, {this.tokensUsed = const []});

  ModelMessage _next() {
    final m = canned[generateCalls % canned.length];
    return m;
  }

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    final m = _next();
    generateCalls++;
    return m;
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    streamCalls++;
    final m = _next();
    return Stream<StreamingMessage>.fromIterable([
      StreamingMessage(modelMessage: m),
    ]);
  }
}

ModelMessage textReply(String text, {String model = 'fake-model'}) {
  return ModelMessage(
    textOutput: text,
    model: model,
    stopReason: 'stop',
    usage: ModelUsage(
      promptTokens: 10,
      completionTokens: 5,
      totalTokens: 15,
      model: model,
    ),
  );
}

// ─── Trial / TrialResult builders ───────────────────────────────────────────

Trial makeTrial({
  required String runName,
  required String suiteName,
  required String taskId,
  int trialIndex = 0,
  TrialStatus status = TrialStatus.passed,
  DateTime? startedAt,
  DateTime? endedAt,
}) {
  final start = startedAt ?? DateTime(2025, 1, 1);
  return Trial(
    runName: runName,
    suiteName: suiteName,
    taskId: taskId,
    trialIndex: trialIndex,
    startedAt: start,
    endedAt: endedAt ?? start.add(const Duration(seconds: 1)),
    status: status,
  );
}

Transcript emptyTranscript() => Transcript(
  messages: const [],
  toolCalls: const [],
  metrics: const TranscriptMetrics(nTurns: 0, nToolCalls: 0, nTotalTokens: 0),
);

TrialResult makeTrialResult({
  required String runName,
  required String suiteName,
  required String taskId,
  int trialIndex = 0,
  required List<Score> scores,
  Outcome? outcome,
  Transcript? transcript,
  TrialStatus? status,
  DateTime? startedAt,
}) {
  final passed = scores
      .where((s) => s.passed != null)
      .every((s) => s.passed == true);
  return TrialResult(
    trial: makeTrial(
      runName: runName,
      suiteName: suiteName,
      taskId: taskId,
      trialIndex: trialIndex,
      status: status ?? (passed ? TrialStatus.passed : TrialStatus.failed),
      startedAt: startedAt,
    ),
    transcript: transcript ?? emptyTranscript(),
    outcome: outcome ?? const Outcome(environmentState: {}),
    scores: scores,
  );
}

Score okScore(String name, {double value = 1.0}) =>
    Score(graderName: name, value: value, passed: true);

Score failScore(String name, {double value = 0.0, String? rationale}) => Score(
  graderName: name,
  value: value,
  passed: false,
  rationale: rationale ?? 'failed',
);

Score nullScore(String name, {String rationale = 'unknown'}) =>
    Score(graderName: name, value: null, passed: null, rationale: rationale);
