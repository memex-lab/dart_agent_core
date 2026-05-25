import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../core/eval_task.dart';
import '../core/outcome.dart';
import '../core/transcript.dart';
import '../core/trial.dart';
import '../graders/score.dart';

/// Streams trial events to an external observability backend.
///
/// "Trace" here is OTel-style (a tree of spans for one trial), distinct
/// from [Transcript] (the serialized record). A single trial produces:
///   - one `onTrialStart` call
///   - many `onLLMCall` and `onToolCall` interleaved
///   - one `onTrialEnd` call
///
/// Implementations must be safe to call from concurrent trials. Each
/// trial's events arrive in order but trials interleave with each other.
abstract class TraceExporter {
  /// Called when a trial starts.
  Future<void> onTrialStart(Trial trial, EvalTask task);

  /// Called for each LLM call. [response] is null on errors.
  Future<void> onLLMCall({
    required Trial trial,
    required List<LLMMessage> requestMessages,
    required ModelConfig modelConfig,
    required ModelMessage? response,
    required Duration duration,
    Object? error,
  });

  /// Called for each tool call.
  Future<void> onToolCall({
    required Trial trial,
    required ToolCallRecord record,
  });

  /// Called when trial finishes with the final transcript, outcome, and
  /// scores. Implementations should attach all scores here.
  Future<void> onTrialEnd({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required List<Score> scores,
  });

  /// Called when a dataset run completes. Implementations may use this
  /// hook to record run-level aggregate scores (pass@k, F1 …).
  Future<void> onRunEnd({
    required String runName,
    required String suiteName,
    required Map<String, double> aggregateScores,
  }) async {}

  /// Flush + release resources. Called once at the end of the run.
  Future<void> dispose();
}
