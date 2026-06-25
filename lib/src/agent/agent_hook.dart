part of 'stateful_agent.dart';

class ModelCallRequest {
  final SystemMessage? systemMessage;
  final List<LLMMessage> requestMessages;
  final List<Tool> tools;
  final ToolChoice? toolChoice;
  final ModelConfig modelConfig;
  final bool stream;

  ModelCallRequest({
    required this.systemMessage,
    required List<LLMMessage> requestMessages,
    required List<Tool> tools,
    required this.toolChoice,
    required this.modelConfig,
    required this.stream,
  }) : requestMessages = List.unmodifiable(requestMessages),
       tools = List.unmodifiable(tools);

  ModelCallRequest copyWith({
    SystemMessage? systemMessage,
    bool clearSystemMessage = false,
    List<LLMMessage>? requestMessages,
    List<Tool>? tools,
    ToolChoice? toolChoice,
    bool clearToolChoice = false,
    ModelConfig? modelConfig,
    bool? stream,
  }) {
    return ModelCallRequest(
      systemMessage: clearSystemMessage
          ? null
          : systemMessage ?? this.systemMessage,
      requestMessages: requestMessages ?? this.requestMessages,
      tools: tools ?? this.tools,
      toolChoice: clearToolChoice ? null : toolChoice ?? this.toolChoice,
      modelConfig: modelConfig ?? this.modelConfig,
      stream: stream ?? this.stream,
    );
  }

  CallLLMParams toCallLLMParams() {
    final messages = List<LLMMessage>.from(requestMessages);
    if (systemMessage != null) {
      messages.insert(0, systemMessage!);
    }
    return CallLLMParams(
      messages: messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      stream: stream,
    );
  }
}

abstract class AgentHookContext {
  final StatefulAgent agent;

  const AgentHookContext(this.agent);

  AgentState get state => agent.state;
}

class BeforeRunHookContext extends AgentHookContext {
  final List<LLMMessage> input;
  final bool stream;
  final CancelToken? cancelToken;

  const BeforeRunHookContext(
    super.agent, {
    required this.input,
    required this.stream,
    this.cancelToken,
  });

  BeforeRunHookContext copyWith({List<LLMMessage>? input}) {
    return BeforeRunHookContext(
      agent,
      input: input ?? this.input,
      stream: stream,
      cancelToken: cancelToken,
    );
  }
}

class ModelCallHookContext extends AgentHookContext {
  final ModelCallRequest request;
  final int turnIndex;
  final CancelToken? cancelToken;

  const ModelCallHookContext(
    super.agent, {
    required this.request,
    required this.turnIndex,
    this.cancelToken,
  });

  ModelCallHookContext copyWith({ModelCallRequest? request}) {
    return ModelCallHookContext(
      agent,
      request: request ?? this.request,
      turnIndex: turnIndex,
      cancelToken: cancelToken,
    );
  }
}

class ModelChunkHookContext extends AgentHookContext {
  final CallLLMParams params;
  final ModelMessage chunk;

  const ModelChunkHookContext(
    super.agent, {
    required this.params,
    required this.chunk,
  });

  ModelChunkHookContext copyWith({ModelMessage? chunk}) {
    return ModelChunkHookContext(
      agent,
      params: params,
      chunk: chunk ?? this.chunk,
    );
  }
}

class ModelResponseHookContext extends AgentHookContext {
  final CallLLMParams params;
  final ModelMessage response;

  const ModelResponseHookContext(
    super.agent, {
    required this.params,
    required this.response,
  });

  ModelResponseHookContext copyWith({ModelMessage? response}) {
    return ModelResponseHookContext(
      agent,
      params: params,
      response: response ?? this.response,
    );
  }
}

class ToolCallHookContext extends AgentHookContext {
  final FunctionCall call;
  final ModelMessage modelMessage;
  final List<Tool> availableTools;

  const ToolCallHookContext(
    super.agent, {
    required this.call,
    required this.modelMessage,
    required this.availableTools,
  });

  ToolCallHookContext copyWith({FunctionCall? call}) {
    return ToolCallHookContext(
      agent,
      call: call ?? this.call,
      modelMessage: modelMessage,
      availableTools: availableTools,
    );
  }
}

class ToolResultHookContext extends AgentHookContext {
  final FunctionExecutionResult result;
  final ModelMessage modelMessage;

  const ToolResultHookContext(
    super.agent, {
    required this.result,
    required this.modelMessage,
  });

  ToolResultHookContext copyWith({FunctionExecutionResult? result}) {
    return ToolResultHookContext(
      agent,
      result: result ?? this.result,
      modelMessage: modelMessage,
    );
  }
}

