import 'dart:convert';
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

  test('MCP protocol errors retain isError through the agent loop', () async {
    await connectEcho();
    final client = _QueuedLLMClient([
      ModelMessage(
        model: 'fake-model',
        stopReason: 'tool_calls',
        functionCalls: [
          for (final entry in {
            'reported': ('mcp_call_tool', {'tool_name': 'fail'}),
            'missing': ('mcp_call_tool', {'tool_name': 'missing'}),
            'resource': ('mcp_read_resource', {'uri': 'test://missing'}),
            'prompt': ('mcp_get_prompt', {'prompt_name': 'missing'}),
            'success': ('mcp_call_tool', {'tool_name': 'error_text'}),
          }.entries)
            FunctionCall(
              id: entry.key,
              name: entry.value.$1,
              arguments: jsonEncode({'server_name': 'echo', ...entry.value.$2}),
            ),
        ],
      ),
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
    await agent.run([UserMessage.text('check errors')], useStream: false);
    final results = agent.state.history.messages
        .whereType<FunctionExecutionResultMessage>()
        .single
        .results;
    expect(results, hasLength(5));
    for (final result in results) {
      expect(result.isError, result.id != 'success', reason: result.id);
    }
    expect(
      (results.firstWhere((r) => r.id == 'reported').content.single as TextPart)
          .text,
      contains('request rejected'),
    );
    expect(
      (results.firstWhere((r) => r.id == 'success').content.single as TextPart)
          .text,
      startsWith('Error:'),
    );
  });

  test(
    'all bridge tools mark missing and disconnected servers as errors',
    () async {
      await connectEcho();
      final tools = manager.getBridgeTools();
      await manager.getSession('echo')!.disconnect();
      for (final serverName in ['missing', 'echo']) {
        for (final tool in tools) {
          final result = await tool.executable!({
            'server_name': serverName,
            'tool_name': 'echo',
            'uri': 'test://notes',
            'prompt_name': 'greet',
          });
          expect(result, isA<McpOperationResult>());
          expect(tool.resultIsError!(result), isTrue, reason: tool.name);
        }
      }
    },
  );

  test(
    'legacy session methods keep text results while structured methods expose errors',
    () async {
      await connectEcho();
      final session = manager.getSession('echo')!;
      expect(await session.callTool('echo', {'message': 'hi'}), 'echo:hi');
      expect(await session.readResource('test://notes'), 'resource-body');
      expect(
        await session.getPrompt('greet', {'name': 'Ada'}),
        contains('Hello Ada'),
      );
      expect(
        await session.callTool('fail', {}),
        'MCP tool error: request rejected',
      );
      final result = await session.callToolResult('fail', {});
      expect(result.isError, isTrue);
      expect(result.text, 'MCP tool error: request rejected');
    },
  );

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
      expect(listed.toString(), contains('echo'));

      final called = await (byName['mcp_call_tool']!.executable as Function)({
        'server_name': 'echo',
        'tool_name': 'echo',
        'arguments': {'message': 'hi'},
      });
      expect(called.toString(), contains('echo:hi'));

      final resources =
          await (byName['mcp_list_resources']!.executable as Function)({
            'server_name': 'echo',
          });
      expect(resources.toString(), contains('notes'));

      final read = await (byName['mcp_read_resource']!.executable as Function)({
        'server_name': 'echo',
        'uri': 'test://notes',
      });
      expect(read.toString(), contains('resource-body'));

      final prompt = await (byName['mcp_get_prompt']!.executable as Function)({
        'server_name': 'echo',
        'prompt_name': 'greet',
        'arguments': {'name': 'Ada'},
      });
      expect(prompt.toString(), contains('Hello Ada'));
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

  test(
    'unknown MCP server makes FunctionExecutionResult.isError true',
    () async {
      await connectEcho();
      final state = AgentState.empty();
      final client = _QueuedLLMClient([
        _mcpListToolsCall(id: 'unknown-1', serverName: 'missing'),
        ModelMessage(
          model: 'fake-model',
          textOutput: 'done',
          stopReason: 'stop',
        ),
      ]);
      final agent = StatefulAgent(
        name: 'mcp',
        client: client,
        modelConfig: ModelConfig(model: 'fake-model'),
        state: state,
        mcpManager: manager,
        withGeneralPrinciples: false,
        disableSubAgents: true,
      );

      await agent.run([UserMessage.text('list missing')], useStream: false);

      final result = state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .single
          .results
          .single;
      expect(result.isError, isTrue);
      expect((result.content.single as TextPart).text, startsWith('Error:'));
    },
  );

  test(
    'disconnected MCP server makes FunctionExecutionResult.isError true',
    () async {
      await connectEcho();
      await manager.getSession('echo')!.disconnect();
      expect(manager.hasServers, isTrue);
      expect(manager.getSession('echo')!.isConnected, isFalse);

      final state = AgentState.empty();
      final client = _QueuedLLMClient([
        _mcpListToolsCall(id: 'disc-1', serverName: 'echo'),
        ModelMessage(
          model: 'fake-model',
          textOutput: 'done',
          stopReason: 'stop',
        ),
      ]);
      final agent = StatefulAgent(
        name: 'mcp',
        client: client,
        modelConfig: ModelConfig(model: 'fake-model'),
        state: state,
        mcpManager: manager,
        withGeneralPrinciples: false,
        disableSubAgents: true,
      );

      await agent.run([UserMessage.text('list echo')], useStream: false);

      final result = state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .single
          .results
          .single;
      expect(result.isError, isTrue);
      expect((result.content.single as TextPart).text, startsWith('Error:'));
    },
  );
}

ModelMessage _mcpListToolsCall({
  required String id,
  required String serverName,
}) {
  return ModelMessage(
    model: 'fake-model',
    stopReason: 'tool_calls',
    functionCalls: [
      FunctionCall(
        id: id,
        name: 'mcp_list_tools',
        arguments: jsonEncode({'server_name': serverName}),
      ),
    ],
  );
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
