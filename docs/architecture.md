# Architecture & Lifecycle

## The `StatefulAgent`

`StatefulAgent` manages an `AgentState` and runs an autonomous "think-act-observe" loop. Every call to `run()` or `runStream()` starts the loop with the current state and continues until a stop condition is met.

### Agent Loop Steps

1. **Compress context** (optional): If a `ContextCompressor` is attached and the token threshold is exceeded, old messages are compressed into episodic memory before the call is made.
2. **Compose request**: The system message and tool list are assembled dynamically from system prompts, active skills, planner tools, sub-agent tools, and memory tools.
3. **System callback** (optional): If a `systemCallback` is provided, it runs here and can modify the system message, tools, or request messages before the LLM call.
4. **Call LLM**: The formatted message history is sent to the chosen `LLMClient`.
5. **Handle response**:
   - If the model returns no tool calls, the loop ends and the final `ModelMessage` is returned.
   - If the model requests one or more `FunctionCall`s, the agent executes the corresponding `Tool` functions (in parallel), appends the results to history, and loops back to step 1.
6. **Stop conditions**: The loop exits on: no tool calls, a tool returning `stopFlag = true`, `AgentException` (loop detected, cancelled, stopped by controller), or an unhandled exception.

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

---

## `AgentController` Event Hooks

Attach an `AgentController` to intercept and react to lifecycle events. The controller supports two patterns:

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

**Request/Response (approve or stop):**

Register a handler to approve or block specific steps. If no handler is registered, the agent proceeds with the default (approve).

```dart
controller.registerHandler<BeforeToolCallRequest, BeforeToolCallResponse>(
  (request) async {
    if (request.functionCall.name == 'delete_files') {
      // Block dangerous tool calls
      return BeforeToolCallResponse(approve: false);
    }
    return BeforeToolCallResponse(approve: true);
  },
);
```

Available request/response pairs:

| Request | Response | Triggered |
|---------|----------|-----------|
| `BeforeRunAgentRequest` | `BeforeRunAgentResponse` | Before the agent loop starts |
| `ResumeAgentRequest` | `ResumeAgentResponse` | Before resuming a suspended agent |
| `BeforeCallLLMRequest` | `BeforeCallLLMResponse` | Before each LLM call |
| `BeforeToolCallRequest` | `BeforeToolCallResponse` | Before each tool call |
| `AfterToolCallRequest` | `AfterToolCallResponse` | After each tool call (can stop loop) |

---

## `systemCallback`

A lower-level interception point that runs before every LLM call. It receives the current system message, tools, and request messages, and can return modified versions:

```dart
final agent = StatefulAgent(
  ...
  systemCallback: (agent, systemMessage, tools, messages) async {
    // Inject dynamic context into the system message
    final updatedSystem = SystemMessage(
      '${systemMessage?.content ?? ''}\n\nCurrent time: ${DateTime.now()}',
    );
    return (updatedSystem, tools, messages);
  },
);
```

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
