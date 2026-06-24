/// HTTP utilities with platform-specific proxy configuration.
///
/// Resolves to a `dart:io`-backed implementation on native platforms and to a
/// no-op stub on the web (browsers manage proxying themselves).
library;

export 'http_util_web.dart' if (dart.library.io) 'http_util_io.dart';
