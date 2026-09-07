import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:test/test.dart';

ModelMessage _msgWithCalls(List<FunctionCall> calls) {
  return ModelMessage(model: 'test-model', functionCalls: calls);
}

void main() {
  group('DefaultLoopDetector', () {
    test('无工具调用时不触发环路', () async {
      final state = AgentState.empty();
      final detector = DefaultLoopDetector(state: state, toolLoopThreshold: 3);

      // Plain assistant text message with no function calls.
      final result = await detector.detect(
        ModelMessage(model: 'test-model', textOutput: 'hello'),
      );

      expect(result.isLoop, isFalse);
      expect(result.message, isNull);
    });

    test('不同工具调用不触发环路', () async {
      final state = AgentState.empty();
      final detector = DefaultLoopDetector(state: state, toolLoopThreshold: 3);

      final calls = [
        FunctionCall(id: 'c1', name: 'read', arguments: '{"path":"a.md"}'),
        FunctionCall(id: 'c2', name: 'read', arguments: '{"path":"b.md"}'),
        FunctionCall(id: 'c3', name: 'write', arguments: '{"path":"c.md"}'),
        FunctionCall(id: 'c4', name: 'read', arguments: '{"path":"a.md"}'),
        FunctionCall(id: 'c5', name: 'list', arguments: '{}'),
      ];

      for (final call in calls) {
        final result = await detector.detect(_msgWithCalls([call]));
        expect(result.isLoop, isFalse, reason: '调用 ${call.id} 不应触发环路');
      }
    });

    test('工具签名相同 N 次后触发环路检测', () async {
      final state = AgentState.empty();
      final detector = DefaultLoopDetector(state: state, toolLoopThreshold: 5);

      LoopDetectorResult? finalResult;
      for (var i = 0; i < 5; i++) {
        finalResult = await detector.detect(
          _msgWithCalls([
            FunctionCall(
              id: 'call_$i',
              name: 'read',
              arguments: '{"path":"loop.md"}',
            ),
          ]),
        );
        if (i < 4) {
          expect(finalResult.isLoop, isFalse, reason: '第 ${i + 1} 次还不应触发');
        }
      }

      expect(finalResult!.isLoop, isTrue);
      expect(finalResult.message, contains('Tool call loop detected'));
      expect(finalResult.message, contains('5'));
    });

    test('达到阈值前不应触发环路', () async {
      final state = AgentState.empty();
      final detector = DefaultLoopDetector(state: state, toolLoopThreshold: 5);

      for (var i = 0; i < 4; i++) {
        final result = await detector.detect(
          _msgWithCalls([
            FunctionCall(
              id: 'call_$i',
              name: 'search',
              arguments: '{"q":"dart"}',
            ),
          ]),
        );
        expect(result.isLoop, isFalse);
      }
    });

    test('相同 id 的流式增量更新签名而不算作新调用', () async {
      final state = AgentState.empty();
      final detector = DefaultLoopDetector(state: state, toolLoopThreshold: 3);

      // Stream-like updates: 同一个 id，参数分片增长。
      await detector.detect(
        _msgWithCalls([
          FunctionCall(id: 'streaming', name: 'read', arguments: '{"pa'),
        ]),
      );
      await detector.detect(
        _msgWithCalls([
          FunctionCall(
            id: 'streaming',
            name: 'read',
            arguments: '{"path":"x"}',
          ),
        ]),
      );

      // 再补一个不同 id 的调用，仍只有 2 条独立调用，未触发阈值。
      final result = await detector.detect(
        _msgWithCalls([
          FunctionCall(id: 'other', name: 'read', arguments: '{"path":"y"}'),
        ]),
      );
      expect(result.isLoop, isFalse);
    });

    test('流式中间 chunk 不触发 LLM 诊断', () async {
      final state = AgentState.empty()..totalLoopCount = 100;
      final client = _CountingLLMClient();
      final detector = DefaultLoopDetector(
        state: state,
        client: client,
        modelConfig: ModelConfig(model: 'test-model'),
        llmCheckAfterTurns: 1,
        llmCheckInterval: 1,
      );

      final result = await detector.detect(
        ModelMessage(model: 'test-model', textOutput: 'partial'),
      );

      expect(result.isLoop, isFalse);
      expect(client.generateCount, 0);
    });

    test('工具调用响应不触发 LLM 诊断', () async {
      final state = AgentState.empty()..totalLoopCount = 100;
      final client = _CountingLLMClient();
      final detector = DefaultLoopDetector(
        state: state,
        client: client,
        modelConfig: ModelConfig(model: 'test-model'),
        llmCheckAfterTurns: 1,
        llmCheckInterval: 1,
      );

      final result = await detector.detect(
        ModelMessage(
          model: 'test-model',
          stopReason: 'tool_calls',
          functionCalls: [
            FunctionCall(id: 'call_1', name: 'read', arguments: '{}'),
          ],
        ),
      );

      expect(result.isLoop, isFalse);
      expect(client.generateCount, 0);
    });

    test('LLM 诊断在 confidence > 0.8 时判定为环路', () async {
      final state = AgentState.empty()..totalLoopCount = 5;
      final client = _CountingLLMClient(
        textOutput: '{"is_loop":true,"confidence":0.91,"reason":"stuck"}',
      );
      final detector = DefaultLoopDetector(
        state: state,
        client: client,
        modelConfig: ModelConfig(model: 'test-model'),
        llmCheckAfterTurns: 1,
        llmCheckInterval: 1,
      );

      final result = await detector.detect(
        ModelMessage(
          model: 'test-model',
          textOutput: 'still going',
          stopReason: 'stop',
        ),
      );

      expect(result.isLoop, isTrue);
      expect(result.message, contains('stuck'));
      expect(client.generateCount, 1);
    });

    test('LLM 诊断在 confidence <= 0.8 时忽略', () async {
      final state = AgentState.empty()..totalLoopCount = 5;
      final client = _CountingLLMClient(
        textOutput: '{"is_loop":true,"confidence":0.8,"reason":"maybe"}',
      );
      final detector = DefaultLoopDetector(
        state: state,
        client: client,
        modelConfig: ModelConfig(model: 'test-model'),
        llmCheckAfterTurns: 1,
        llmCheckInterval: 1,
      );

      final result = await detector.detect(
        ModelMessage(
          model: 'test-model',
          textOutput: 'still going',
          stopReason: 'stop',
        ),
      );

      expect(result.isLoop, isFalse);
      expect(client.generateCount, 1);
    });

    test('LLM 诊断 JSON 无法解析时不抛出', () async {
      final state = AgentState.empty()..totalLoopCount = 5;
      final client = _CountingLLMClient(textOutput: 'not json');
      final detector = DefaultLoopDetector(
        state: state,
        client: client,
        modelConfig: ModelConfig(model: 'test-model'),
        llmCheckAfterTurns: 1,
        llmCheckInterval: 1,
      );

      final result = await detector.detect(
        ModelMessage(
          model: 'test-model',
          textOutput: 'still going',
          stopReason: 'stop',
        ),
      );

      expect(result.isLoop, isFalse);
      expect(client.generateCount, 1);
    });
  });
}

class _CountingLLMClient extends LLMClient {
  int generateCount = 0;
  final String textOutput;

  _CountingLLMClient({
    this.textOutput = '{"is_loop":false,"reason":"ok","confidence":0}',
  });

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    generateCount += 1;
    return ModelMessage(
      model: modelConfig.model,
      textOutput: textOutput,
      stopReason: 'stop',
    );
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    throw UnimplementedError();
  }
}
