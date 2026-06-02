import 'dart:async';

export 'node_javascript_runtime.dart';

typedef JavaScriptBridgeHandler =
    FutureOr<dynamic> Function(
      Map<String, dynamic> payload,
      JavaScriptBridgeContext context,
    );

class JavaScriptBridgeContext {
  final String agentName;
  final String sessionId;
  final String scriptPath;
  final Map<String, dynamic> scriptArgs;

  JavaScriptBridgeContext({
    required this.agentName,
    required this.sessionId,
    required this.scriptPath,
    required this.scriptArgs,
  });
}

class JavaScriptBridgeRegistry {
  final Map<String, JavaScriptBridgeHandler> _handlers = {};

  void register(String channel, JavaScriptBridgeHandler handler) {
    _handlers[channel] = handler;
  }

  void unregister(String channel) {
    _handlers.remove(channel);
  }

  bool contains(String channel) => _handlers.containsKey(channel);

  List<String> channels() {
    final names = _handlers.keys.toList()..sort();
    return names;
  }

  Future<dynamic> invoke(
    String channel,
    Map<String, dynamic> payload,
    JavaScriptBridgeContext context,
  ) async {
    final handler = _handlers[channel];
    if (handler == null) {
      throw StateError('Bridge channel not found: $channel');
    }
    return await handler(payload, context);
  }
}

class JavaScriptExecutionResult {
  final bool success;
  final dynamic result;
  final String? error;
  final String stdout;
  final String stderr;

  JavaScriptExecutionResult({
    required this.success,
    this.result,
    this.error,
    this.stdout = '',
    this.stderr = '',
  });
}

abstract class JavaScriptRuntime {
  Future<JavaScriptExecutionResult> executeFile({
    required String scriptPath,
    Map<String, dynamic>? args,
    Duration? timeout,
    required JavaScriptBridgeRegistry bridgeRegistry,
    required JavaScriptBridgeContext bridgeContext,
  });
}
