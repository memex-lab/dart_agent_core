import 'dart:async';

import 'package:logging/logging.dart';

import '../graders/score.dart';
import '../llm/rate_limit_gate.dart';
import '../llm/recording_store.dart';
import '../observability/composite_trace_exporter.dart';
import '../observability/trace_exporter.dart';
import '../reporting/report_store.dart';
import 'agent_harness_factory.dart';
import 'eval_environment.dart';
import 'eval_run_report.dart';
import 'eval_suite.dart';
import 'eval_task.dart';
import 'outcome.dart';
import 'transcript.dart';
import 'transcript_recorder.dart';
import 'trial.dart';
import 'trial_result.dart';

final _logger = Logger('EvalRunner');

/// Runs evaluation suites with bounded concurrency and optional rate
/// limiting. See RFC §6.8 and §6.15.
class EvalRunner {
  final EvalEnvironment environment;
  final AgentHarnessFactory harnessFactory;
  final TraceExporter exporter;

  /// Optional. If set, the runner exposes the store to the harness via
  /// the EvalContext (the harness chooses to wrap its LLMClient or not).
  final RecordingStore? recordingStore;

  /// Optional persistent store for run reports. When set, [runSuite]
  /// automatically saves the final [EvalRunReport] for cross-run analysis
  /// (saturation, graduation, diff).
  final ReportStore? reportStore;

  /// Optional. The harness can pull this from EvalContext too.
  final RateLimitGate rateLimitGate;

  /// Default per-trial timeout. Tasks may override via [EvalTask.timeout].
  final Duration defaultTimeout;

  EvalRunner({
    required this.environment,
    required this.harnessFactory,
    List<TraceExporter> exporters = const [],
    this.recordingStore,
    this.reportStore,
    RateLimitGate? rateLimitGate,
    this.defaultTimeout = const Duration(minutes: 5),
  }) : exporter = exporters.length == 1
           ? exporters.first
           : CompositeTraceExporter(exporters),
       rateLimitGate = rateLimitGate ?? const NoopRateLimitGate();
}

extension EvalRunnerOps on EvalRunner {
  /// Run all tasks in [suite], honoring [concurrency] and per-task
  /// trialsPerRun. Returns the aggregated report.
  Future<EvalRunReport> runSuite({
    required String runName,
    required EvalSuite suite,
    int concurrency = 8,
    int? trialsOverride,
    bool Function(EvalTask)? filter,
  }) async {
    final problems = suite.validate();
    if (problems.isNotEmpty) {
      throw StateError(
        'Invalid suite "${suite.name}":\n${problems.join('\n')}',
      );
    }

    final tasks = filter == null
        ? suite.tasks
        : suite.tasks.where(filter).toList();

    // Build the work queue: (task, trialIndex) pairs.
    final queue = <_PlannedTrial>[];
    for (final task in tasks) {
      final trialsPerRun = trialsOverride ?? task.trialsPerRun;
      for (var i = 0; i < trialsPerRun; i++) {
        queue.add(_PlannedTrial(task: task, trialIndex: i));
      }
    }

    final results = <TrialResult>[];
    final startedAt = DateTime.now();

    // Bounded concurrency via a simple semaphore over an async queue.
    final iterator = queue.iterator;
    final pool = List<Future<void>>.generate(
      concurrency,
      (_) => _worker(
        iterator: iterator,
        suite: suite,
        runName: runName,
        results: results,
      ),
    );
    await Future.wait(pool);

    final endedAt = DateTime.now();

    // Run-level aggregate scores: report top-line metrics.
    final report = EvalRunReport(
      runName: runName,
      suite: suite,
      trials: results,
      startedAt: startedAt,
      endedAt: endedAt,
    );

    final aggregateScores = <String, double>{
      'task_pass_rate': report.taskPassRate,
      'trial_pass_rate': report.trialPassRate,
      ...report.graderMeans.map((k, v) => MapEntry('grader_mean.$k', v)),
    };

    await exporter.onRunEnd(
      runName: runName,
      suiteName: suite.name,
      aggregateScores: aggregateScores,
    );
    await exporter.dispose();
    if (recordingStore != null) await recordingStore!.flush();
    if (reportStore != null) await reportStore!.save(report);

    return report;
  }

  /// Convenience: run a single task. Useful for ad-hoc debugging or for
  /// rerunning a flaky task with extra trials.
  ///
  /// Internally wraps the task in a one-off [EvalSuite] of kind
  /// [SuiteKind.mixed]. The synthetic suite is **not** persisted to the
  /// report store (the run is for diagnosis, not for cross-run analysis).
  Future<List<TrialResult>> runTask({
    required String runName,
    required EvalTask task,
    required String agentName,
    int? trialsOverride,
  }) async {
    final tempSuite = EvalSuite(
      name: '_one_off/${task.id}',
      agentName: agentName,
      kind: SuiteKind.mixed,
      tasks: [task],
    );
    // Use a one-off runner that skips the persistent report store but
    // keeps every other behavior (exporters, recording, rate gate).
    final scopedRunner = EvalRunner(
      environment: environment,
      harnessFactory: harnessFactory,
      exporters: exporter is CompositeTraceExporter
          ? (exporter as CompositeTraceExporter).exporters
          : [exporter],
      recordingStore: recordingStore,
      // Intentionally null: this is a debug run, don't pollute history.
      // reportStore: null,
      rateLimitGate: rateLimitGate,
      defaultTimeout: defaultTimeout,
    );
    final report = await scopedRunner.runSuite(
      runName: runName,
      suite: tempSuite,
      concurrency: 1,
      trialsOverride: trialsOverride,
    );
    return report.trials;
  }
}

