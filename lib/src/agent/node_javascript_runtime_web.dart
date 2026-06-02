import 'package:dart_agent_core/src/agent/javascript_runtime.dart';

/// Web stub for [NodeJavaScriptRuntime].
///
/// Browsers cannot spawn external processes, so executing a Node.js script is
/// not possible. This keeps the [NodeJavaScriptRuntime] API available on the
/// web and returns a failed [JavaScriptExecutionResult] instead of crashing.
class NodeJavaScriptRuntime implements JavaScriptRuntime {
  final String nodeCommand;

  NodeJavaScriptRuntime({this.nodeCommand = 'node'});

  @override
  Future<JavaScriptExecutionResult> executeFile({
    required String scriptPath,
    Map<String, dynamic>? args,
    Duration? timeout,
    required JavaScriptBridgeRegistry bridgeRegistry,
    required JavaScriptBridgeContext bridgeContext,
  }) async {
    return JavaScriptExecutionResult(
      success: false,
      error:
          'NodeJavaScriptRuntime is not supported on the web platform. '
          'Provide a web-compatible JavaScriptRuntime implementation instead.',
    );
  }
}
