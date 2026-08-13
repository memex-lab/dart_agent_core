import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:test/test.dart';

void main() {
  group('MCP stdio integration', () {
    late Directory tempDirectory;
    late String startupLogPath;
    late McpSession session;

    setUp(() {
      tempDirectory = Directory.systemTemp.createTempSync('mcp-session-test-');
      startupLogPath = '${tempDirectory.path}/startup.log';
      session = McpSession(
        serverName: 'paged',
        config: McpConnectionConfig(
          serverName: 'paged',
          type: McpTransportType.stdio,
          command: Platform.resolvedExecutable,
          args: ['run', 'test/fixtures/mcp_paged_server.dart', startupLogPath],
          env: const {'PATH': 'configured-mcp-path'},
        ),
      );
    });

    tearDown(() async {
      await session.disconnect();
      tempDirectory.deleteSync(recursive: true);
    });

    test('starts one process and preserves configured environment', () async {
      await session.connect();

      final startups = File(startupLogPath).readAsLinesSync();
      expect(startups, hasLength(1));
      expect(startups.single.split('|').last, 'configured-mcp-path');
    });

    test('discovers every page of server capabilities', () async {
      await session.connect();

      expect(session.tools.map((tool) => tool.name), ['tool-one', 'tool-two']);
      expect(session.resources.map((resource) => resource.name), [
        'resource-one',
        'resource-two',
      ]);
      expect(session.prompts.map((prompt) => prompt.name), [
        'prompt-one',
        'prompt-two',
      ]);
    });
  });

  test('McpManager rejects duplicate server names before connecting', () async {
    final manager = McpManager();
    addTearDown(manager.dispose);
    final configs = [
      const McpConnectionConfig(
        serverName: 'duplicate',
        type: McpTransportType.stdio,
        command: 'never-started-one',
      ),
      const McpConnectionConfig(
        serverName: 'duplicate',
        type: McpTransportType.stdio,
        command: 'never-started-two',
      ),
    ];

    await expectLater(manager.connectAll(configs), throwsArgumentError);
  });
}
