import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';

import 'mcp_session.dart';
import '../core/tool.dart';
import 'stateful_agent.dart';

final _logger = Logger('McpManager');

/// Manages multiple MCP server sessions and provides the bridge layer
/// between the Agent and MCP servers.
///
/// This is the central coordinator that:
/// 1. Manages the lifecycle of multiple [McpSession] instances
/// 2. Provides fixed bridge tools (mcp_list_tools, mcp_call_tool, etc.)
///    that the LLM uses to interact with MCP servers
/// 3. Generates system prompt sections for MCP server awareness
class McpManager {
  final Map<String, McpSession> _sessions = {};

  /// Whether any MCP servers are configured.
  bool get hasServers => _sessions.isNotEmpty;

  /// Get all connected server names.
  List<String> get serverNames => _sessions.keys.toList();

  /// Get the session for a specific server.
  McpSession? getSession(String serverName) => _sessions[serverName];

  /// Connect to multiple MCP servers from their configurations.
  Future<void> connectAll(List<McpConnectionConfig> configs) async {
    // Disconnect existing sessions first
    await disconnectAll();

    for (final config in configs) {
      final session = McpSession(serverName: config.serverName, config: config);

      try {
        await session.connect();
        _sessions[config.serverName] = session;
      } catch (e) {
        _logger.severe('[McpManager] Failed to connect to "${config.serverName}": $e');
        // Continue connecting other servers even if one fails
      }
    }

    _logger.info(
      '[McpManager] Connected to ${_sessions.length}/${configs.length} MCP servers',
    );
  }

  /// Disconnect from all MCP servers.
  Future<void> disconnectAll() async {
    for (final session in _sessions.values) {
      try {
        await session.disconnect();
      } catch (e) {
        _logger.warning('[McpManager] Error disconnecting: $e');
      }
    }
    _sessions.clear();
  }

  /// Build the system prompt section that informs the LLM about
  /// available MCP servers (Layer 1: progressive disclosure).
  ///
  /// Includes server name + short description so the LLM knows what each
  /// server is for, plus a capability count summary. Detailed tool lists,
  /// instructions, and resource URIs are NOT included — the LLM should use
  /// bridge tools to discover those on demand.
  SystemPromptPart? buildMcpSystemPrompt() {
    if (_sessions.isEmpty) return null;

    final lines = <String>[];
    lines.add('## MCP Servers');
    lines.add(
      'You have access to the following MCP (Model Context Protocol) servers. '
      'Use the MCP bridge tools to discover each server\'s tools, resources, '
      'and prompts on demand.',
    );
    lines.add('');
    lines.add('### Available Servers');
    for (final entry in _sessions.entries) {
      final name = entry.key;
      final session = entry.value;
      final toolCount = session.tools.length;
      final resourceCount = session.resources.length;
      final promptCount = session.prompts.length;
      final details = <String>[];
      if (toolCount > 0) details.add('$toolCount tools');
      if (resourceCount > 0) details.add('$resourceCount resources');
      if (promptCount > 0) details.add('$promptCount prompts');
      final detailStr = details.isNotEmpty ? ' (${details.join(', ')})' : '';
      lines.add('- **$name**$detailStr');

      // Include the server's own short description so the LLM knows its purpose,
      // but exclude lengthy instructions — those should be fetched on demand
      // via mcp_read_resource if the server exposes them as resources.
      final description = session.serverDescription;
      if (description != null && description.isNotEmpty) {
        lines.add('  $description');
      } else {
        lines.add('instructions: \n ${session.instructions}');
      }
    }
    lines.add('');
    lines.add('### How to use MCP Servers');
    lines.add('- **Discovery**: Use `mcp_list_tools` to get the full tool list for a server.');
    lines.add('- **Execution**: Use `mcp_call_tool` to invoke a discovered tool.');
    lines.add('- **Resources**: Use `mcp_list_resources` and `mcp_read_resource` for data access.');
    lines.add('- **Prompts**: Use `mcp_list_prompts` and `mcp_get_prompt` for prompt templates.');
    lines.add('- Always specify the `server_name` parameter when calling any MCP bridge tool.');

    return SystemPromptPart(
      name: 'mcp_servers',
      content: lines.join('\n'),
    );
  }

  /// Get the fixed bridge tools that the Agent registers.
  ///
  /// These are the tools the LLM uses to interact with MCP servers:
  /// - mcp_list_tools
  /// - mcp_call_tool
  /// - mcp_list_resources
  /// - mcp_read_resource
  /// - mcp_list_prompts
  /// - mcp_get_prompt
  List<Tool> getBridgeTools() {
    if (_sessions.isEmpty) return [];

    return [
      _buildMcpListToolsTool(),
      _buildMcpCallToolTool(),
      _buildMcpListResourcesTool(),
      _buildMcpReadResourceTool(),
      _buildMcpListPromptsTool(),
      _buildMcpGetPromptTool(),
    ];
  }

