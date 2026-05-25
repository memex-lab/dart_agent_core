/// Identifies one trial uniquely across runs.
class TrialId {
  final String runName;
  final String taskId;
  final int trialIndex;

  const TrialId({
    required this.runName,
    required this.taskId,
    required this.trialIndex,
  });

  @override
  String toString() => '$runName/$taskId#$trialIndex';

  Map<String, dynamic> toJson() => {
    'runName': runName,
    'taskId': taskId,
    'trialIndex': trialIndex,
  };

  factory TrialId.fromJson(Map<String, dynamic> json) {
    return TrialId(
      runName: json['runName'] as String,
      taskId: json['taskId'] as String,
      trialIndex: json['trialIndex'] as int,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TrialId &&
      other.runName == runName &&
      other.taskId == taskId &&
      other.trialIndex == trialIndex;

  @override
  int get hashCode => Object.hash(runName, taskId, trialIndex);
}

/// Final status of a trial.
enum TrialStatus { passed, failed, errored, timedOut, skipped }

/// Metadata about one attempt at a task.
class Trial {
  final String runName;
  final String suiteName;
  final String taskId;
  final int trialIndex;

  final DateTime startedAt;
  final DateTime endedAt;
  final TrialStatus status;

  /// Reason set when [status] is [TrialStatus.errored] or [TrialStatus.timedOut].
  final String? failureReason;

  Trial({
    required this.runName,
    required this.suiteName,
    required this.taskId,
    required this.trialIndex,
    required this.startedAt,
    required this.endedAt,
    required this.status,
    this.failureReason,
  });

  TrialId get id =>
      TrialId(runName: runName, taskId: taskId, trialIndex: trialIndex);

  /// Stable salt for record/replay caching, scoped per task+trial but
  /// **independent of run name** so that recordings made in run A can
  /// be replayed by run B. Format: `taskId#trialIndex`.
  ///
  /// Pass this into `RecordingLLMClient` / `ReplayLLMClient`'s
  /// `trialSalt` parameter from inside `EvalEnvironment.prepare()` to
  /// give each trial its own cache slot. Without it, trials of the
  /// same task collapse onto one cache entry and the framework
  /// silently destroys the non-determinism that pass^k / pass@k are
  /// supposed to measure.
  String get cacheSalt => '$taskId#$trialIndex';

  Duration get duration => endedAt.difference(startedAt);

  Map<String, dynamic> toJson() => {
    'runName': runName,
    'suiteName': suiteName,
    'taskId': taskId,
    'trialIndex': trialIndex,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
    'status': status.name,
    if (failureReason != null) 'failureReason': failureReason,
  };

  factory Trial.fromJson(Map<String, dynamic> json) {
    return Trial(
      runName: json['runName'] as String,
      suiteName: json['suiteName'] as String,
      taskId: json['taskId'] as String,
      trialIndex: json['trialIndex'] as int,
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: DateTime.parse(json['endedAt'] as String),
      status: TrialStatus.values.firstWhere((s) => s.name == json['status']),
      failureReason: json['failureReason'] as String?,
    );
  }
}
