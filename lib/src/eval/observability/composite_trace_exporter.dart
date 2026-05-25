import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../core/eval_task.dart';
import '../core/outcome.dart';
import '../core/transcript.dart';
import '../core/trial.dart';
import '../graders/score.dart';
import 'trace_exporter.dart';

/// Fans out events to multiple exporters. Order is preserved within each
/// exporter; cross-exporter order is not guaranteed.
class CompositeTraceExporter implements TraceExporter {
  final List<TraceExporter> exporters;

  CompositeTraceExporter(this.exporters);

  Future<void> _broadcast(Future<void> Function(TraceExporter e) op) async {
    await Future.wait(exporters.map(op));
  }

  @override
  Future<void> onTrialStart(Trial trial, EvalTask task) =>
      _broadcast((e) => e.onTrialStart(trial, task));

  @override
  Future<void> onLLMCall({
    required Trial trial,
    required List<LLMMessage> requestMessages,
    required ModelConfig modelConfig,
    required ModelMessage? response,
    required Duration duration,
    Object? error,
  }) => _broadcast(
    (e) => e.onLLMCall(
      trial: trial,
      requestMessages: requestMessages,
      modelConfig: modelConfig,
      response: response,
      duration: duration,
      error: error,
    ),
  );

  @override
  Future<void> onToolCall({
    required Trial trial,
    required ToolCallRecord record,
  }) => _broadcast((e) => e.onToolCall(trial: trial, record: record));

  @override
  Future<void> onTrialEnd({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required List<Score> scores,
  }) => _broadcast(
    (e) => e.onTrialEnd(
      trial: trial,
      transcript: transcript,
      outcome: outcome,
      scores: scores,
    ),
  );

  @override
  Future<void> onRunEnd({
    required String runName,
    required String suiteName,
    required Map<String, double> aggregateScores,
  }) => _broadcast(
    (e) => e.onRunEnd(
      runName: runName,
      suiteName: suiteName,
      aggregateScores: aggregateScores,
    ),
  );

  @override
  Future<void> dispose() => _broadcast((e) => e.dispose());
}
