import 'package:dart_agent_core/src/agent/stateful_agent.dart';

abstract class StateStorage {
  Future<AgentState> loadOrCreate(
    String sessionId,
    Map<String, dynamic>? initialMetadata,
  );
  Future<void> save(AgentState state);
  Future<void> delete(String sessionId);
  Future<bool> exist(String sessionId);
}
