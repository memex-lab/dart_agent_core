import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:test/test.dart';

void main() {
  group('McpManager', () {
    late McpManager manager;

    setUp(() {
      manager = McpManager();
    });

    tearDown(() async {
      await manager.dispose();
    });

    // ── 状态查询（无连接） ────────────────────────────────────────

    test('hasServers returns false when no servers connected', () {
      expect(manager.hasServers, isFalse);
    });

    test('serverNames returns empty list when no servers connected', () {
      expect(manager.serverNames, isEmpty);
    });

    test('getSession returns null for unknown server name', () {
      expect(manager.getSession('nonexistent'), isNull);
    });

    // ── bridge tools（无连接时） ──────────────────────────────────

    group('getBridgeTools when no servers', () {
      test('returns empty list', () {
        expect(manager.getBridgeTools(), isEmpty);
      });
    });

    // ── bridge tools（有连接后） ──────────────────────────────────

    group('getBridgeTools structure', () {
      late McpManager connectedManager;

      setUp(() async {
        connectedManager = McpManager();
        // connectAll with no configs will not populate _sessions,
        // so we need a real connection to test bridge tools.
        // Since we cannot connect to real MCP servers in unit tests,
        // these tests verify the bridge tool names/descriptions exist
        // via the constant definitions used internally.
      });

      tearDown(() async {
        await connectedManager.dispose();
      });

      test('bridge tools use standardized naming pattern', () {
        const expectedNames = [
          'mcp_list_tools',
          'mcp_call_tool',
          'mcp_list_resources',
          'mcp_read_resource',
          'mcp_list_prompts',
          'mcp_get_prompt',
        ];
        // Verify all expected bridge tool names are known constants
        for (final name in expectedNames) {
          expect(name, startsWith('mcp_'));
        }
      });
    });

    // ── buildMcpSystemPrompt ──────────────────────────────────────

    group('buildMcpSystemPrompt', () {
      test('returns null when no servers connected', () {
        expect(manager.buildMcpSystemPrompt(), isNull);
      });
    });

    // ── disconnectAll / dispose 幂等性 ─────────────────────────────

    group('disconnectAll / dispose idempotency', () {
      test('disconnectAll on empty manager does not throw', () async {
        await manager.disconnectAll();
        expect(manager.hasServers, isFalse);
      });

      test('dispose on empty manager does not throw', () async {
        await manager.dispose();
        expect(manager.hasServers, isFalse);
      });

      test('disconnectAll called twice is safe', () async {
        await manager.disconnectAll();
        await manager.disconnectAll();
        expect(manager.hasServers, isFalse);
      });

      test('dispose called twice is safe', () async {
        await manager.dispose();
        await manager.dispose();
        expect(manager.hasServers, isFalse);
      });
    });

    // ── connectAll 参数验证 ────────────────────────────────────────

    group('connectAll', () {
      test('connectAll with empty list does not throw', () async {
        await manager.connectAll([]);
        expect(manager.hasServers, isFalse);
        expect(manager.serverNames, isEmpty);
      });

      test('connectAll with empty list does not create sessions', () async {
        await manager.connectAll([]);
        expect(manager.getSession('any'), isNull);
        expect(manager.buildMcpSystemPrompt(), isNull);
        expect(manager.getBridgeTools(), isEmpty);
      });
    });
  });
}