  Tool _buildMcpListToolsTool() {
    return Tool(
      name: 'mcp_list_tools',
      description:
          'List all tools available on a specific MCP server. '
          'Use this to discover what capabilities a server provides '
          'before calling specific tools.',
      parameters: {
        'type': 'object',
        'properties': {
          'server_name': {
            'type': 'string',
            'description': 'The name of the MCP server to list tools from.',
          },
        },
        'required': ['server_name'],
      },
      parameterMode: ToolParameterMode.object,
      executable: _mcpListTools,
    );
  }

  Tool _buildMcpCallToolTool() {
    return Tool(
      name: 'mcp_call_tool',
      description:
          'Call a specific tool on an MCP server. '
          'First use mcp_list_tools to discover available tools and their '
          'parameter schemas, then call this with the appropriate arguments.',
      parameters: {
        'type': 'object',
        'properties': {
          'server_name': {
            'type': 'string',
            'description': 'The name of the MCP server.',
          },
          'tool_name': {
            'type': 'string',
            'description': 'The name of the tool to call.',
          },
          'arguments': {
            'type': 'object',
            'description':
                'The arguments to pass to the tool, as a JSON object matching the tool\'s input schema.',
          },
        },
        'required': ['server_name', 'tool_name', 'arguments'],
      },
      parameterMode: ToolParameterMode.object,
      executable: _mcpCallTool,
    );
  }

  Tool _buildMcpListResourcesTool() {
    return Tool(
      name: 'mcp_list_resources',
      description:
          'List all resources available on a specific MCP server. '
          'Resources provide access to data like files, database records, etc.',
      parameters: {
        'type': 'object',
        'properties': {
          'server_name': {
            'type': 'string',
            'description': 'The name of the MCP server to list resources from.',
          },
        },
        'required': ['server_name'],
      },
      parameterMode: ToolParameterMode.object,
      executable: _mcpListResources,
    );
  }

  Tool _buildMcpReadResourceTool() {
    return Tool(
      name: 'mcp_read_resource',
      description:
          'Read a specific resource from an MCP server by its URI. '
          'Use mcp_list_resources first to discover available resource URIs.',
      parameters: {
        'type': 'object',
        'properties': {
          'server_name': {
            'type': 'string',
            'description': 'The name of the MCP server.',
          },
          'uri': {
            'type': 'string',
            'description': 'The URI of the resource to read.',
          },
        },
        'required': ['server_name', 'uri'],
      },
      parameterMode: ToolParameterMode.object,
      executable: _mcpReadResource,
    );
  }

  Tool _buildMcpListPromptsTool() {
    return Tool(
      name: 'mcp_list_prompts',
      description:
          'List all prompt templates available on a specific MCP server.',
      parameters: {
        'type': 'object',
        'properties': {
          'server_name': {
            'type': 'string',
            'description': 'The name of the MCP server to list prompts from.',
          },
        },
        'required': ['server_name'],
      },
      parameterMode: ToolParameterMode.object,
      executable: _mcpListPrompts,
    );
  }

  Tool _buildMcpGetPromptTool() {
    return Tool(
      name: 'mcp_get_prompt',
      description:
          'Get a specific prompt template from an MCP server. '
          'Use mcp_list_prompts first to discover available prompts and their argument requirements.',
      parameters: {
        'type': 'object',
        'properties': {
          'server_name': {
            'type': 'string',
            'description': 'The name of the MCP server.',
          },
          'prompt_name': {
            'type': 'string',
            'description': 'The name of the prompt to retrieve.',
          },
          'arguments': {
            'type': 'object',
            'description':
                'Optional arguments for the prompt template, as key-value pairs.',
          },
        },
        'required': ['server_name', 'prompt_name'],
      },
      parameterMode: ToolParameterMode.object,
      executable: _mcpGetPrompt,
    );
  }

  // --- Bridge tool executables ---

  Future<String> _mcpListTools(Map<String, dynamic> args) async {
    final serverName = args['server_name'] as String;
    final session = _sessions[serverName];
    if (session == null) {
      return 'Error: MCP server "$serverName" not found or not connected. Available servers: ${_sessions.keys.join(", ")}';
    }
    if (!session.isConnected) {
      return 'Error: MCP server "$serverName" is not connected.';
    }

    try {
      await session.refresh();
      final tools = session.tools;
      if (tools.isEmpty) {
        return 'No tools available on MCP server "$serverName".';
      }

      final buffer = StringBuffer();
      buffer.writeln('Tools available on MCP server "$serverName":');
      for (final tool in tools) {
        buffer.writeln('- **${tool.name}**: ${tool.description}');
        final schema = tool.inputSchema;
        if (schema.isNotEmpty) {
          buffer.writeln('  Input Schema: ${jsonEncode(schema)}');
        }
      }
      return buffer.toString();
    } catch (e) {
      return 'Error listing tools from "$serverName": $e';
    }
  }

