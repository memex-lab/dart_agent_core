import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';

/// Web implementation of [StateStorage].
///
/// The browser has no filesystem, so this keeps serialized session state in a
/// process-wide in-memory map. State therefore persists for the lifetime of the
/// page/tab but is lost on reload. The serialized JSON round-trip is preserved
/// so behavior matches the native [FileStateStorage] as closely as possible.
///
/// For durable web storage, supply your own [StateStorage] backed by
/// `localStorage`/IndexedDB instead.
class FileStateStorage implements StateStorage {
  /// Directory path accepted for API parity with the native constructor. It is
  /// used only to namespace in-memory entries; no filesystem is touched.
  final String directoryPath;

  FileStateStorage(this.directoryPath);

  static final Map<String, String> _store = <String, String>{};

  String _key(String sessionId) => '$directoryPath/$sessionId';

  @override
  Future<AgentState> loadOrCreate(
    String sessionId,
    Map<String, dynamic>? initialMetadata, {
    bool overwrite = true,
  }) async {
    final state = _load(sessionId);
    if (state != null) {
      if (overwrite && initialMetadata != null) {
        state.metadata.addAll(initialMetadata);
      }
      return state;
    }
    return AgentState(sessionId: sessionId, metadata: initialMetadata);
  }

  @override
  Future<void> save(AgentState state) async {
    _store[_key(state.sessionId)] = jsonEncode(state.toJson());
  }

  @override
  Future<void> delete(String sessionId) async {
    _store.remove(_key(sessionId));
  }

  @override
  Future<bool> exist(String sessionId) async {
    return _store.containsKey(_key(sessionId));
  }

  AgentState? _load(String sessionId) {
    final raw = _store[_key(sessionId)];
    if (raw == null) return null;
    try {
      return AgentState.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }
}
