/// MCP (Model Context Protocol) support for dart_agent_core.
///
/// This module provides the bridge layer that allows Agents to interact
/// with MCP servers through a three-layer progressive disclosure pattern:
///
/// **Layer 1 - Server Discovery**: System prompt lists available MCP servers
///   by name + description only.
///
/// **Layer 2 - Tool/Resource Discovery**: LLM uses bridge tools
///   (mcp_list_tools, mcp_list_resources, etc.) to discover capabilities.
///
/// **Layer 3 - Execution**: LLM uses bridge tools (mcp_call_tool,
///   mcp_read_resource, etc.) to invoke specific server capabilities.
library;

export 'mcp_session.dart';
export 'mcp_manager.dart';
