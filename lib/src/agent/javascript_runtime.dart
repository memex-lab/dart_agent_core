import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

/// Node.js-backed JavaScript runtime with bidirectional bridge calls over stdio.
///
/// This is the default runtime shipped in `dart_agent_core`.
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
    final timeoutDuration = timeout ?? const Duration(seconds: 30);
    final process = await Process.start(nodeCommand, [
      '-e',
      _bootstrapCode,
      scriptPath,
      jsonEncode(args ?? <String, dynamic>{}),
    ]);

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final completer = Completer<JavaScriptExecutionResult>();
    var settled = false;

    Future<void> complete(JavaScriptExecutionResult result) async {
      if (settled) return;
      settled = true;
      if (!completer.isCompleted) {
        completer.complete(result);
      }
      try {
        await process.stdin.flush();
      } catch (_) {}
      try {
        process.stdin.close();
      } catch (_) {}
      try {
        process.kill();
      } catch (_) {}
    }

    process.stderr
        .transform(utf8.decoder)
        .listen((chunk) => stderrBuffer.write(chunk));

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) async {
          stdoutBuffer.writeln(line);
          Map<String, dynamic>? packet;
          try {
            final decoded = jsonDecode(line);
            if (decoded is Map<String, dynamic>) {
              packet = decoded;
            } else if (decoded is Map) {
              packet = decoded.cast<String, dynamic>();
            }
          } catch (_) {
            // Ignore non-protocol stdout lines.
          }
          if (packet == null) return;

          final type = packet['type'] as String?;
          if (type == 'bridge_call') {
            final id = packet['id'] as String?;
            final channel = packet['channel'] as String?;
            final payload =
                (packet['payload'] as Map?)?.cast<String, dynamic>() ??
                <String, dynamic>{};
            if (id == null || channel == null) return;
            try {
              final result = await bridgeRegistry.invoke(
                channel,
                payload,
                bridgeContext,
              );
              final response = jsonEncode({
                'type': 'bridge_result',
                'id': id,
                'ok': true,
                'result': result,
              });
              process.stdin.writeln(response);
            } catch (e) {
              final response = jsonEncode({
                'type': 'bridge_result',
                'id': id,
                'ok': false,
                'error': e.toString(),
              });
              process.stdin.writeln(response);
            }
          } else if (type == 'result') {
            await complete(
              JavaScriptExecutionResult(
                success: true,
                result: packet['result'],
                stdout: stdoutBuffer.toString(),
                stderr: stderrBuffer.toString(),
              ),
            );
          } else if (type == 'error') {
            await complete(
              JavaScriptExecutionResult(
                success: false,
                error: (packet['error'] ?? 'Unknown JavaScript error')
                    .toString(),
                stdout: stdoutBuffer.toString(),
                stderr: stderrBuffer.toString(),
              ),
            );
          }
        });

    process.exitCode.then((code) async {
      if (settled) return;
      final stderr = stderrBuffer.toString().trim();
      if (code == 0) {
        await complete(
          JavaScriptExecutionResult(
            success: true,
            stdout: stdoutBuffer.toString(),
            stderr: stderr,
          ),
        );
      } else {
        await complete(
          JavaScriptExecutionResult(
            success: false,
            error: stderr.isEmpty
                ? 'Node runtime exited with code $code'
                : stderr,
            stdout: stdoutBuffer.toString(),
            stderr: stderr,
          ),
        );
      }
    });

    try {
      return await completer.future.timeout(
        timeoutDuration,
        onTimeout: () {
          final result = JavaScriptExecutionResult(
            success: false,
            error:
                'JavaScript execution timed out after ${timeoutDuration.inMilliseconds}ms',
            stdout: stdoutBuffer.toString(),
            stderr: stderrBuffer.toString(),
          );
          unawaited(complete(result));
          return result;
        },
      );
    } catch (e) {
      await complete(
        JavaScriptExecutionResult(
          success: false,
          error: e.toString(),
          stdout: stdoutBuffer.toString(),
          stderr: stderrBuffer.toString(),
        ),
      );
      return JavaScriptExecutionResult(
        success: false,
        error: e.toString(),
        stdout: stdoutBuffer.toString(),
        stderr: stderrBuffer.toString(),
      );
    }
  }
}

