import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../../core/message.dart';

final _logger = Logger('RecordingStore');

/// Append-only key-value store for recorded LLM responses.
///
/// Per RFC §13.3 the store is intentionally append-only; it does not
/// support compaction or deletion. Operators who need to archive old
/// recordings should do so externally.
abstract class RecordingStore {
  /// Returns the recorded response for [hash], or null if no recording.
  Future<ModelMessage?> get(String hash);

  /// Stores a new recording under [hash]. If a recording already exists,
  /// implementations may overwrite or no-op (FileRecordingStore overwrites
  /// — useful when re-recording after a known-broken capture).
  Future<void> put(String hash, ModelMessage response);

  /// Force any buffered writes to flush. Called by the runner before
  /// exiting.
  Future<void> flush();
}

/// In-memory store; useful for tests of the eval subsystem itself and for
/// short-lived runs.
class InMemoryRecordingStore implements RecordingStore {
  final Map<String, ModelMessage> _store = {};

  @override
  Future<ModelMessage?> get(String hash) async => _store[hash];

  @override
  Future<void> put(String hash, ModelMessage response) async {
    _store[hash] = response;
  }

  @override
  Future<void> flush() async {}
}

/// Filesystem-backed store. One JSON file per (hash) under [rootDir].
///
/// Layout:
///   rootDir/
///     ab/cd/abcdef…json
///
/// The two-level prefix avoids huge directories on filesystems that don't
/// like 100k+ siblings.
class FileRecordingStore implements RecordingStore {
  final Directory rootDir;

  /// Cached writes, flushed lazily. Keyed by hash. We always re-read from
  /// disk on miss so multiple concurrent runs converge.
  final Map<String, ModelMessage> _pendingWrites = {};

  /// Pending future for a single in-flight flush. Subsequent calls await
  /// the same future to serialize disk writes.
  Future<void>? _inflightFlush;

  FileRecordingStore(this.rootDir) {
    if (!rootDir.existsSync()) {
      rootDir.createSync(recursive: true);
    }
  }

  File _fileFor(String hash) {
    final p1 = hash.substring(0, 2);
    final p2 = hash.substring(2, 4);
    return File('${rootDir.path}/$p1/$p2/$hash.json');
  }

  @override
  Future<ModelMessage?> get(String hash) async {
    final pending = _pendingWrites[hash];
    if (pending != null) return pending;
    final f = _fileFor(hash);
    if (!await f.exists()) return null;
    try {
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return ModelMessage.fromJson(json);
    } catch (e, st) {
      _logger.warning(
        'failed to decode recording ${hash.length > 8 ? '${hash.substring(0, 8)}...' : hash}',
        e,
        st,
      );
      return null;
    }
  }

  @override
  Future<void> put(String hash, ModelMessage response) async {
    _pendingWrites[hash] = response;
    // Trigger a background flush; callers don't need to await each put.
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _inflightFlush ??= Future.microtask(() async {
      try {
        await _doFlush();
      } finally {
        _inflightFlush = null;
      }
    });
  }

  Future<void> _doFlush() async {
    final batch = Map<String, ModelMessage>.from(_pendingWrites);
    if (batch.isEmpty) return;
    _pendingWrites.clear();
    for (final entry in batch.entries) {
      final f = _fileFor(entry.key);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(entry.value.toJson()));
    }
  }

  @override
  Future<void> flush() async {
    final inflight = _inflightFlush;
    if (inflight != null) await inflight;
    if (_pendingWrites.isNotEmpty) await _doFlush();
  }
}
