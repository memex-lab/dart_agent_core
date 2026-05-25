import 'eval_context.dart';
import 'eval_task.dart';
import 'outcome.dart';
import 'transcript.dart';
import 'trial.dart';

/// Anthropic: an *agent harness* is the system that lets a model act as
/// an agent. The framework does not assume any specific implementation —
/// applications provide their own factory.
abstract class AgentHarnessFactory {
  /// Build a session for one trial. Implementations are responsible for:
  /// - Instantiating the agent (e.g. a StatefulAgent)
  /// - Wiring tools / skills
  /// - Subscribing to controller events for transcript collection
  Future<AgentHarnessSession> create({
    required EvalTask task,
    required Trial trial,
    required EvalContext context,
  });
}

/// One trial worth of agent execution. Always created via the factory.
abstract class AgentHarnessSession {
  /// Run the agent for this trial and produce both a transcript and an
  /// outcome.
  Future<({Transcript transcript, Outcome outcome})> run();

  /// Called after [run] regardless of outcome. Free any per-session
  /// resources (file handles, subscriptions, etc.).
  Future<void> dispose();
}
