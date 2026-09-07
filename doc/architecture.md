# Architecture & Lifecycle

[English](architecture.md) | [简体中文](architecture.zh-CN.md)

## The `StatefulAgent`

`StatefulAgent` manages an `AgentState` and runs an autonomous "think-act-observe" loop. Every call to `run()` or `runStream()` starts the loop with the current state and continues until a stop condition is met.

### Agent Loop Steps

1. **Compress context** (optional): If a `ContextCompressor` is attached and the token threshold is exceeded, old messages are compressed into episodic memory before the call is made.
2. **Compose request**: The system message and tool list are assembled dynamically from system prompts, active skills, planner tools, sub-agent tools, memory tools, and connected MCP servers.
3. **Run `beforeModelCall` hooks** (optional): Hooks can rewrite the system message, request messages, tools, tool choice, model config, or return a synthetic model response. If a hook wants data to survive later turns or resume, it can write to `context.state`.
4. **Call LLM**: The formatted message history is sent to the chosen `LLMClient`, unless a hook supplied a synthetic response.
5. **Run model response hooks** (optional): Streaming chunks pass through `onModelChunk`; the assembled response passes through `afterModelCall`, which can rewrite, retry, or abort.
6. **Handle response**:
   - If the model returns no tool calls, the loop ends and the final `ModelMessage` is returned.
   - If the model requests one or more `FunctionCall`s, `beforeToolCall` hooks can allow, rewrite, deny, defer, or abort each call. Executed and synthetic results are appended to history, `afterToolCall` hooks can rewrite results or inject follow-up context, and the loop returns to step 1.
7. **Stop conditions**: The loop exits on: no tool calls, a tool returning `stopFlag = true`, a hook returning stop/abort, `AgentException` (loop detected, cancelled, stopped by hook), or an unhandled exception.

### Streaming Lifecycle

The preferred method for Flutter UIs is `agent.runStream()`, which yields a `Stream<StreamingEvent>`:

```dart
await for (final event in agent.runStream([UserMessage.text('Do XYZ')])) {
  switch (event.eventType) {
    case StreamingEventType.beforeCallModel:
      // About to call LLM; event.data is CallLLMParams
      break;
    case StreamingEventType.modelChunkMessage:
      // Token chunk from the LLM stream; event.data is ModelMessage
      final chunk = event.data as ModelMessage;
      stdout.write(chunk.textOutput);
      break;
    case StreamingEventType.modelRetrying:
      // Provider hit a transient error, or agent received an empty response
      break;
    case StreamingEventType.fullModelMessage:
      // Complete assembled ModelMessage for this turn
      break;
    case StreamingEventType.functionCallRequest:
      // Model requested tool calls; event.data is List<FunctionCall>
      break;
    case StreamingEventType.functionCallResult:
      // Tool execution finished; event.data is FunctionExecutionResultMessage
      break;
  }
}
```

### `run()` vs `runStream()`

`run()` is a convenience wrapper that collects all `fullModelMessage` and `functionCallResult` events and returns them as a `List<LLMMessage>`. Internally it calls `runStream()`.

When an `McpManager` is attached, each run also exposes the MCP server summary and bridge tools. MCP sessions are disconnected in run cleanup; reconnect the manager before starting a later run. See [Model Context Protocol](mcp.md).

---

## `AgentController` Events

Attach an `AgentController` to observe lifecycle events. Controller events are for UI updates, tracing, metrics, and diagnostics; they do not control the agent loop.

**Pub/Sub (fire and forget):**

```dart
final controller = AgentController();

controller.on<BeforeToolCallEvent>((event) {
  print('About to call: ${event.functionCall.name}');
});

controller.on<AfterToolCallEvent>((event) {
  print('Tool result: ${event.result.name}, error: ${event.result.isError}');
});

controller.on<PlanChangedEvent>((event) {
  // event.plan is the updated PlanState
  for (final step in event.plan.steps) {
    print('${step.status.name}: ${step.description}');
  }
});

final agent = StatefulAgent(..., controller: controller);
```

---

## `AgentHook`

Use `AgentHook` for controlled changes to the loop. Hook outcomes are typed, so a hook can explicitly proceed, respond, retry, deny, defer, stop, continue, or abort depending on the phase.

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

To affect only the current model call, rewrite `ModelCallRequest.requestMessages`. To persist hook-created context for later loops or resume, write to `context.state.history.messages`.

Available hook phases:

| Phase | Typical controls |
|-------|------------------|
| `beforeRun` | Rewrite initial input or abort |
| `beforeModelCall` | Rewrite model request, return synthetic response, or abort |
| `onModelChunk` | Rewrite/drop streaming chunks or abort |
| `afterModelCall` | Rewrite final response, retry, or abort |
| `beforeToolCall` | Rewrite call, deny/defer with synthetic result, or abort |
| `afterToolCall` | Rewrite result, inject context, stop, or abort |
| `onTurnCompletion` | Accept final answer, continue with messages, or abort |
| `beforePersistState` / `afterPersistState` | Wrap `autoSaveStateFunc`, skip save, or abort |
| `afterRun` | Observe final input, model messages, and error |

---

## Cancellation and Suspension

Pass a `CancelToken` (from the `dio` package) to `run()` or `runStream()` to cancel mid-flight:

```dart
final cancelToken = CancelToken();

// Cancel from elsewhere
cancelToken.cancel('user cancelled');

// Run with cancellation support
await agent.run(messages, cancelToken: cancelToken);
```

Cancellation throws `AgentException(AgentExceptionCode.cancelled, ...)`. To suspend and resume (rather than fully cancel), cancel with the message `"Suspend"` — this triggers a special suspension path detectable via `isSuspend()`.

---

## Loop Detection

`StatefulAgent` automatically creates a `DefaultLoopDetector` unless you supply your own. It uses two mechanisms:

1. **Tool signature tracking**: If the same tool is called with identical arguments `N` consecutive times (default `toolLoopThreshold = 5`), a loop is declared.
2. **Periodic LLM diagnosis**: After `llmCheckAfterTurns` turns (default 30), every `llmCheckInterval` turns (default 10), the agent sends recent history to the LLM and asks it to diagnose whether a loop is occurring. A loop is declared if `confidence > 0.8`.

A detected loop throws `AgentException(AgentExceptionCode.loopDetection, ...)`.

You can customize thresholds or provide a completely different implementation:

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

## Resuming a Paused Agent

If `state.isRunning == true` (e.g., the agent was suspended mid-run), call `resume()` to continue from where it left off:

```dart
final responses = await agent.resume();
// or
await for (final event in agent.resumeStream()) { ... }
```
