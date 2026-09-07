# 架构与生命周期

[English](architecture.md) | [简体中文](architecture.zh-CN.md)

## `StatefulAgent`

`StatefulAgent` 持有一份 `AgentState`，并运行自主的「思考—行动—观察」循环。每次调用 `run()` 或 `runStream()` 都会基于当前状态启动循环，直到满足停止条件。

### Agent 循环步骤

1. **压缩上下文**（可选）：若挂载了 `ContextCompressor` 且 Token 超过阈值，会在发起模型调用前把旧消息压缩为情节记忆（episodic memory）。
2. **组装请求**：系统提示词与工具列表会根据系统提示、激活技能、规划器工具、子 Agent 工具、记忆工具以及已连接的 MCP Server 动态组装。
3. **运行 `beforeModelCall` Hook**（可选）：Hook 可以改写系统提示词、请求消息、工具列表、tool choice、模型配置，或直接返回合成的模型响应。若希望数据在后续回合或 resume 后仍然有效，应写入 `context.state`。
4. **调用 LLM**：把格式化后的消息历史发给选定的 `LLMClient`；若 Hook 已提供合成响应则跳过。
5. **运行模型响应 Hook**（可选）：流式分片经过 `onModelChunk`；组装后的完整响应经过 `afterModelCall`，可改写、重试或中止。
6. **处理响应**：
   - 若模型未返回工具调用，循环结束并返回最终 `ModelMessage`。
   - 若模型请求一个或多个 `FunctionCall`，`beforeToolCall` Hook 可以允许、改写、拒绝、延后或中止每次调用。执行结果与合成结果会追加到历史中；`afterToolCall` Hook 可以改写结果或注入后续上下文，然后循环回到第 1 步。
7. **停止条件**：循环在以下情况退出：没有工具调用、工具返回 `stopFlag = true`、Hook 返回 stop/abort、`AgentException`（循环检测、取消、被 Hook 停止），或未处理的异常。

### 流式生命周期

Flutter UI 推荐使用 `agent.runStream()`，它会产出 `Stream<StreamingEvent>`：

```dart
await for (final event in agent.runStream([UserMessage.text('Do XYZ')])) {
  switch (event.eventType) {
    case StreamingEventType.beforeCallModel:
      // 即将调用 LLM；event.data 为 CallLLMParams
      break;
    case StreamingEventType.modelChunkMessage:
      // LLM 流式分片；event.data 为 ModelMessage
      final chunk = event.data as ModelMessage;
      stdout.write(chunk.textOutput);
      break;
    case StreamingEventType.modelRetrying:
      // Provider 遇到瞬时错误，或 Agent 收到空响应
      break;
    case StreamingEventType.fullModelMessage:
      // 本回合组装完成的 ModelMessage
      break;
    case StreamingEventType.functionCallRequest:
      // 模型请求工具调用；event.data 为 List<FunctionCall>
      break;
    case StreamingEventType.functionCallResult:
      // 工具执行完成；event.data 为 FunctionExecutionResultMessage
      break;
  }
}
```

### `run()` 与 `runStream()`

`run()` 是便捷封装：收集所有 `fullModelMessage` 与 `functionCallResult` 事件，并以 `List<LLMMessage>` 返回。内部仍调用 `runStream()`。

当挂载了 `McpManager` 时，每次 run 还会暴露 MCP Server 摘要与桥接工具。MCP 会话会在 run 清理阶段断开；后续 run 前需要重新连接。详见 [Model Context Protocol](mcp.zh-CN.md)。

---

## `AgentController` 事件

挂载 `AgentController` 可观测生命周期事件。Controller 事件用于 UI 更新、追踪、指标与诊断，**不会**控制 Agent 循环。

**发布/订阅（即发即忘）：**

```dart
final controller = AgentController();

controller.on<BeforeToolCallEvent>((event) {
  print('About to call: ${event.functionCall.name}');
});

controller.on<AfterToolCallEvent>((event) {
  print('Tool result: ${event.result.name}, error: ${event.result.isError}');
});

controller.on<PlanChangedEvent>((event) {
  // event.plan 为更新后的 PlanState
  for (final step in event.plan.steps) {
    print('${step.status.name}: ${step.description}');
  }
});

final agent = StatefulAgent(..., controller: controller);
```