class TurnCompletionHookContext extends AgentHookContext {
  final ModelMessage finalMessage;
  final int continuationCount;
  final int maxContinuations;

  const TurnCompletionHookContext(
    super.agent, {
    required this.finalMessage,
    required this.continuationCount,
    required this.maxContinuations,
  });
}

class StatePersistenceHookContext extends AgentHookContext {
  final String reason;
  final AgentException? runError;

  const StatePersistenceHookContext(
    super.agent, {
    required this.reason,
    this.runError,
  });
}

class AfterRunHookContext extends AgentHookContext {
  final List<LLMMessage> input;
  final List<ModelMessage> modelMessages;
  final AgentException? error;

  const AfterRunHookContext(
    super.agent, {
    required this.input,
    required this.modelMessages,
    this.error,
  });
}

enum BeforeRunHookAction { proceed, abort }

class BeforeRunHookResult {
  final BeforeRunHookAction action;
  final List<LLMMessage>? input;
  final Exception? error;
  final String? reason;

  const BeforeRunHookResult.proceed([this.input])
    : action = BeforeRunHookAction.proceed,
      error = null,
      reason = null;

  const BeforeRunHookResult.abort({this.error, this.reason})
    : action = BeforeRunHookAction.abort,
      input = null;
}

enum ModelCallHookAction { proceed, respond, abort }

class ModelCallHookResult {
  final ModelCallHookAction action;
  final ModelCallRequest? request;
  final ModelMessage? response;
  final bool changed;
  final Exception? error;
  final String? reason;

  const ModelCallHookResult.proceed({this.request, this.changed = false})
    : action = ModelCallHookAction.proceed,
      response = null,
      error = null,
      reason = null;

  const ModelCallHookResult.respond(this.response, {this.request, this.reason})
    : action = ModelCallHookAction.respond,
      changed = true,
      error = null;

  const ModelCallHookResult.abort({this.error, this.reason})
    : action = ModelCallHookAction.abort,
      request = null,
      response = null,
      changed = false;
}

enum ModelChunkHookAction { proceed, drop, abort }

class ModelChunkHookResult {
  final ModelChunkHookAction action;
  final ModelMessage? chunk;
  final Exception? error;
  final String? reason;

  const ModelChunkHookResult.proceed([this.chunk])
    : action = ModelChunkHookAction.proceed,
      error = null,
      reason = null;

  const ModelChunkHookResult.drop({this.reason})
    : action = ModelChunkHookAction.drop,
      chunk = null,
      error = null;

  const ModelChunkHookResult.abort({this.error, this.reason})
    : action = ModelChunkHookAction.abort,
      chunk = null;
}

enum ModelResponseHookAction { proceed, retry, abort }

class ModelResponseHookResult {
  final ModelResponseHookAction action;
  final ModelMessage? response;
  final String? retryReason;
  final Exception? error;
  final String? reason;

  const ModelResponseHookResult.proceed([this.response])
    : action = ModelResponseHookAction.proceed,
      retryReason = null,
      error = null,
      reason = null;

  const ModelResponseHookResult.retry(this.retryReason)
    : action = ModelResponseHookAction.retry,
      response = null,
      error = null,
      reason = null;

  const ModelResponseHookResult.abort({this.error, this.reason})
    : action = ModelResponseHookAction.abort,
      response = null,
      retryReason = null;
}

enum ToolCallHookAction { proceed, deny, defer, abort }

class ToolCallHookResult {
  final ToolCallHookAction action;
  final FunctionCall? call;
  final ExecutionToolResult? syntheticResult;
  final List<UserContentPart>? syntheticContent;
  final bool syntheticIsError;
  final Map<String, dynamic>? metadata;
  final Exception? error;
  final String? reason;

  const ToolCallHookResult.proceed([this.call])
    : action = ToolCallHookAction.proceed,
      syntheticResult = null,
      syntheticContent = null,
      syntheticIsError = false,
      metadata = null,
      error = null,
      reason = null;

  const ToolCallHookResult.denyWithResult(this.syntheticResult)
    : action = ToolCallHookAction.deny,
      call = null,
      syntheticContent = null,
      syntheticIsError = true,
      metadata = null,
      error = null,
      reason = null;

  const ToolCallHookResult.deny({
    List<UserContentPart>? content,
    bool isError = true,
    this.metadata,
    this.reason,
  }) : action = ToolCallHookAction.deny,
       call = null,
       syntheticResult = null,
       syntheticContent = content,
       syntheticIsError = isError,
       error = null;

  const ToolCallHookResult.defer({
    List<UserContentPart>? content,
    this.metadata,
    this.reason,
  }) : action = ToolCallHookAction.defer,
       call = null,
       syntheticResult = null,
       syntheticContent = content,
       syntheticIsError = false,
       error = null;

