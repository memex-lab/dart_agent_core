import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

final _logger = Logger('McpSession');

/// Represents the connection state of an MCP server session.
enum McpConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

/// An MCP tool definition as returned by the server.
class McpToolDef {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const McpToolDef({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  factory McpToolDef.fromJson(Map<String, dynamic> json) {
    return McpToolDef(
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      inputSchema: (json['inputSchema'] as Map<String, dynamic>?) ?? {},
    );
  }
}

/// An MCP resource definition as returned by the server.
class McpResourceDef {
  final String uri;
  final String name;
  final String? description;
  final String? mimeType;

  const McpResourceDef({
    required this.uri,
    required this.name,
    this.description,
    this.mimeType,
  });

  factory McpResourceDef.fromJson(Map<String, dynamic> json) {
    return McpResourceDef(
      uri: json['uri'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      mimeType: json['mimeType'] as String?,
    );
  }
}

/// An MCP prompt definition as returned by the server.
class McpPromptDef {
  final String name;
  final String? description;
  final List<McpPromptArgument>? arguments;

  const McpPromptDef({
    required this.name,
    this.description,
    this.arguments,
  });

  factory McpPromptDef.fromJson(Map<String, dynamic> json) {
    return McpPromptDef(
      name: json['name'] as String,
      description: json['description'] as String?,
      arguments: (json['arguments'] as List<dynamic>?)
          ?.map((e) => McpPromptArgument.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class McpPromptArgument {
  final String name;
  final String? description;
  final bool? required;

  const McpPromptArgument({
    required this.name,
    this.description,
    this.required,
  });

  factory McpPromptArgument.fromJson(Map<String, dynamic> json) {
    return McpPromptArgument(
      name: json['name'] as String,
      description: json['description'] as String?,
      required: json['required'] as bool?,
    );
  }
}

/// Manages a single MCP client session connected to one MCP server.
///
/// Handles connection lifecycle, tool/resource/prompt discovery,
/// and tool execution.
class McpSession {
  final String serverName;
  final McpConnectionConfig config;
  McpConnectionState _state = McpConnectionState.disconnected;

  mcp.McpClient? _client;
  mcp.Transport? _transport;
  Process? _process;

  List<McpToolDef> _tools = [];
  List<McpResourceDef> _resources = [];
  List<McpPromptDef> _prompts = [];

  /// Server description from InitializeResult.serverInfo.description.
  String? _serverDescription;

  /// Instructions from InitializeResult.instructions.
  String? _instructions;

  McpConnectionState get state => _state;
  List<McpToolDef> get tools => List.unmodifiable(_tools);
  List<McpResourceDef> get resources => List.unmodifiable(_resources);
  List<McpPromptDef> get prompts => List.unmodifiable(_prompts);
  String? get serverDescription => _serverDescription;
  String? get instructions => _instructions;
  bool get isConnected => _state == McpConnectionState.connected;

  McpSession({
    required this.serverName,
    required this.config,
  });

  /// Connect to the MCP server and perform initial discovery.
  Future<void> connect() async {
    if (_state == McpConnectionState.connected ||
        _state == McpConnectionState.connecting) {
      return;
    }

    _state = McpConnectionState.connecting;
    _logger.info('[MCP:$serverName] Connecting...');

    try {
      switch (config.type) {
        case McpTransportType.stdio:
          await _connectStdio();
          break;
        case McpTransportType.http:
          await _connectHttp();
          break;
      }

      _state = McpConnectionState.connected;
      _logger.info('[MCP:$serverName] Connected successfully');

      // Perform initial discovery
      await _discover();
    } catch (e) {
      _state = McpConnectionState.error;
      _logger.severe('[MCP:$serverName] Connection failed: $e');
      rethrow;
    }
  }

  Future<void> _connectStdio() async {
    final command = config.command;
    if (command == null || command.isEmpty) {
      throw ArgumentError('stdio transport requires a command');
    }

    final args = config.args ?? [];
    final env = Map<String, String>.from(config.env ?? {});

    // Merge with current process environment
    env.addAll(Platform.environment);

    _logger.info('[MCP:$serverName] Starting process: $command ${args.join(" ")}');

    _process = await Process.start(command, args, environment: env);

    // Handle process errors
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      _logger.fine('[MCP:$serverName][stderr] $line');
    });

    _process!.exitCode.then((code) {
      _logger.warning('[MCP:$serverName] Process exited with code $code');
      _state = McpConnectionState.disconnected;
    });

    // Create Stdio transport
    final serverParams = mcp.StdioServerParameters(
      command: command,
      args: args,
      environment: env,
      includeParentEnvironment: true,
    );

    _transport = mcp.StdioClientTransport(serverParams);

    // Create client and connect
    _client = mcp.McpClient(
      mcp.Implementation(name: 'x_agent', version: '1.0.0'),
      options: mcp.McpClientOptions(
        capabilities: mcp.ClientCapabilities(),
      ),
    );

    await _client!.connect(_transport!);
  }

  Future<void> _connectHttp() async {
    final url = config.url;
    if (url == null || url.isEmpty) {
      throw ArgumentError('HTTP transport requires a URL');
    }

    final headers = Map<String, dynamic>.from(config.headers ?? {});
    final uri = Uri.parse(url);

    // If allowedHosts is configured, pass the first allowed host as
    // X-Forwarded-Host to help the MCP server (e.g. Wigolo) identify
    // the client and pass its host_not_allowed check.
    if (config.allowedHosts != null && config.allowedHosts!.isNotEmpty) {
      headers['X-Forwarded-Host'] = config.allowedHosts!.first;
    }

    _transport = mcp.StreamableHttpClientTransport(
      uri,
      opts: mcp.StreamableHttpClientTransportOptions(
        requestInit: {'headers': headers},
      ),
    );

    _client = mcp.McpClient(
      mcp.Implementation(name: 'x_agent', version: '1.0.0'),
      options: mcp.McpClientOptions(
        capabilities: mcp.ClientCapabilities(),
      ),
    );

    await _client!.connect(_transport!);
  }

  /// Discover tools, resources, and prompts from the server.
  Future<void> _discover() async {
    if (_client == null) return;

    // 获取服务器描述信息（从 InitializeResult）
    try {
      final serverVersion = _client!.getServerVersion();
      if (serverVersion != null) {
        _serverDescription = serverVersion.description;
        _logger.info('[MCP:$serverName] Server description: ${_serverDescription ?? "none"}');
      }
    } catch (_) {}

    try {
      _instructions = _client!.getInstructions();
      if (_instructions != null && _instructions!.isNotEmpty) {
        _logger.info('[MCP:$serverName] Server instructions available (${_instructions!.length} chars)');
      }
    } catch (_) {}

    try {
      final toolsResult = await _client!.listTools();
      _tools = toolsResult.tools
          .map((t) => McpToolDef.fromJson(t.toJson()))
          .toList();
      _logger.info('[MCP:$serverName] Discovered ${_tools.length} tools');
    } catch (e) {
      _logger.warning('[MCP:$serverName] Failed to list tools: $e');
    }

    try {
      final resourcesResult = await _client!.listResources();
      _resources = resourcesResult.resources
          .map((r) => McpResourceDef.fromJson(r.toJson()))
          .toList();
      _logger.info('[MCP:$serverName] Discovered ${_resources.length} resources');
    } catch (e) {
      _logger.warning('[MCP:$serverName] Failed to list resources: $e');
    }

    try {
      final promptsResult = await _client!.listPrompts();
      _prompts = promptsResult.prompts
          .map((p) => McpPromptDef.fromJson(p.toJson()))
          .toList();
      _logger.info('[MCP:$serverName] Discovered ${_prompts.length} prompts');
    } catch (e) {
      _logger.warning('[MCP:$serverName] Failed to list prompts: $e');
    }
  }

  /// Call a specific tool on the MCP server.
  Future<dynamic> callTool(String toolName, Map<String, dynamic> arguments) async {
    if (_client == null || _state != McpConnectionState.connected) {
      throw StateError('MCP session [$serverName] is not connected');
    }

    try {
      final request = mcp.CallToolRequest(
        name: toolName,
        arguments: arguments,
      );
      final result = await _client!.callTool(request);
      final content = _formatContent(result.content);
      if (result.isError == true) {
        return 'MCP tool error: $content';
      }
      return content;
    } catch (e) {
      return 'Error calling MCP tool "$toolName" on [$serverName]: $e';
    }
  }

  /// Read a specific resource from the MCP server.
  Future<String> readResource(String uri) async {
    if (_client == null || _state != McpConnectionState.connected) {
      throw StateError('MCP session [$serverName] is not connected');
    }

    try {
      final request = mcp.ReadResourceRequest(uri: uri);
      final result = await _client!.readResource(request);
      final buffer = StringBuffer();
      for (final c in result.contents) {
        if (c is mcp.TextResourceContents) {
          buffer.writeln(c.text);
        } else if (c is mcp.BlobResourceContents) {
          buffer.writeln('[Blob: ${c.mimeType ?? "unknown"}, ${c.blob.length} bytes]');
        } else {
          buffer.writeln(c.toJson().toString());
        }
      }
      return buffer.toString().trimRight();
    } catch (e) {
      return 'Error reading MCP resource "$uri" on [$serverName]: $e';
    }
  }

  /// Get a specific prompt from the MCP server.
  Future<String> getPrompt(String promptName, Map<String, String>? arguments) async {
    if (_client == null || _state != McpConnectionState.connected) {
      throw StateError('MCP session [$serverName] is not connected');
    }

    try {
      final request = mcp.GetPromptRequest(
        name: promptName,
        arguments: arguments,
      );
      final result = await _client!.getPrompt(request);
      final buffer = StringBuffer();
      for (final msg in result.messages) {
        buffer.write('[${msg.role.name}]: ');
        buffer.writeln(_formatSingleContent(msg.content));
      }
      return buffer.toString().trimRight();
    } catch (e) {
      return 'Error getting MCP prompt "$promptName" on [$serverName]: $e';
    }
  }

  /// Format a single MCP Content into a string.
  String _formatSingleContent(mcp.Content content) {
    switch (content) {
      case mcp.TextContent(:final text):
        return text;
      default:
        return content.toJson().toString();
    }
  }

  /// Format MCP content list into a string.
  String _formatContent(List<mcp.Content> contentList) {
    final buffer = StringBuffer();
    for (final c in contentList) {
      switch (c) {
        case mcp.TextContent(:final text):
          buffer.writeln(text);
        default:
          buffer.writeln(c.toJson().toString());
      }
    }
    return buffer.toString().trimRight();
  }

  /// Refresh discovery (re-list tools, resources, prompts).
  Future<void> refresh() async {
    if (_client == null || _state != McpConnectionState.connected) return;
    await _discover();
  }

  /// Disconnect from the MCP server and clean up resources.
  Future<void> disconnect() async {
    _logger.info('[MCP:$serverName] Disconnecting...');
    try {
      await _client?.close();
    } catch (_) {}
    _client = null;
    _transport = null;
    _process?.kill();
    _process = null;
    _tools = [];
    _resources = [];
    _prompts = [];
    _serverDescription = null;
    _instructions = null;
    _state = McpConnectionState.disconnected;
    _logger.info('[MCP:$serverName] Disconnected');
  }
}

/// Transport type for MCP connections.
enum McpTransportType {
  /// stdio protocol (command-line process)
  stdio,

  /// HTTP protocol (remote SSE / streamable HTTP)
  http,
}

/// Configuration for connecting to an MCP server.
class McpConnectionConfig {
  /// Human-readable name for this server (unique identifier).
  final String serverName;

  final McpTransportType type;
  final String? command;
  final List<String>? args;
  final Map<String, String>? env;
  final String? url;
  final Map<String, String>? headers;

  /// Hosts that are allowed to connect (for server-side host_not_allowed
  /// validation, e.g. Wigolo). Also passed as X-Forwarded-Host header.
  final List<String>? allowedHosts;

  const McpConnectionConfig({
    required this.serverName,
    required this.type,
    this.command,
    this.args,
    this.env,
    this.url,
    this.headers,
    this.allowedHosts,
  });
}
