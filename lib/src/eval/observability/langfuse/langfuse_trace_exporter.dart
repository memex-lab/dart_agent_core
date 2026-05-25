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
import 'langfuse_event.dart';

/// Streams trial events to Langfuse via `/api/public/ingestion`.
///
/// 映射方式（一个 trial = 一棵 langfuse trace）：
///
/// | dart_agent_core | Langfuse |
/// |---|---|
/// | [Trial] | `trace-create`：traceId = `<runName>:<taskId>:<trialIndex>` |
/// | LLM call | `generation-create`：observationId = uuid，parent = trace |
/// | Tool call | `span-create`：observationId = uuid，parent = trace |
/// | [Score] | `score-create`：traceId 关联到 trial 的 trace，dataType=NUMERIC |
/// | run-level aggregate | trace 上挂一个 `run-summary` trace + score |
///
/// 配置从 [LangfuseConfig.fromEnv] 或显式构造，支持云端 / 自托管：
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
/// 所有 HTTP 都跑在后台 queue 里。即使 langfuse server 临时挂了或网络
/// 抖动，也不会拖慢 eval run（最多丢几条 event）。
class LangfuseTraceExporter implements TraceExporter {
  final LangfuseConfig config;
  final LangfuseClient _client;
  final _uuid = const Uuid();

  /// runName + taskId + trialIndex → 当前 trace id（自己生成的稳定 id）。
  /// 之所以不直接用 trial id 字符串拼一拼，是因为 langfuse 服务端要求
  /// id 长这个样子 `^[a-zA-Z0-9_\-:.@/]+$`，而 trial 字符串里可能含 `#`。
  final Map<String, String> _traceIds = {};

  LangfuseTraceExporter(this.config, {LangfuseClient? client})
    : _client = client ?? LangfuseClient(config);

  String _traceIdFor(Trial trial) {
    final key = trial.id.toString();
    return _traceIds.putIfAbsent(key, () => _uuid.v4());
  }

  // ── TraceExporter callbacks ───────────────────────────────────────