  const ToolCallHookResult.abort({this.error, this.reason})
    : action = ToolCallHookAction.abort,
      call = null,
      syntheticResult = null,
      syntheticContent = null,
      syntheticIsError = false,
      metadata = null;
}

enum ToolResultHookAction { proceed, stop, abort }

class ToolResultHookResult {
  final ToolResultHookAction action;
  final FunctionExecutionResult? result;
  final List<LLMMessage> injectedMessages;
  final Exception? error;
  final String? reason;

  const ToolResultHookResult.proceed({
    this.result,
    this.injectedMessages = const [],
  }) : action = ToolResultHookAction.proceed,
       error = null,
       reason = null;

  const ToolResultHookResult.stop({
    this.result,
    this.injectedMessages = const [],
    this.reason,
  }) : action = ToolResultHookAction.stop,
       error = null;

  const ToolResultHookResult.abort({this.error, this.reason})
    : action = ToolResultHookAction.abort,
      result = null,
      injectedMessages = const [];
}

enum TurnCompletionHookAction { accept, continueRun, abort }

class TurnCompletionHookResult {
  final TurnCompletionHookAction action;
  final List<LLMMessage> messages;
  final Exception? error;
  final String? reason;

  const TurnCompletionHookResult.accept()
    : action = TurnCompletionHookAction.accept,
      messages = const [],
      error = null,
      reason = null;

  const TurnCompletionHookResult.continueWith(
    List<LLMMessage> continuationMessages,
  ) : action = TurnCompletionHookAction.continueRun,
      messages = continuationMessages,
      error = null,
      reason = null;

  const TurnCompletionHookResult.abort({this.error, this.reason})
    : action = TurnCompletionHookAction.abort,
      messages = const [];
}

enum StatePersistenceHookAction { proceed, skip, abort }

class StatePersistenceHookResult {
  final StatePersistenceHookAction action;
  final Exception? error;
  final String? reason;

  const StatePersistenceHookResult.proceed()
    : action = StatePersistenceHookAction.proceed,
      error = null,
      reason = null;

  const StatePersistenceHookResult.skip({this.reason})
    : action = StatePersistenceHookAction.skip,
      error = null;

  const StatePersistenceHookResult.abort({this.error, this.reason})
    : action = StatePersistenceHookAction.abort;
}

abstract class AgentHook {
  FutureOr<BeforeRunHookResult> beforeRun(BeforeRunHookContext context) {
    return BeforeRunHookResult.proceed(context.input);
  }

  FutureOr<ModelCallHookResult> beforeModelCall(ModelCallHookContext context) {
    return ModelCallHookResult.proceed(request: context.request);
  }

  FutureOr<ModelChunkHookResult> onModelChunk(ModelChunkHookContext context) {
    return ModelChunkHookResult.proceed(context.chunk);
  }

  FutureOr<ModelResponseHookResult> afterModelCall(
    ModelResponseHookContext context,
  ) {
    return ModelResponseHookResult.proceed(context.response);
  }

  FutureOr<ToolCallHookResult> beforeToolCall(ToolCallHookContext context) {
    return ToolCallHookResult.proceed(context.call);
  }

  FutureOr<ToolResultHookResult> afterToolCall(ToolResultHookContext context) {
    return ToolResultHookResult.proceed(result: context.result);
  }

  FutureOr<TurnCompletionHookResult> onTurnCompletion(
    TurnCompletionHookContext context,
  ) {
    return const TurnCompletionHookResult.accept();
  }

  FutureOr<StatePersistenceHookResult> beforePersistState(
    StatePersistenceHookContext context,
  ) {
    return const StatePersistenceHookResult.proceed();
  }

  FutureOr<void> afterPersistState(StatePersistenceHookContext context) {}

  FutureOr<void> afterRun(AfterRunHookContext context) {}
}

class AgentHookPipeline {
  final List<AgentHook> hooks;

  AgentHookPipeline(List<AgentHook> hooks) : hooks = List.unmodifiable(hooks);

  bool get isEmpty => hooks.isEmpty;

  Future<BeforeRunHookResult> beforeRun(BeforeRunHookContext context) async {
    var input = context.input;
    for (final hook in hooks) {
      final result = await hook.beforeRun(context.copyWith(input: input));
      if (result.action == BeforeRunHookAction.abort) {
        return result;
      }
      final nextInput = result.input ?? input;
      input = nextInput;
    }
    return BeforeRunHookResult.proceed(input);
  }