/*
Optional flutter_js implementation guidance (not compiled in this package):

1) Add dependencies in your Flutter app:
   dependencies:
     flutter_js: ^0.8.7

2) Implement JavaScriptRuntime using flutter_js and plug it into StatefulAgent.
   Tool input `args` is a JSON object string; StatefulAgent parses it before
   calling executeFile. The runtime receives `args` as Map<String, dynamic>?
   and exposes it to scripts as ctx.args.

   QuickJS (Android/Linux/Windows) does not resolve Promises automatically.
   You must use evaluateAsync + executePendingJob + handlePromise so that
   the event loop is driven until the script Promise settles. getJavascriptRuntime()
   already calls enableHandlePromises(); use it or call enableHandlePromises()
   yourself if you supply a custom runtime.

   Full example (tested with flutter_js 0.8.7):

   import 'dart:convert';
   import 'dart:io';
   import 'package:dart_agent_core/dart_agent_core.dart';
   import 'package:flutter_js/flutter_js.dart' as flutter_js;

   class FlutterJavaScriptRuntime implements JavaScriptRuntime {
     final flutter_js.JavascriptRuntime runtime;
     FlutterJavaScriptRuntime({flutter_js.JavascriptRuntime? runtime})
         : runtime = runtime ?? flutter_js.getJavascriptRuntime();

     @override
     Future<JavaScriptExecutionResult> executeFile({
       required String scriptPath,
       Map<String, dynamic>? args,
       Duration? timeout,
       required JavaScriptBridgeRegistry bridgeRegistry,
       required JavaScriptBridgeContext bridgeContext,
     }) async {
       final scriptFile = File(scriptPath);
       if (!scriptFile.existsSync()) {
         return JavaScriptExecutionResult(
           success: false,
           error: 'JavaScript file not found: \$scriptPath',
         );
       }

       final scriptSource = await scriptFile.readAsString();
       final execId = DateTime.now().microsecondsSinceEpoch.toString();
       final bridgeChannel = '__dart_agent_bridge_\$execId';
       final resultChannel = '__dart_agent_result_\$execId';
       final timeoutDuration = timeout ?? const Duration(seconds: 30);
       final stderrBuffer = StringBuffer();

       // Register bridge-call handler so JS scripts can call back into Dart.
       runtime.onMessage(bridgeChannel, (dynamic raw) async {
         final packet = _decode(raw);
         if (packet == null) return;
         final requestId = packet['id']?.toString();
         final channel = packet['channel']?.toString();
         final payload = (packet['payload'] as Map?)?.cast<String, dynamic>() ??
             <String, dynamic>{};
         if (requestId == null || channel == null) return;

         try {
           final value =
               await bridgeRegistry.invoke(channel, payload, bridgeContext);
           final js =
               "globalThis.__dartAgentBridgeResolve(\${jsonEncode(requestId)}, \${jsonEncode(value)});";
           final eval = runtime.evaluate(js);
           if (eval.isError) stderrBuffer.writeln(eval.stringResult);
         } catch (e) {
           final js =
               "globalThis.__dartAgentBridgeReject(\${jsonEncode(requestId)}, \${jsonEncode(e.toString())});";
           final eval = runtime.evaluate(js);
           if (eval.isError) stderrBuffer.writeln(eval.stringResult);
         }
       });

       final bootstrap = _buildBootstrap(
         scriptSource: scriptSource,
         args: args ?? const <String, dynamic>{},
         bridgeChannel: bridgeChannel,
         resultChannel: resultChannel,
       );

       // evaluateAsync → executePendingJob → handlePromise (flutter_js protocol)
       final evalResult = await runtime.evaluateAsync(bootstrap);
       if (evalResult.isError) {
         return JavaScriptExecutionResult(
             success: false, error: evalResult.stringResult);
       }

       runtime.executePendingJob();

       try {
         await runtime.handlePromise(evalResult, timeout: timeoutDuration);
       } catch (_) {
         // Promise rejected or timed out – fall through to read __dartAgentLastResult.
       }

       final result = _readLastResultFromRuntime(
         stderr: stderrBuffer.toString(),
       );
       if (result != null) return result;

       return JavaScriptExecutionResult(
         success: false,
         error:
             'JavaScript execution completed but no result was captured '
             '(timeout: \${timeoutDuration.inMilliseconds}ms)',
         stderr: stderrBuffer.toString(),
       );
     }

     Map<String, dynamic>? _decode(dynamic raw) {
       try {
         if (raw is Map<String, dynamic>) return raw;
         if (raw is Map) return raw.cast<String, dynamic>();
         if (raw is List && raw.isNotEmpty) {
           final first = raw.first;
           if (first is String && first.isNotEmpty) {
             final decoded = jsonDecode(first);
             if (decoded is Map<String, dynamic>) return decoded;
             if (decoded is Map) return decoded.cast<String, dynamic>();
           }
         }
         if (raw is String && raw.isNotEmpty) {
           final decoded = jsonDecode(raw);
           if (decoded is Map<String, dynamic>) return decoded;
           if (decoded is Map) return decoded.cast<String, dynamic>();
         }
       } catch (_) {}
       return null;
     }

     JavaScriptExecutionResult? _readLastResultFromRuntime({
       required String stderr,
     }) {
       final result = runtime.evaluate(
         'JSON.stringify(globalThis.__dartAgentLastResult ?? null)',
       );
       if (result.isError) return null;
       final raw = result.stringResult;
       if (raw.isEmpty || raw == 'null' || raw == 'undefined') return null;
       try {
         final decoded = jsonDecode(raw);
         if (decoded is! Map) return null;
         final packet = decoded.cast<String, dynamic>();
         final type = packet['type']?.toString();
         if (type == 'result') {
           return JavaScriptExecutionResult(
             success: true,
             result: packet['result'],
             stderr: stderr,
           );
         }
         if (type == 'error') {
           return JavaScriptExecutionResult(
             success: false,
             error: (packet['error'] ?? 'Unknown JavaScript error').toString(),
             stderr: stderr,
           );
         }
       } catch (_) {}
       return null;
     }

     String _buildBootstrap({
       required String scriptSource,
       required Map<String, dynamic> args,
       required String bridgeChannel,
       required String resultChannel,
     }) {
       final encodedScript = jsonEncode(scriptSource);
       final encodedArgs = jsonEncode(args);
       final encodedBridgeChannel = jsonEncode(bridgeChannel);
       final encodedResultChannel = jsonEncode(resultChannel);
       return """
(function () {
  const __bridgeChannel = \$encodedBridgeChannel;
  const __resultChannel = \$encodedResultChannel;
  const __script = \$encodedScript;
  const __args = \$encodedArgs;
  globalThis.__dartAgentLastResult = null;

  globalThis.__dartAgentBridgePending = globalThis.__dartAgentBridgePending || {};
  globalThis.__dartAgentBridgeCall = function(channel, payload) {
    return new Promise(function(resolve, reject) {
      var id = "req_" + Date.now() + "_" + Math.floor(Math.random() * 1000000);
      globalThis.__dartAgentBridgePending[id] = { resolve: resolve, reject: reject };
      sendMessage(__bridgeChannel, JSON.stringify({ id: id, channel: channel, payload: payload || {} }));
    });
  };
  globalThis.__dartAgentBridgeResolve = function(id, value) {
    var pending = globalThis.__dartAgentBridgePending[id];
    if (!pending) return;
    delete globalThis.__dartAgentBridgePending[id];
    pending.resolve(value);
  };
  globalThis.__dartAgentBridgeReject = function(id, error) {
    var pending = globalThis.__dartAgentBridgePending[id];
    if (!pending) return;
    delete globalThis.__dartAgentBridgePending[id];
    pending.reject(new Error(error || "bridge_error"));
  };

  return (async function () {
    try {
      (0, eval)(__script);
      var entry =
        (typeof run === "function" && run) ||
        (typeof main === "function" && main) ||
        (typeof globalThis["default"] === "function" && globalThis["default"]);
      if (typeof entry !== "function") {
        throw new Error("Script must define a function: run(ctx) or main(ctx)");
      }
      var result = await entry({ args: __args, bridge: { call: globalThis.__dartAgentBridgeCall } });
      globalThis.__dartAgentLastResult = { type: "result", result: result };
      return result;
    } catch (e) {
      var message = (e && e.stack) ? String(e.stack) : String(e);
      globalThis.__dartAgentLastResult = { type: "error", error: message };
    }
  })();
})();
""";
     }
   }

3) Pass into agent:
   final agent = StatefulAgent(
     ...,
     javaScriptRuntime: FlutterJavaScriptRuntime(),
   );

4) Register bridge channels:
   agent.registerJavaScriptBridgeChannel('local.greeting', (payload, context) {
     final name = (payload['name'] ?? 'friend').toString();
     return {'message': 'Hello, \$name'};
   });
*/

