import 'dart:io';

import '../../agent/controller.dart';
import '../../core/llm_client.dart';

/// Per-trial context provided by an [EvalEnvironment].
///
/// The context groups everything the [AgentHarnessFactory] needs to build
/// and run an agent under test: filesystem root, clock, LLM client (which
/// may be a recording/replay wrapper), application services, and a
/// preconfigured [AgentController] with trace exporters already attached.
class EvalContext {
  /// Workspace root (when the agent reads/writes files). May be null for
  /// agents that don't touch the filesystem.
  final Directory? workspaceDir;

  /// Time source. Use `clock.now()` instead of `DateTime.now()` so trials
  /// can be made deterministic. Implementations may wire this up via
  /// `package:clock` zones if they wish.
  final EvalClock clock;

  /// LLM client to use during the trial. May be a [RecordingLLMClient] or
  /// [ReplayLLMClient] depending on the run mode.
  final LLMClient llmClient;

  /// Controller pre-attached with trace exporters and listeners. The
  /// harness should reuse this controller, not create its own.
  final AgentController controller;

  /// Application services keyed by Type. Use [services] for typed lookup.
  final Map<Type, Object> servicesMap;

  /// Free-form metadata that flows into transcripts and reports.
  final Map<String, dynamic> metadata;

  EvalContext({
    this.workspaceDir,
    required this.clock,
    required this.llmClient,
    required this.controller,
    this.servicesMap = const {},
    this.metadata = const {},
  });

  T services<T>() => servicesMap[T] as T;
}

/// Time source abstraction. Production agents call `clock.now()` instead of
/// `DateTime.now()` so the eval runner can lock time per trial.
abstract class EvalClock {
  DateTime now();
}

/// Real clock — delegates to [DateTime.now].
class SystemEvalClock implements EvalClock {
  const SystemEvalClock();

  @override
  DateTime now() => DateTime.now();
}

/// Fixed clock — always returns [reference]. Useful for deterministic trials.
class FixedEvalClock implements EvalClock {
  final DateTime reference;

  const FixedEvalClock(this.reference);

  @override
  DateTime now() => reference;
}