  Future<ModelCallHookResult> beforeModelCall(
    ModelCallHookContext context,
  ) async {
    var request = context.request;
    var changed = false;
    for (final hook in hooks) {
      final result = await hook.beforeModelCall(
        context.copyWith(request: request),
      );
      switch (result.action) {
        case ModelCallHookAction.abort:
          return result;
        case ModelCallHookAction.respond:
          return ModelCallHookResult.respond(
            result.response!,
            request: result.request ?? request,
            reason: result.reason,
          );
        case ModelCallHookAction.proceed:
          final nextRequest = result.request ?? request;
          if (!identical(nextRequest, request) || result.changed) {
            changed = true;
          }
          request = nextRequest;
      }
    }
    return ModelCallHookResult.proceed(request: request, changed: changed);
  }

  Future<ModelChunkHookResult> onModelChunk(
    ModelChunkHookContext context,
  ) async {
    var chunk = context.chunk;
    for (final hook in hooks) {
      final result = await hook.onModelChunk(context.copyWith(chunk: chunk));
      switch (result.action) {
        case ModelChunkHookAction.abort:
          return result;
        case ModelChunkHookAction.drop:
          return result;
        case ModelChunkHookAction.proceed:
          final nextChunk = result.chunk ?? chunk;
          chunk = nextChunk;
      }
    }
    return ModelChunkHookResult.proceed(chunk);
  }

  Future<ModelResponseHookResult> afterModelCall(
    ModelResponseHookContext context,
  ) async {
    var response = context.response;
    for (final hook in hooks) {
      final result = await hook.afterModelCall(
        context.copyWith(response: response),
      );
      switch (result.action) {
        case ModelResponseHookAction.abort:
        case ModelResponseHookAction.retry:
          return result;
        case ModelResponseHookAction.proceed:
          final nextResponse = result.response ?? response;
          response = nextResponse;
      }
    }
    return ModelResponseHookResult.proceed(response);
  }

  Future<ToolCallHookResult> beforeToolCall(ToolCallHookContext context) async {
    var call = context.call;
    for (final hook in hooks) {
      final result = await hook.beforeToolCall(context.copyWith(call: call));
      switch (result.action) {
        case ToolCallHookAction.abort:
        case ToolCallHookAction.deny:
        case ToolCallHookAction.defer:
          return result;
        case ToolCallHookAction.proceed:
          final nextCall = result.call ?? call;
          call = _preserveToolCallId(context.call.id, nextCall);
      }
    }
    return ToolCallHookResult.proceed(call);
  }

  Future<ToolResultHookResult> afterToolCall(
    ToolResultHookContext context,
  ) async {
    var result = context.result;
    final injectedMessages = <LLMMessage>[];
    for (final hook in hooks) {
      final hookResult = await hook.afterToolCall(
        context.copyWith(result: result),
      );
      switch (hookResult.action) {
        case ToolResultHookAction.abort:
          return hookResult;
        case ToolResultHookAction.stop:
        case ToolResultHookAction.proceed:
          final nextResult = hookResult.result ?? result;
          result = nextResult;
          if (hookResult.injectedMessages.isNotEmpty) {
            injectedMessages.addAll(hookResult.injectedMessages);
          }
          if (hookResult.action == ToolResultHookAction.stop) {
            return ToolResultHookResult.stop(
              result: result,
              injectedMessages: injectedMessages,
              reason: hookResult.reason,
            );
          }
      }
    }
    return ToolResultHookResult.proceed(
      result: result,
      injectedMessages: injectedMessages,
    );
  }

  Future<TurnCompletionHookResult> onTurnCompletion(
    TurnCompletionHookContext context,
  ) async {
    for (final hook in hooks) {
      final result = await hook.onTurnCompletion(context);
      if (result.action == TurnCompletionHookAction.accept) {
        continue;
      }
      return result;
    }
    return const TurnCompletionHookResult.accept();
  }

  Future<StatePersistenceHookResult> beforePersistState(
    StatePersistenceHookContext context,
  ) async {
    for (final hook in hooks) {
      final result = await hook.beforePersistState(context);
      if (result.action == StatePersistenceHookAction.proceed) {
        continue;
      }
      return result;
    }
    return const StatePersistenceHookResult.proceed();
  }

  Future<void> afterPersistState(StatePersistenceHookContext context) async {
    for (final hook in hooks) {
      await hook.afterPersistState(context);
    }
  }

  Future<void> afterRun(AfterRunHookContext context) async {
    for (final hook in hooks) {
      await hook.afterRun(context);
    }
  }
}

FunctionCall _preserveToolCallId(String id, FunctionCall call) {
  if (call.id == id) return call;
  return FunctionCall(id: id, name: call.name, arguments: call.arguments);
}