class _PlannedTrial {
  final EvalTask task;
  final int trialIndex;
  _PlannedTrial({required this.task, required this.trialIndex});
}

extension on EvalRunner {
  Future<void> _worker({
    required Iterator<_PlannedTrial> iterator,
    required EvalSuite suite,
    required String runName,
    required List<TrialResult> results,
  }) async {
    while (true) {
      _PlannedTrial planned;
      // The dart Iterator on List is single-thread safe within one isolate
      // because moveNext()/current are synchronous; we just need a critical
      // section that's atomic in the cooperative-scheduling sense.
      if (!iterator.moveNext()) return;
      planned = iterator.current;

      final result = await _runOneTrial(
        planned: planned,
        suite: suite,
        runName: runName,
      );
      results.add(result);
    }
  }

  Future<TrialResult> _runOneTrial({
    required _PlannedTrial planned,
    required EvalSuite suite,
    required String runName,
  }) async {
    final task = planned.task;
    final trialIndex = planned.trialIndex;

    final startedAt = DateTime.now();
    Trial trial = Trial(
      runName: runName,
      suiteName: suite.name,
      taskId: task.id,
      trialIndex: trialIndex,
      startedAt: startedAt,
      endedAt: startedAt, // updated below
      status: TrialStatus.errored,
    );

    try {
      await exporter.onTrialStart(trial, task);
    } catch (e, st) {
      _logger.warning('exporter.onTrialStart failed', e, st);
    }

    final timeout = task.timeout ?? defaultTimeout;
    Transcript? transcript;
    Outcome? outcome;
    var status = TrialStatus.errored;
    String? failureReason;

    final context = await environment.prepare(trial: trial, task: task);
    final recorder = EvalTranscriptRecorder(
      controller: context.controller,
      startedAt: startedAt,
      now: context.clock.now,
    );
    try {
      final session = await harnessFactory.create(
        task: task,
        trial: trial,
        context: context,
      );
      try {
        final r = await session.run().timeout(timeout);
        transcript = r.transcript;
        outcome = r.outcome;
        status = TrialStatus.passed; // tentative; graders decide below
      } on TimeoutException catch (e) {
        status = TrialStatus.timedOut;
        failureReason = 'Trial timed out after $timeout: $e';
      } catch (e, st) {
        status = TrialStatus.errored;
        failureReason = '$e';
        _logger.warning('trial run threw', e, st);
      } finally {
        await session.dispose();
      }
    } finally {
      // EventBus notifications are scheduled as microtasks by default. Give
      // controller listeners a chance to drain before snapshotting.
      await Future<void>.delayed(Duration.zero);
      final currentTranscript = transcript;
      if (currentTranscript == null || _isEmptyTranscript(currentTranscript)) {
        transcript = recorder.snapshot();
      }
      await recorder.dispose();
      await environment.dispose(context);
    }

    final endedAt = DateTime.now();

    // If the harness produced no transcript/outcome (timeout/error), make
    // placeholders so graders can still decide what to do.
    final effectiveTranscript =
        transcript ??
        Transcript(
          messages: const [],
          toolCalls: const [],
          metrics: const TranscriptMetrics(
            nTurns: 0,
            nToolCalls: 0,
            nTotalTokens: 0,
          ),
        );
    outcome ??= const Outcome(environmentState: {});

    // Run graders. Each grader returns a Score; runner does not enforce
    // pass/fail above the grader's own threshold.
    final scores = <Score>[];
    for (final grader in task.graders) {
      try {
        final score = await grader.grade(
          trial: trial,
          transcript: effectiveTranscript,
          outcome: outcome,
          context: context,
          referenceSolution: task.referenceSolution,
        );
        scores.add(score);
      } catch (e, st) {
        _logger.warning('grader ${grader.name} threw', e, st);
        scores.add(
          Score(
            graderName: grader.name,
            value: null,
            passed: null,
            rationale: 'grader exception: $e',
          ),
        );
      }
    }

    // Final trial status reflects graders.
    final passed = scores
        .where((s) => s.passed != null)
        .every((s) => s.passed == true);
    if (status == TrialStatus.passed && !passed) status = TrialStatus.failed;

    trial = Trial(
      runName: trial.runName,
      suiteName: trial.suiteName,
      taskId: trial.taskId,
      trialIndex: trial.trialIndex,
      startedAt: startedAt,
      endedAt: endedAt,
      status: status,
      failureReason: failureReason,
    );

    final result = TrialResult(
      trial: trial,
      transcript: effectiveTranscript,
      outcome: outcome,
      scores: scores,
    );

    try {
      await exporter.onTrialEnd(
        trial: trial,
        transcript: effectiveTranscript,
        outcome: outcome,
        scores: scores,
      );
    } catch (e, st) {
      _logger.warning('exporter.onTrialEnd failed', e, st);
    }

    return result;
  }

  bool _isEmptyTranscript(Transcript transcript) {
    final metrics = transcript.metrics;
    return transcript.messages.isEmpty &&
        transcript.toolCalls.isEmpty &&
        transcript.reasoningSteps.isEmpty &&
        transcript.events.isEmpty &&
        metrics.nTurns == 0 &&
        metrics.nToolCalls == 0 &&
        metrics.nTotalTokens == 0 &&
        metrics.timeToFirstToken == null &&
        metrics.timeToLastToken == null &&
        metrics.outputTokensPerSec == null;
  }
}