  Future<String> _mcpCallTool(Map<String, dynamic> args) async {
    final serverName = args['server_name'] as String;
    final toolName = args['tool_name'] as String;
    final arguments = (args['arguments'] as Map<String, dynamic>?) ?? {};

    final session = _sessions[serverName];
    if (session == null) {
      return 'Error: MCP server "$serverName" not found or not connected.';
    }
    if (!session.isConnected) {
      return 'Error: MCP server "$serverName" is not connected.';
    }

    try {
      final result = await session.callTool(toolName, arguments);
      return result.toString();
    } catch (e) {
      return 'Error calling tool "$toolName" on "$serverName": $e';
    }
  }

  Future<String> _mcpListResources(Map<String, dynamic> args) async {
    final serverName = args['server_name'] as String;
    final session = _sessions[serverName];
    if (session == null) {
      return 'Error: MCP server "$serverName" not found or not connected.';
    }
    if (!session.isConnected) {
      return 'Error: MCP server "$serverName" is not connected.';
    }

    try {
      await session.refresh();
      final resources = session.resources;
      if (resources.isEmpty) {
        return 'No resources available on MCP server "$serverName".';
      }

      final buffer = StringBuffer();
      buffer.writeln('Resources available on MCP server "$serverName":');
      for (final resource in resources) {
        buffer.write('- **${resource.name}**: ${resource.uri}');
        if (resource.description != null && resource.description!.isNotEmpty) {
          buffer.write(' - ${resource.description}');
        }
        if (resource.mimeType != null) {
          buffer.write(' [${resource.mimeType}]');
        }
        buffer.writeln();
      }
      return buffer.toString();
    } catch (e) {
      return 'Error listing resources from "$serverName": $e';
    }
  }

  Future<String> _mcpReadResource(Map<String, dynamic> args) async {
    final serverName = args['server_name'] as String;
    final uri = args['uri'] as String;

    final session = _sessions[serverName];
    if (session == null) {
      return 'Error: MCP server "$serverName" not found or not connected.';
    }
    if (!session.isConnected) {
      return 'Error: MCP server "$serverName" is not connected.';
    }

    try {
      return await session.readResource(uri);
    } catch (e) {
      return 'Error reading resource "$uri" from "$serverName": $e';
    }
  }

  Future<String> _mcpListPrompts(Map<String, dynamic> args) async {
    final serverName = args['server_name'] as String;
    final session = _sessions[serverName];
    if (session == null) {
      return 'Error: MCP server "$serverName" not found or not connected.';
    }
    if (!session.isConnected) {
      return 'Error: MCP server "$serverName" is not connected.';
    }

    try {
      await session.refresh();
      final prompts = session.prompts;
      if (prompts.isEmpty) {
        return 'No prompts available on MCP server "$serverName".';
      }

      final buffer = StringBuffer();
      buffer.writeln('Prompts available on MCP server "$serverName":');
      for (final prompt in prompts) {
        buffer.write('- **${prompt.name}**');
        if (prompt.description != null && prompt.description!.isNotEmpty) {
          buffer.write(': ${prompt.description}');
        }
        if (prompt.arguments != null && prompt.arguments!.isNotEmpty) {
          buffer.write('\n  Arguments:');
          for (final arg in prompt.arguments!) {
            final req = arg.required == true ? ' (required)' : '';
            buffer.write(' ${arg.name}$req');
          }
        }
        buffer.writeln();
      }
      return buffer.toString();
    } catch (e) {
      return 'Error listing prompts from "$serverName": $e';
    }
  }

  Future<String> _mcpGetPrompt(Map<String, dynamic> args) async {
    final serverName = args['server_name'] as String;
    final promptName = args['prompt_name'] as String;
    final arguments = (args['arguments'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(k, v.toString()),
    );

    final session = _sessions[serverName];
    if (session == null) {
      return 'Error: MCP server "$serverName" not found or not connected.';
    }
    if (!session.isConnected) {
      return 'Error: MCP server "$serverName" is not connected.';
    }

    try {
      return await session.getPrompt(promptName, arguments);
    } catch (e) {
      return 'Error getting prompt "$promptName" from "$serverName": $e';
    }
  }

  /// Clean up all sessions.
  Future<void> dispose() async {
    await disconnectAll();
  }
}
