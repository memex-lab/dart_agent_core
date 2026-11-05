import 'package:uuid/uuid.dart';

import '../../../core/llm_client.dart';
import '../../../core/message.dart';
import '../../core/eval_task.dart';
import '../../core/outcome.dart';
import '../../core/transcript.dart';
import '../../core/trial.dart';
import '../../graders/score.dart';
import '../trace_exporter.dart';
import 'langfuse_client.dart';
import 'langfuse_config.dart';
import 'langfuse_otlp.dart';

/// Streams trial observations to Langfuse v4 over OTLP.
///
/// One trial is one trace. The root span is exported once, when the trial
/// ends, with the task input and the outcome on that span. Each LLM call
/// is a `generation` span and each tool call is a `tool` span, parented to
/// the root. Scores go to `POST /api/public/scores`, not into the trace.
///
/// Trace name, user, session, tags, environment, and metadata are copied
/// onto every span. Langfuse v4 filters observations directly, so context
/// that exists only on the root is invisible on its children.
///
/// ```dart
/// final exporter = LangfuseTraceExporter(LangfuseConfig.fromEnv());
/// final runner = EvalRunner(
///   environment: env,
///   harnessFactory: harness,
///   exporters: [JsonlTraceExporter(file), exporter],
///   ...
/// );
/// ```
///
/// HTTP runs on a background queue. A Langfuse outage drops observations;
/// it does not fail the eval run.
class LangfuseTraceExporter implements TraceExporter {
  final LangfuseConfig config;
  final LangfuseClient _client;
  final _uuid = const Uuid();

  final Map<String, _OpenTrial> _open = {};

  LangfuseTraceExporter(this.config, {LangfuseClient? client})
    : _client = client ?? LangfuseClient(config);

  _OpenTrial _openFor(Trial trial) {
    return _open.putIfAbsent(trial.id.toString(), () {
      return _OpenTrial(
        traceId: newOtelTraceId(),
        spanId: newOtelSpanId(),
        name: '${trial.suiteName}/${trial.taskId}#${trial.trialIndex}',
        userId: trial.runName,
        sessionId: trial.suiteName,
        tags: [
          'suite:${trial.suiteName}',
          'task:${trial.taskId}',
          'run:${trial.runName}',
          'trial:${trial.trialIndex}',
        ],
        startedAt: trial.startedAt,
      );
    });
  }

  // ── TraceExporter callbacks ───────────────────────────────────────

  @override
  Future<void> onTrialStart(Trial trial, EvalTask task) async {
    final open = _openFor(trial);
    open.input = {
      'taskId': task.id,
      'description': task.description,
      'input': task.input,
    };
    open.traceMetadata = {
      'taskMetadata': task.metadata,
      'trialIndex': trial.trialIndex,
    };
  }

  @override
  Future<void> onLLMCall({
    required Trial trial,
    required List<LLMMessage> requestMessages,
    required ModelConfig modelConfig,
    required ModelMessage? response,
    required Duration duration,
    Object? error,
  }) async {
    final open = _openFor(trial);
    final endTime = DateTime.now();
    final startTime = endTime.subtract(duration);
    final usage = response?.usage;

    _client.enqueueSpan(
      _span(
        open: open,
        spanId: newOtelSpanId(),
        parentSpanId: open.spanId,
        name: 'llm.${modelConfig.model}',
        type: 'generation',
        start: startTime,
        end: endTime,
        input: requestMessages.map((m) => m.toJson()).toList(),
        output: response?.toJson(),
        model: modelConfig.model,
        modelParameters: _modelParameters(modelConfig),
        usage: usage == null
            ? null
            : {
                'input': usage.promptTokens,
                'output': usage.completionTokens,
                'total': usage.totalTokens,
              },
        level: error == null ? null : 'ERROR',
        statusMessage: error?.toString(),
      ),
    );
  }

  Map<String, dynamic> _modelParameters(ModelConfig c) {
    final out = <String, dynamic>{};
    if (c.temperature != null) out['temperature'] = c.temperature;
    if (c.maxTokens != null) out['maxTokens'] = c.maxTokens;
    if (c.topP != null) out['topP'] = c.topP;
    if (c.topK != null) out['topK'] = c.topK;
    return out;
  }

  @override
  Future<void> onToolCall({
    required Trial trial,
    required ToolCallRecord record,
  }) async {
    final open = _openFor(trial);
    _client.enqueueSpan(
      _span(
        open: open,
        spanId: newOtelSpanId(),
        parentSpanId: open.spanId,
        name: 'tool.${record.toolName}',
        type: 'tool',
        start: record.startedAt,
        end: record.endedAt,
        input: {
          'callId': record.callId,
          'toolName': record.toolName,
          'arguments': record.arguments,
        },
        output: record.result?.toJson(),
        level: record.isError ? 'ERROR' : null,
        statusMessage: record.isError
            ? (record.errorMessage ?? 'tool error')
            : null,
      ),
    );
  }

