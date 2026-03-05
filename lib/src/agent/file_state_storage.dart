import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';

import 'package:dart_agent_core/dart_agent_core.dart';

/// A simple file-based implementation of [StateStorage].
/// Saves state to a JSON file in the specified directory, naming the file
/// based on the session ID (e.g., "$directory/$sessionId.json").
class FileStateStorage implements StateStorage {
  final Logger _logger = Logger('FileStateStorage');
  final Directory directory;

  FileStateStorage(this.directory);

  File _getFile(String sessionId) {
    return File('${directory.path}/$sessionId.json');
  }

  @override
  Future<AgentState> loadOrCreate(
    String sessionId,
    Map<String, dynamic>? initialMetadata, {
    bool overwrite = true,
  }) async {
    final state = await _load(sessionId);
    if (state != null) {
      if (overwrite) {
        if (initialMetadata != null) {
          state.metadata.addAll(initialMetadata);
        }
      }
      return state;
    }
    return AgentState(sessionId: sessionId, metadata: initialMetadata);
  }

  @override
  Future<void> save(AgentState state) async {
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    final file = _getFile(state.sessionId);
    await file.writeAsString(jsonEncode(state.toJson()));
  }

  @override
  Future<void> delete(String sessionId) async {
    final file = _getFile(sessionId);
    if (!await file.exists()) {
      return;
    }
    await file.delete();
  }

  @override
  Future<bool> exist(String sessionId) async {
    final file = _getFile(sessionId);
    return await file.exists();
  }

  Future<AgentState?> _load(String sessionId) async {
    final file = _getFile(sessionId);
    if (!await file.exists()) {
      return null;
    }
    try {
      final content = await file.readAsString();
      final json = jsonDecode(content);
      return AgentState.fromJson(json);
    } catch (e) {
      _logger.severe('❌ Error loading state for session $sessionId: $e');
      return null;
    }
  }
}
