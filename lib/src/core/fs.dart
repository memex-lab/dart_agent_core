/// Platform-agnostic filesystem helpers.
///
/// On native platforms this resolves to a `dart:io`-backed implementation.
/// On the web (where `dart:io` is unavailable) it resolves to a stub that
/// degrades gracefully: directory/file lookups report "not found", reads throw
/// [UnsupportedError], and path helpers operate on plain strings.
///
/// This indirection is what allows the public `dart_agent_core.dart` library to
/// be analyzed as web-compatible: no `dart:io` import is reachable from it.
library;

export 'fs_stub.dart' if (dart.library.io) 'fs_io.dart';