  @override
  Future<void> onTrialEnd({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required List<Score> scores,
  }) async {
    final open = _openFor(trial);
    open.traceMetadata.addAll({
      'status': trial.status.name,
      if (trial.failureReason != null) 'failureReason': trial.failureReason,
      'durationMs': trial.duration.inMilliseconds,
      'transcriptMetrics': transcript.metrics.toJson(),
    });
    _exportRoot(open, end: trial.endedAt, output: outcome.toJson());
    _open.remove(trial.id.toString());

    for (final score in scores) {
      if (score.value == null) continue;
      _client.enqueueScore(
        _score(
          traceId: open.traceId,
          observationId: open.spanId,
          name: score.graderName,
          value: score.value,
          comment: score.rationale,
          metadata: {
            if (score.passed != null) 'passed': score.passed,
            'assertions': score.assertions.map((a) => a.toJson()).toList(),
            ...score.metadata,
          },
          timestamp: trial.endedAt,
        ),
      );
    }
  }

  @override
  Future<void> onRunEnd({
    required String runName,
    required String suiteName,
    required Map<String, double> aggregateScores,
  }) async {
    final now = DateTime.now();
    final open = _OpenTrial(
      traceId: newOtelTraceId(),
      spanId: newOtelSpanId(),
      name: 'run-summary:$suiteName',
      userId: runName,
      sessionId: suiteName,
      tags: ['summary', 'run:$runName', 'suite:$suiteName'],
      startedAt: now,
    );
    open.traceMetadata = {'aggregateScores': aggregateScores};
    _exportRoot(open, end: now);
    for (final entry in aggregateScores.entries) {
      _client.enqueueScore(
        _score(
          traceId: open.traceId,
          observationId: open.spanId,
          name: entry.key,
          value: entry.value,
          timestamp: now,
        ),
      );
    }
  }

  @override
  Future<void> dispose() async {
    final pending = List<_OpenTrial>.from(_open.values);
    _open.clear();
    final now = DateTime.now();
    for (final open in pending) {
      final end = now.isBefore(open.startedAt) ? open.startedAt : now;
      _exportRoot(open, end: end);
    }
    await _client.shutdown();
  }

  void _exportRoot(_OpenTrial open, {required DateTime end, Object? output}) {
    _client.enqueueSpan(
      _span(
        open: open,
        spanId: open.spanId,
        name: open.name,
        type: 'span',
        start: open.startedAt,
        end: end.isBefore(open.startedAt) ? open.startedAt : end,
        input: open.input,
        output: output,
      ),
    );
  }

  Map<String, dynamic> _span({
    required _OpenTrial open,
    required String spanId,
    String? parentSpanId,
    required String name,
    required String type,
    required DateTime start,
    required DateTime end,
    Object? input,
    Object? output,
    String? model,
    Map<String, dynamic>? modelParameters,
    Map<String, Object?>? usage,
    String? level,
    String? statusMessage,
  }) {
    return langfuseSpan(
      traceId: open.traceId,
      spanId: spanId,
      parentSpanId: parentSpanId,
      name: name,
      type: type,
      start: start,
      end: end,
      traceName: open.name,
      userId: open.userId,
      sessionId: open.sessionId,
      tags: open.tags,
      environment: config.environment,
      release: config.release,
      version: config.version,
      input: input,
      output: output,
      traceMetadata: open.traceMetadata,
      model: model,
      modelParameters: modelParameters,
      usage: usage,
      level: level,
      statusMessage: statusMessage,
    );
  }

  Map<String, dynamic> _score({
    required String traceId,
    required String observationId,
    required String name,
    required Object? value,
    String? comment,
    Map<String, dynamic>? metadata,
    required DateTime timestamp,
  }) {
    return {
      'id': _uuid.v4(),
      'traceId': traceId,
      'observationId': observationId,
      'name': name,
      'value': value,
      'dataType': 'NUMERIC',
      'environment': config.environment,
      'comment': ?comment,
      if (metadata != null && metadata.isNotEmpty) 'metadata': metadata,
      'timestamp': timestamp.toUtc().toIso8601String(),
    };
  }
}

class _OpenTrial {
  final String traceId;
  final String spanId;
  final String name;
  final String userId;
  final String sessionId;
  final List<String> tags;
  final DateTime startedAt;
  Object? input;
  Map<String, dynamic> traceMetadata = {};

  _OpenTrial({
    required this.traceId,
    required this.spanId,
    required this.name,
    required this.userId,
    required this.sessionId,
    required this.tags,
    required this.startedAt,
  });
}
