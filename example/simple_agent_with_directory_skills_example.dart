import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:logging/logging.dart';

/// Example: directory skills + JavaScript execution + bridge channel.
///
/// 1) Creates a temporary skill directory with:
///    - `hello_script/SKILL.md`
///    - `hello_script/scripts/hello.js`
/// 2) Enables directory-skill mode via [skillDirectoryPaths].
/// 3) Enables JavaScript execution via [NodeJavaScriptRuntime].
/// 4) Registers a bridge channel (`local.greeting`) that JS can call.
void main() async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((LogRecord record) {
    print('[${record.level.name}] ${record.loggerName}: ${record.message}');
    if (record.error != null) print(record.error);
    if (record.stackTrace != null) print(record.stackTrace);
  });
  final skillRoot = await _createExampleSkillDirectory();
  try {
    final apiKey = Platform.environment['OPENAI_API_KEY'] ?? 'YOUR_API_KEY';
    final client = OpenAIClient(apiKey: apiKey);
    final modelConfig = ModelConfig(model: 'gpt-4o');

    final readTool = Tool(
      name: 'Read',
      description:
          'Read the contents of a file. Path can be absolute or relative to the workspace.',
      executable: (path) => _readFile(skillRoot, path as String),
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'File path to read'},
        },
        'required': ['path'],
      },
    );
    final lsTool = Tool(
      name: 'LS',
      description:
          'List entries in a directory. Path can be absolute or relative to the workspace.',
      executable: (path) => _listDir(skillRoot, path as String),
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Directory path to list'},
        },
        'required': ['path'],
      },
    );

    final agent = StatefulAgent(
      name: 'directory_skill_agent',
      client: client,
      modelConfig: modelConfig,
      state: AgentState.empty(),
      disableSubAgents: true,
      systemPrompts: [
        'You are a helpful assistant. Use directory skills when relevant.',
      ],
      tools: [readTool, lsTool],
      skillDirectoryPaths: [skillRoot],
      javaScriptRuntime: NodeJavaScriptRuntime(),
      skills: null,
    );

    // Register an extensible bridge channel callable from JS:
    agent.registerJavaScriptBridgeChannel('local.greeting', (payload, context) {
      final name = (payload['name'] ?? 'friend').toString();
      return {
        'message': 'Hello, $name! (from Dart bridge)',
        'agent': context.agentName,
      };
    });

    print('Running agent with directory skill + JS script...\\n');
    final responses = await agent.run([
      UserMessage.text(
        'Use the hello_script skill and run its JavaScript script to greet user "Dart".',
      ),
    ]);

    final last = responses.last;
    if (last is ModelMessage) {
      print('Agent response: ${last.textOutput}');
    } else {
      print('Last response: $last');
    }
  } finally {
    //await Directory(skillRoot).delete(recursive: true);
  }
}

Future<String> _createExampleSkillDirectory() async {
  final base = Directory.systemTemp;
  final skillRoot =
      '${base.path}${Platform.pathSeparator}dart_agent_dir_skills_example';
  final skillDir = '$skillRoot${Platform.pathSeparator}hello_script';
  final scriptsDir = '$skillDir${Platform.pathSeparator}scripts';
  await Directory(scriptsDir).create(recursive: true);

  final skillMd = File('$skillDir${Platform.pathSeparator}SKILL.md');
  await skillMd.writeAsString('''
---
name: hello_script
description: Greet users via JavaScript scripts and bridge channels.
metadata:
  short-description: JS greeting demo
---

# hello_script

When the user asks for scripted greeting behavior:

1. Execute `scripts/hello.js` with the `name` parameter using `RunJavaScript`.
2. Return both script output and bridge-assisted output.
''');

  final helloJs = File('$scriptsDir${Platform.pathSeparator}hello.js');
  await helloJs.writeAsString(r'''
module.exports = async function main(ctx) {
  const name = (ctx.args && ctx.args.name) || 'friend';
  const bridgeResult = await ctx.bridge.call('local.greeting', { name });
  return {
    script: `Hello from JS, ${name}!`,
    bridge: bridgeResult,
  };
};
''');

  return skillRoot;
}

String _readFile(String workspaceRoot, String path) {
  final normalized = _resolvePath(workspaceRoot, path);
  final file = File(normalized);
  if (!file.existsSync()) {
    return 'Error: file not found: $path';
  }
  try {
    return file.readAsStringSync();
  } catch (e) {
    return 'Error reading $path: $e';
  }
}

String _listDir(String workspaceRoot, String path) {
  final normalized = _resolvePath(workspaceRoot, path);
  final dir = Directory(normalized);
  if (!dir.existsSync()) {
    return 'Error: directory not found: $path';
  }
  try {
    final entries = dir.listSync();
    final names = entries
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .join(', ');
    return names.isEmpty ? '(empty)' : names;
  } catch (e) {
    return 'Error listing $path: $e';
  }
}

String _resolvePath(String workspaceRoot, String path) {
  final p = path.replaceAll('\\', '/').trim();
  if (p.startsWith('/') || (p.length >= 2 && p[1] == ':')) {
    return path;
  }
  return '$workspaceRoot${Platform.pathSeparator}${p.replaceAll('/', Platform.pathSeparator)}';
}
