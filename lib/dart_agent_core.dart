/// A mobile-first, local-first Dart library for building stateful, tool-using AI agents
/// with multi-provider LLM support (OpenAI, Gemini, AWS Bedrock).
///
/// This library provides a unified interface for interacting with various LLMs,
/// managing agent state, handling tool calls, and maintaining conversation history.
library;

export 'src/core/message.dart';
export 'src/core/tool.dart';
export 'src/core/llm_client.dart';
export 'src/core/event_bus.dart';

export 'src/llm/openai_client.dart';
export 'src/llm/gemini_client.dart';
export 'src/llm/responses_client.dart';
export 'src/llm/bedrock_claude_client.dart';
export 'src/llm/claude_client.dart';

export 'src/agent/state_storage.dart';
export 'src/agent/file_state_storage.dart';
export 'src/agent/stateful_agent.dart';
export 'src/agent/skill.dart';
export 'src/agent/planner.dart';
export 'src/agent/context_compressor.dart';
export 'src/agent/memory.dart';
export 'src/agent/controller.dart';
export 'src/agent/events.dart';
export 'src/agent/exception.dart';
export 'src/agent/sub_agent.dart';
export 'src/agent/loop_detector.dart';
