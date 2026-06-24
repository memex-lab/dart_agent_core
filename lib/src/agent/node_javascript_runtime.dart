/// The default [JavaScriptRuntime] implementation.
///
/// Resolves to a Node.js-backed runtime (via `Process.start`) on native
/// platforms and to a stub on the web, where spawning processes is impossible.
library;

export 'node_javascript_runtime_web.dart'
    if (dart.library.io) 'node_javascript_runtime_io.dart';