  @override
  Future<void> onTrialStart(Trial trial, EvalTask task) async {
    final traceId = _traceIdFor(trial);
    _client.enqueue(
      LangfuseEvent(
        id: _uuid.v4(),
        type: 'trace-create',
        timestamp: trial.startedAt,
        body: {
          'id': traceId,
          'timestamp': trial.startedAt.toUtc().toIso8601String(),
          'name': '${trial.suiteName}/${trial.taskId}#${trial.trialIndex}',
          'environment': config.environment,
          'userId': trial.runName, // 在 dashboard 上按 run 过滤
          'sessionId': trial.suiteName,
          'tags': [
            'suite:${trial.suiteName}',
            'task:${trial.taskId}',
            'run:${trial.runName}',
            'trial:${trial.trialIndex}',
          ],
          'input': {
            'taskId': task.id,
            'description': task.description,
            'input': task.input,
          },
          'metadata': {
            'taskMetadata': task.metadata,
            'trialIndex': trial.trialIndex,
          },
          if (config.release != null) 'release': config.release,
          if (config.version != null) 'version': config.version,
        },
      ),
    );
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
    final traceId = _traceIdFor(trial);
    final endTime = DateTime.now();
    final startTime = endTime.subtract(duration);
    final usage = response?.usage;

    _client.enqueue(
      LangfuseEvent(
        id: _uuid.v4(),
        type: 'generation-create',
        timestamp: startTime,
        body: {
          'id': _uuid.v4(),
          'traceId': traceId,
          'environment': config.environment,
          'name': 'llm.${modelConfig.model}',
          'startTime': startTime.toUtc().toIso8601String(),
          'endTime': endTime.toUtc().toIso8601String(),
          'model': modelConfig.model,
          'modelParameters': _modelParameters(modelConfig),
          'input': requestMessages.map((m) => m.toJson()).toList(),
          if (response != null) 'output': response.toJson(),
          if (usage != null)
            'usage': {
              'input': usage.promptTokens,
              'output': usage.completionTokens,
              'total': usage.totalTokens,
              'unit': 'TOKENS',
            },
          if (error != null) ...{
            'level': 'ERROR',
            'statusMessage': error.toString(),
          },
        },
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
    final traceId = _traceIdFor(trial);
    _client.enqueue(
      LangfuseEvent(
        id: _uuid.v4(),
        type: 'span-create',
        timestamp: record.startedAt,
        body: {
          'id': _uuid.v4(),
          'traceId': traceId,
          'environment': config.environment,
          'name': 'tool.${record.toolName}',
          'startTime': record.startedAt.toUtc().toIso8601String(),
          'endTime': record.endedAt.toUtc().toIso8601String(),
          'input': {
            'callId': record.callId,
            'toolName': record.toolName,
            'arguments': record.arguments,
          },
          if (record.result != null) 'output': record.result!.toJson(),
          if (record.isError) ...{
            'level': 'ERROR',
            'statusMessage': record.errorMessage ?? 'tool error',
          },
        },
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
    final traceId = _traceIdFor(trial);

    // 用 trace-create 再写一次同 id 的 trace 来 merge：补 endTime / output /
    // 终态 metadata（30 天内 langfuse 服务端会按 id 合并）。
    _client.enqueue(
      LangfuseEvent(
        id: _uuid.v4(),
        type: 'trace-create',
        timestamp: trial.endedAt,
        body: {
          'id': traceId,
          'timestamp': trial.startedAt.toUtc().toIso8601String(),
          'name': '${trial.suiteName}/${trial.taskId}#${trial.trialIndex}',
          'environment': config.environment,
          'userId': trial.runName,
          'sessionId': trial.suiteName,
          'output': outcome.toJson(),
          'metadata': {
            'status': trial.status.name,
            if (trial.failureReason != null)
              'failureReason': trial.failureReason,
            'durationMs': trial.duration.inMilliseconds,
            'transcriptMetrics': transcript.metrics.toJson(),
          },
        },
      ),
    );

    // 每个 grader 一条 score-create。
    for (final s in scores) {
      if (s.value == null) continue; // null score 不上传（langfuse 不支持）
      _client.enqueue(
        LangfuseEvent(
          id: _uuid.v4(),
          type: 'score-create',
          timestamp: trial.endedAt,
          body: {
            'id': _uuid.v4(),
            'traceId': traceId,
            'environment': config.environment,
            'name': s.graderName,
            'value': s.value,
            'dataType': 'NUMERIC',
            if (s.rationale != null) 'comment': s.rationale,
            'metadata': {
              if (s.passed != null) 'passed': s.passed,
              'assertions': s.assertions.map((a) => a.toJson()).toList(),
              ...s.metadata,
            },
          },
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
    // 给 run 整体建一个 summary trace，把所有 aggregate score 挂上去。
    // 这样在 langfuse dashboard 可以按 userId=runName 筛出整次跑的概览。
    final summaryTraceId = _uuid.v4();
    final now = DateTime.now();
    _client.enqueue(
      LangfuseEvent(
        id: _uuid.v4(),
        type: 'trace-create',
        timestamp: now,
        body: {
          'id': summaryTraceId,
          'timestamp': now.toUtc().toIso8601String(),
          'name': 'run-summary:$suiteName',
          'environment': config.environment,
          'userId': runName,
          'sessionId': suiteName,
          'tags': ['summary', 'run:$runName', 'suite:$suiteName'],
          'metadata': {'aggregateScores': aggregateScores},
        },
      ),
    );
    for (final entry in aggregateScores.entries) {
      _client.enqueue(
        LangfuseEvent(
          id: _uuid.v4(),
          type: 'score-create',
          timestamp: now,
          body: {
            'id': _uuid.v4(),
            'traceId': summaryTraceId,
            'environment': config.environment,
            'name': entry.key,
            'value': entry.value,
            'dataType': 'NUMERIC',
          },
        ),
      );
    }
  }

  @override
  Future<void> dispose() async {
    await _client.shutdown();
  }
}
