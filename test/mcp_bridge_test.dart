import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDirectory;
  late McpManager manager;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync('mcp-bridge-');
    manager = McpManager();
  });

  tearDown(() async {
    await manager.dispose();
    tempDirectory.deleteSync(recursive: true);
  });

  Future<void> connectEcho() {
    return manager.connectAll([
      McpConnectionConfig(
        serverName: 'echo',
        type: McpTransportType.stdio,
        command: Platform.resolvedExecutable,
        args: ['run', 'test/fixtures/mcp_echo_server.dart'],
      ),
    ]);
  }

  test(
    'bridge tools list, call, read, and get prompt against a live server',
    () async {
      await connectEcho();

      expect(manager.hasServers, isTrue);
      expect(
        manager.getBridgeTools().map((tool) => tool.name),
        containsAll([
          'mcp_list_tools',
          'mcp_call_tool',
          'mcp_list_resources',
          'mcp_read_resource',
          'mcp_list_prompts',
          'mcp_get_prompt',
        ]),
      );
      expect(manager.buildMcpSystemPrompt()?.content, contains('echo'));

      final byName = {
        for (final tool in manager.getBridgeTools()) tool.name: tool,
      };

      final listed = await (byName['mcp_list_tools']!.executable as Function)({
        'server_name': 'echo',
      });
      expect(listed, contains('echo'));

      final called = await (byName['mcp_call_tool']!.executable as Function)({
        'server_name': 'echo',
        'tool_name': 'echo',
        'arguments': {'message': 'hi'},
      });
      expect(called, contains('echo:hi'));

      final resources =
          await (byName['mcp_list_resources']!.executable as Function)({
            'server_name': 'echo',
          });
      expect(resources, contains('notes'));

      final read = await (byName['mcp_read_resource']!.executable as Function)({
        'server_name': 'echo',
        'uri': 'test://notes',
      });
      expect(read, contains('resource-body'));

      final prompt = await (byName['mcp_get_prompt']!.executable as Function)({
        'server_name': 'echo',
        'prompt_name': 'greet',
        'arguments': {'name': 'Ada'},
      });
      expect(prompt, contains('Hello Ada'));
    },
  );

  test('agent run disconnects MCP sessions in finally', () async {
    await connectEcho();
    final client = _QueuedLLMClient([
      ModelMessage(model: 'fake-model', textOutput: 'done', stopReason: 'stop'),
    ]);
    final agent = StatefulAgent(
      name: 'mcp',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      mcpManager: manager,
      withGeneralPrinciples: false,
      disableSubAgents: true,
    );

    expect(
      agent.composeTools().map((tool) => tool.name),
      contains('mcp_call_tool'),
    );

    await agent.run([UserMessage.text('hello')], useStream: false);

    expect(manager.hasServers, isFalse);
    expect(
      agent.composeTools().map((tool) => tool.name),
      isNot(contains('mcp_call_tool')),
    );
  });
}

class _QueuedLLMClient extends LLMClient {
  final List<ModelMessage> replies;
  int generateCalls = 0;

  _QueuedLLMClient(this.replies);

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    return replies[generateCalls++];
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    return Stream.value(
      StreamingMessage(
        modelMessage: await generate(
          messages,
          tools: tools,
          toolChoice: toolChoice,
          modelConfig: modelConfig,
          jsonOutput: jsonOutput,
          cancelToken: cancelToken,
        ),
      ),
    );
  }
}