const String _bootstrapCode = r'''
const fs = require('fs');
const path = require('path');
const readline = require('readline');

const scriptPath = process.argv[1];
const rawArgs = process.argv[2] || '{}';
const scriptArgs = JSON.parse(rawArgs);

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
let seq = 0;
const pending = new Map();

function send(packet) {
  process.stdout.write(JSON.stringify(packet) + '\n');
}

function bridgeCall(channel, payload) {
  return new Promise((resolve, reject) => {
    const id = `b_${Date.now()}_${++seq}`;
    pending.set(id, { resolve, reject });
    send({
      type: 'bridge_call',
      id,
      channel,
      payload: payload ?? {},
    });
  });
}

rl.on('line', (line) => {
  let packet;
  try {
    packet = JSON.parse(line);
  } catch (_) {
    return;
  }
  if (!packet || packet.type !== 'bridge_result') return;
  const item = pending.get(packet.id);
  if (!item) return;
  pending.delete(packet.id);
  if (packet.ok) {
    item.resolve(packet.result);
  } else {
    item.reject(new Error(packet.error || 'bridge_error'));
  }
});

async function run() {
  try {
    const mod = require(path.resolve(scriptPath));
    const entry = mod.default || mod.main || mod.run || mod;
    if (typeof entry !== 'function') {
      throw new Error('Script must export a function (default/main/run)');
    }
    const result = await entry({
      args: scriptArgs,
      bridge: { call: bridgeCall },
    });
    send({ type: 'result', result });
    process.exit(0);
  } catch (e) {
    send({ type: 'error', error: String(e && e.stack ? e.stack : e) });
    process.exit(1);
  }
}

run();
''';
