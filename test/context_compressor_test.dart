import 'dart:async';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  test('does not compress when promptTokens are below the threshold', () async {
    final client = _QueuedLLMClient([]);
    final compressor = LLMBasedContextCompressor(
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      totalTokenThreshold: 1000,
      keepRecentMessageSize: 2,
    );
    final state = _historyState(messageCount: 6)
      ..usages.add(ModelUsage(promptTokens: 10));

    await compressor.compress(state);

    expect(client.generateCalls, 0);
    expect(state.history.messages, hasLength(6));
    expect(state.history.episodicMemories, isEmpty);
  });

  test('writes episodic memory and keeps the most recent messages', () async {
    const snapshot = '''
<state_snapshot>
    <overall_goal>Finish the task.</overall_goal>
</state_snapshot>
''';
    final client = _QueuedLLMClient([
      ModelMessage(
        model: 'fake-model',
        textOutput: snapshot,
        stopReason: 'stop',
      ),
    ]);
    final compressor = LLMBasedContextCompressor(
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      totalTokenThreshold: 50,
      keepRecentMessageSize: 2,
    );
    final state = _historyState(messageCount: 6)
      ..usages.add(ModelUsage(promptTokens: 80));

    await compressor.compress(state);

    expect(state.history.episodicMemories, hasLength(1));
    final episode = state.history.episodicMemories.single;
    expect(episode.summary, contains('<state_snapshot>'));
    expect(episode.id, startsWith('episode_'));
    expect(state.history.messages, hasLength(4));
    expect(
      (state.history.messages.first as UserMessage).contents.single,
      isA<TextPart>(),
    );
    expect(
      ((state.history.messages.first as UserMessage).contents.single
              as TextPart)
          .text,
      contains(episode.id),
    );
    expect(
      (state.history.messages.first as UserMessage).metadata,
      containsPair('context_compression_reminder', true),
    );
  });

  test('malformed empty summary leaves history unchanged', () async {
    final client = _QueuedLLMClient([
      ModelMessage(model: 'fake-model', textOutput: '', stopReason: 'stop'),
    ]);
    final compressor = LLMBasedContextCompressor(
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      totalTokenThreshold: 10,
      keepRecentMessageSize: 2,
    );
    final state = _historyState(messageCount: 6)
      ..usages.add(ModelUsage(promptTokens: 80));

    await compressor.compress(state);

    expect(state.history.episodicMemories, isEmpty);
    expect(state.history.messages, hasLength(6));
  });

  test('retrieve_memory returns a hit, miss, and offset error', () async {
    final state = AgentState.empty();
    state.history.episodicMemories.add(
      EpisodicMemory(
        id: 'episode_1',
        summary: '<state_snapshot/>',
        messages: [
          UserMessage.text('one'),
          UserMessage.text('two'),
          UserMessage.text('three'),
        ],
      ),
    );
    final agent = StatefulAgent(
      name: 'memory',
      client: _QueuedLLMClient([]),
      modelConfig: ModelConfig(model: 'fake-model'),
      state: state,
      withGeneralPrinciples: false,
      disableSubAgents: true,
    );
    final tool = memoryTools.single;

    Future<AgentToolResult> invoke({
      required String snapshotId,
      int? limit,
      int? offset,
    }) {
      final ctx = AgentCallToolContext(
        state: state,
        agent: agent,
        batchCallId: 'batch-1',
      );
      return runZoned(() async {
        if (limit == null && offset == null) {
          return await (tool.executable as Function)(snapshotId);
        }
        return await Function.apply(
          tool.executable as Function,
          [snapshotId],
          {#limit: limit, #offset: offset},
        );
      }, zoneValues: {AgentCallToolContext.zoneKey: ctx});
    }

    final hit = await invoke(snapshotId: 'episode_1', limit: 1, offset: 1);
    expect((hit.content as TextPart).text, contains('two'));
    expect((hit.content as TextPart).text, isNot(contains('one')));

    final miss = await invoke(snapshotId: 'missing');
    expect((miss.content as TextPart).text, contains('not found'));

    final oob = await invoke(snapshotId: 'episode_1', offset: 9);
    expect((oob.content as TextPart).text, contains('Offset out of bounds'));
  });

  test('retrieve_memory is composed only after episodic memories exist', () {
    final empty = StatefulAgent(
      name: 'memory',
      client: _QueuedLLMClient([]),
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      withGeneralPrinciples: false,
      disableSubAgents: true,
    );
    expect(
      empty.composeTools().map((tool) => tool.name),
      isNot(contains('retrieve_memory')),
    );

    final withMemory = StatefulAgent(
      name: 'memory',
      client: _QueuedLLMClient([]),
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty()
        ..history.episodicMemories.add(
          EpisodicMemory(id: 'episode_1', summary: 's', messages: []),
        ),
      withGeneralPrinciples: false,
      disableSubAgents: true,
    );
    expect(
      withMemory.composeTools().map((tool) => tool.name),
      contains('retrieve_memory'),
    );
  });
}

AgentState _historyState({required int messageCount}) {
  final state = AgentState.empty();
  for (var i = 0; i < messageCount; i++) {
    state.history.messages.add(UserMessage.text('msg-$i'));
  }
  return state;
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
    if (generateCalls >= replies.length) {
      throw StateError('Unexpected extra generate() call');
    }
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
  }) {
    throw UnimplementedError();
  }
}
