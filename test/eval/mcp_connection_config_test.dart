import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:test/test.dart';

void main() {
  group('McpConnectionConfig', () {
    // ── stdio 配置 ────────────────────────────────────────────────

    group('stdio transport', () {
      test('basic stdio config with command only', () {
        final config = McpConnectionConfig(
          serverName: 'test-server',
          type: McpTransportType.stdio,
          command: 'node',
        );

        expect(config.serverName, 'test-server');
        expect(config.type, McpTransportType.stdio);
        expect(config.command, 'node');
        expect(config.args, isNull);
        expect(config.env, isNull);
        expect(config.url, isNull);
        expect(config.headers, isNull);
        expect(config.allowedHosts, isNull);
      });

      test('stdio config with command and args', () {
        final config = McpConnectionConfig(
          serverName: 'filesystem',
          type: McpTransportType.stdio,
          command: 'npx',
          args: ['-y', '@modelcontextprotocol/server-filesystem', '/tmp'],
        );

        expect(config.serverName, 'filesystem');
        expect(config.type, McpTransportType.stdio);
        expect(config.command, 'npx');
        expect(config.args, hasLength(3));
        expect(config.args?[0], '-y');
      });

      test('stdio config with environment variables', () {
        final config = McpConnectionConfig(
          serverName: 'env-server',
          type: McpTransportType.stdio,
          command: 'python',
          args: ['server.py'],
          env: {'API_KEY': 'secret', 'DEBUG': '1'},
        );

        expect(config.env, containsPair('API_KEY', 'secret'));
        expect(config.env, containsPair('DEBUG', '1'));
      });
    });

    // ── http 配置 ─────────────────────────────────────────────────

    group('http transport', () {
      test('basic http config with url', () {
        final config = McpConnectionConfig(
          serverName: 'remote-server',
          type: McpTransportType.http,
          url: 'https://example.com/mcp',
        );

        expect(config.serverName, 'remote-server');
        expect(config.type, McpTransportType.http);
        expect(config.url, 'https://example.com/mcp');
        expect(config.command, isNull);
        expect(config.args, isNull);
      });

      test('http config with headers', () {
        final config = McpConnectionConfig(
          serverName: 'auth-server',
          type: McpTransportType.http,
          url: 'https://api.example.com/mcp',
          headers: {'Authorization': 'Bearer token123'},
        );

        expect(config.headers, containsPair('Authorization', 'Bearer token123'));
      });

      test('http config with allowedHosts', () {
        final config = McpConnectionConfig(
          serverName: 'wigolo-server',
          type: McpTransportType.http,
          url: 'https://wigolo.example.com/mcp',
          allowedHosts: ['wigolo.example.com'],
        );

        expect(config.allowedHosts, ['wigolo.example.com']);
      });

      test('http config with full options', () {
        final config = McpConnectionConfig(
          serverName: 'full-http',
          type: McpTransportType.http,
          url: 'https://mcp.service.com',
          headers: {'X-Custom': 'value'},
          allowedHosts: ['mcp.service.com'],
        );

        expect(config.type, McpTransportType.http);
        expect(config.url, 'https://mcp.service.com');
        expect(config.headers, containsPair('X-Custom', 'value'));
        expect(config.allowedHosts, contains('mcp.service.com'));
      });
    });

    // ── 服务器名称唯一性 ─────────────────────────────────────────

    group('server name uniqueness', () {
      test('same server name for different transports is allowed at '
          'config level (uniqueness enforced by McpManager)', () {
        final stdioConfig = McpConnectionConfig(
          serverName: 'shared-name',
          type: McpTransportType.stdio,
          command: 'node',
        );
        final httpConfig = McpConnectionConfig(
          serverName: 'shared-name',
          type: McpTransportType.http,
          url: 'https://example.com/mcp',
        );

        expect(stdioConfig.serverName, httpConfig.serverName);
        expect(stdioConfig.type, isNot(httpConfig.type));
      });
    });

    // ── 边界情况 ─────────────────────────────────────────────────

    group('edge cases', () {
      test('empty server name is allowed at config level', () {
        final config = McpConnectionConfig(
          serverName: '',
          type: McpTransportType.stdio,
          command: 'node',
        );
        expect(config.serverName, '');
      });

      test('args can be an empty list', () {
        final config = McpConnectionConfig(
          serverName: 'no-args',
          type: McpTransportType.stdio,
          command: 'my-tool',
          args: [],
        );
        expect(config.args, isEmpty);
      });

      test('env can be an empty map', () {
        final config = McpConnectionConfig(
          serverName: 'no-env',
          type: McpTransportType.stdio,
          command: 'my-tool',
          env: {},
        );
        expect(config.env, isEmpty);
      });
    });
  });

  // ── McpTransportType 枚举 ──────────────────────────────────────

  group('McpTransportType', () {
    test('has two values: stdio and http', () {
      expect(McpTransportType.values, hasLength(2));
      expect(
        McpTransportType.values,
        containsAll([McpTransportType.stdio, McpTransportType.http]),
      );
    });

    test('McpTransportType.stdio.toString() contains "stdio"', () {
      expect(McpTransportType.stdio.toString(), contains('stdio'));
    });

    test('McpTransportType.http.toString() contains "http"', () {
      expect(McpTransportType.http.toString(), contains('http'));
    });
  });
}