---

## `AgentHook`

如需控制 Agent loop，使用 `AgentHook`。Hook 的结果是 typed 的，因此可在不同阶段显式 proceed、respond、retry、deny、defer、stop、continue 或 abort。

```dart
class RuntimeContextHook extends AgentHook {
  @override
  ModelCallHookResult beforeModelCall(ModelCallHookContext context) {
    final transientMessage = UserMessage.text(
      'Current time: ${DateTime.now()}',
    );

    return ModelCallHookResult.proceed(
      request: context.request.copyWith(
        requestMessages: [
          ...context.request.requestMessages,
          transientMessage,
        ],
      ),
    );
  }
}

class ToolPolicyHook extends AgentHook {
  @override
  ToolCallHookResult beforeToolCall(ToolCallHookContext context) {
    if (context.call.name != 'delete_file') {
      return ToolCallHookResult.proceed(context.call);
    }
    return ToolCallHookResult.deny(
      content: [TextPart('delete_file is blocked by local policy.')],
    );
  }
}

final agent = StatefulAgent(
  ...,
  hooks: [RuntimeContextHook(), ToolPolicyHook()],
);
```

只想影响本次模型调用时，改写 `ModelCallRequest.requestMessages`。需要把 Hook 创建的上下文保留到后续 loop 或 resume 时，写入 `context.state.history.messages`。

可用 hook phase：

| Phase | 典型控制 |
|-------|------------------|
| `beforeRun` | 改写初始输入或中止 |
| `beforeModelCall` | 改写模型请求、返回合成响应，或中止 |
| `onModelChunk` | 改写/丢弃流式分片，或中止 |
| `afterModelCall` | 改写最终响应、重试，或中止 |
| `beforeToolCall` | 改写调用、以合成结果拒绝/延后，或中止 |
| `afterToolCall` | 改写结果、注入上下文、停止，或中止 |
| `onTurnCompletion` | 接受最终回答、继续追加消息，或中止 |
| `beforePersistState` / `afterPersistState` | 包裹 `autoSaveStateFunc`、跳过保存，或中止 |
| `afterRun` | 观察最终输入、模型消息与错误 |

---

## 取消与挂起

向 `run()` 或 `runStream()` 传入 `CancelToken`（来自 `dio` 包）即可在运行中取消：

```dart
final cancelToken = CancelToken();

// 在其他位置取消
cancelToken.cancel('user cancelled');

// 带取消能力运行
await agent.run(messages, cancelToken: cancelToken);
```

取消会抛出 `AgentException(AgentExceptionCode.cancelled, ...)`。若要挂起并稍后恢复（而不是彻底取消），用消息 `"Suspend"` 取消 —— 这会走可通过 `isSuspend()` 识别的挂起路径。

---

## 循环检测

除非自行提供实现，`StatefulAgent` 会自动创建 `DefaultLoopDetector`。它使用两种机制：

1. **工具签名追踪**：同一工具以相同参数连续调用 `N` 次（默认 `toolLoopThreshold = 5`）即判定为循环。
2. **周期性 LLM 诊断**：在 `llmCheckAfterTurns` 回合之后（默认 30），每隔 `llmCheckInterval` 回合（默认 10），Agent 会把近期历史发给 LLM，询问是否发生循环。若 `confidence > 0.8` 则判定为循环。

检测到循环会抛出 `AgentException(AgentExceptionCode.loopDetection, ...)`。

可以自定义阈值，或提供完全不同的实现：

```dart
final agent = StatefulAgent(
  ...
  loopDetector: DefaultLoopDetector(
    state: state,
    client: client,
    modelConfig: modelConfig,
    toolLoopThreshold: 3,
    llmCheckAfterTurns: 20,
    llmCheckInterval: 5,
  ),
);
```

---

## 恢复暂停的 Agent

若 `state.isRunning == true`（例如 Agent 在运行中被挂起），调用 `resume()` 即可从中断处继续：

```dart
final responses = await agent.resume();
// 或
await for (final event in agent.resumeStream()) { ... }
```
