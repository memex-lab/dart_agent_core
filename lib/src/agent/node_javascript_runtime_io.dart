import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/src/agent/javascript_runtime.dart';

/// Node.js-backed JavaScript runtime with bidirectional bridge calls over stdio.
///
/// This is the default runtime shipped in `dart_agent_core` on native
/// platforms.
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
