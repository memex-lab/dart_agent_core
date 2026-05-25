import 'dart:convert';
import 'dart:io';

import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../core/eval_task.dart';
import '../core/outcome.dart';
import '../core/transcript.dart';
import '../core/trial.dart';
import '../graders/score.dart';
import 'trace_exporter.dart';

/// Writes one JSON object per line to a file. Easy to grep, easy to
/// import into other tools.
///
/// Event format (top-level keys):
///   - `kind`: 'trial_start' | 'llm_call' | 'tool_call' | 'trial_end' | 'run_end'
///   - `at`: ISO-8601 timestamp
///   - all other keys are kind-specific
///
/// The exporter buffers writes; flush is called automatically on
/// [dispose] but can also be called manually.
class JsonlTraceExporter implements TraceExporter {
  final IOSink _sink;
  final File file;

  JsonlTraceExporter._(this.file, this._sink);

  factory JsonlTraceExporter(File file, {bool append = true}) {
    file.parent.createSync(recursive: true);
    final sink = file.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    return JsonlTraceExporter._(file, sink);
  }

  void _write(Map<String, dynamic> obj) {
    obj['at'] ??= DateTime.now().toIso8601String();
    _sink.writeln(jsonEncode(obj));
  }

  @override
  Future<void> onTrialStart(Trial trial, EvalTask task) async {
    _write({
      'kind': 'trial_start',
      'trial': trial.toJson(),
      'task': {
        'id': task.id,
        'description': task.description,
        'metadata': task.metadata,
      },
    });
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
    _write({
      'kind': 'llm_call',
      'trialId': trial.id.toJson(),
      'model': modelConfig.toJson(),
      'durationMs': duration.inMilliseconds,
      if (response != null) 'response': response.toJson(),
      if (error != null) 'error': error.toString(),
    });
  }

  @override
  Future<void> onToolCall({
    required Trial trial,
    required ToolCallRecord record,
  }) async {
    _write({
      'kind': 'tool_call',
      'trialId': trial.id.toJson(),
      'record': record.toJson(),
    });
  }

  @override
  Future<void> onTrialEnd({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required List<Score> scores,
  }) async {
    _write({
      'kind': 'trial_end',
      'trial': trial.toJson(),
      'transcript': transcript.toJson(),
      'outcome': outcome.toJson(),
      'scores': scores.map((s) => s.toJson()).toList(),
    });
  }

  @override
  Future<void> onRunEnd({
    required String runName,
    required String suiteName,
    required Map<String, double> aggregateScores,
  }) async {
    _write({
      'kind': 'run_end',
      'runName': runName,
      'suiteName': suiteName,
      'aggregateScores': aggregateScores,
    });
  }

  @override
  Future<void> dispose() async {
    await _sink.flush();
    await _sink.close();
  }
}
