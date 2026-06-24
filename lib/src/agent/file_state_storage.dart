/// File-based [StateStorage] implementation.
///
/// On native platforms this persists each session to a JSON file on disk. On
/// the web (no filesystem) it resolves to an in-memory implementation that
/// keeps state for the lifetime of the page; supply a custom [StateStorage] for
/// durable browser persistence.
library;

export 'file_state_storage_web.dart'
    if (dart.library.io) 'file_state_storage_io.dart';
