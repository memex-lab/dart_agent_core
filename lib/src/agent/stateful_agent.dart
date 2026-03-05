import 'dart:async';
import 'dart:convert';
import 'package:dart_agent_core/src/agent/controller.dart';
import 'package:dart_agent_core/src/agent/events.dart';
import 'package:dart_agent_core/src/agent/exception.dart';
import 'package:dart_agent_core/src/agent/loop_detector.dart';
import 'package:dart_agent_core/src/agent/skill.dart';
import 'package:dart_agent_core/src/agent/sub_agent.dart';
import 'package:dart_agent_core/src/agent/util.dart';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../core/llm_client.dart';
import '../core/message.dart';
import '../core/tool.dart';
import 'context_compressor.dart';
import 'planner.dart';
import 'memory.dart';

class SystemPromptPart {
  final String name;
  final String content;

  SystemPromptPart({required this.name, required this.content});
}

class SystemPromptHistoryItem {
  final String content;
  final int validFromMessageIndex;

  SystemPromptHistoryItem({
    required this.content,
    required this.validFromMessageIndex,
  });

  Map<String, dynamic> toJson() => {
    'content': content,
    'validFromMessageIndex': validFromMessageIndex,
  };

  factory SystemPromptHistoryItem.fromJson(Map<String, dynamic> json) {
    return SystemPromptHistoryItem(
      content: json['content'],
      validFromMessageIndex: json['validFromMessageIndex'],
    );
  }
}

class ToolsHistoryItem {
  final List<Map<String, dynamic>> tools;
  final int validFromMessageIndex;

  ToolsHistoryItem({required this.tools, required this.validFromMessageIndex});

  Map<String, dynamic> toJson() => {
    'tools': tools,
    'validFromMessageIndex': validFromMessageIndex,
  };

  factory ToolsHistoryItem.fromJson(Map<String, dynamic> json) {
    return ToolsHistoryItem(
      tools: (json['tools'] as List).cast<Map<String, dynamic>>(),
      validFromMessageIndex: json['validFromMessageIndex'],
    );
  }
}

class AgentState {
  String sessionId;
  bool isRunning;
  Map<String, String> systemReminders;
  AgentMessageHistory history;
  List<ModelUsage> usages;
  Map<String, dynamic> metadata;
  PlanState? plan;
  List<String>? activeSkills;
  int totalLoopCount;
  int currentLoopCount;
  List<ModelUsage> currentLoopUsages;
  String? lastError;
  List<SystemPromptHistoryItem> systemPromptHistory;
  List<ToolsHistoryItem> toolsHistory;

  AgentState({
    required this.sessionId,
    AgentMessageHistory? history,
    Map<String, String>? systemReminders,
    List<ModelUsage>? usages,
    List<ModelUsage>? currentLoopUsages,
    Map<String, dynamic>? metadata,
    this.plan,
    this.activeSkills,
    this.isRunning = false,
    this.totalLoopCount = 0,
    this.currentLoopCount = 0,
    this.lastError,
    List<SystemPromptHistoryItem>? systemPromptHistory,
    List<ToolsHistoryItem>? toolsHistory,
  }) : history = history ?? AgentMessageHistory(),
       systemReminders = systemReminders ?? {},
       usages = usages ?? [],
       metadata = metadata ?? {},
       currentLoopUsages = currentLoopUsages ?? [],
       systemPromptHistory = systemPromptHistory ?? [],
       toolsHistory = toolsHistory ?? [];

  Map<String, dynamic> toJson() => {
    'history': history.toJson(),
    'usages': usages.map((e) => e.toJson()).toList(),
    'metadata': metadata,
    'sessionId': sessionId,
    'systemReminders': systemReminders,
    'plan': plan?.toJson(),
    'activeSkills': activeSkills,
    'isRunning': isRunning,
    'totalLoopCount': totalLoopCount,
    'currentLoopCount': currentLoopCount,
    'currentLoopUsages': currentLoopUsages.map((e) => e.toJson()).toList(),
    'lastError': lastError,
    'systemPromptHistory': systemPromptHistory.map((e) => e.toJson()).toList(),
    'toolsHistory': toolsHistory.map((e) => e.toJson()).toList(),
  };

  factory AgentState.empty() {
    return AgentState(sessionId: uuid.v4());
  }

  factory AgentState.fromJson(Map<String, dynamic> json) {
    return AgentState(
      sessionId: json['sessionId'],
      history: AgentMessageHistory.fromJson(json['history']),
      usages:
          (json['usages'] as List?)
              ?.map((e) => ModelUsage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      currentLoopUsages:
          (json['currentLoopUsages'] as List?)
              ?.map((e) => ModelUsage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      metadata: json['metadata'] as Map<String, dynamic>? ?? {},
      systemReminders: (json['systemReminders'] as Map? ?? {})
          .cast<String, String>(),
      plan: json['plan'] != null ? PlanState.fromJson(json['plan']) : null,
      activeSkills: (json['activeSkills'] as List? ?? [])
          .cast<String>()
          .toList(),
      isRunning: json['isRunning'] as bool? ?? false,
      totalLoopCount: json['totalLoopCount'] as int? ?? 0,
      currentLoopCount: json['currentLoopCount'] as int? ?? 0,
      lastError: json['lastError'] as String?,
      systemPromptHistory:
          (json['systemPromptHistory'] as List?)
              ?.map(
                (e) =>
                    SystemPromptHistoryItem.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          [],
      toolsHistory:
          (json['toolsHistory'] as List?)
              ?.map((e) => ToolsHistoryItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

class AgentCallToolContext {
  static final ZoneKey = #AgentCallToolContext;

  static AgentCallToolContext? get current {
    return Zone.current[ZoneKey] as AgentCallToolContext?;
  }

  final AgentState state;
  final StatefulAgent agent;
  final String batchCallId;
  final CancelToken? cancelToken;

  AgentCallToolContext({
    required this.state,
    required this.agent,
    required this.batchCallId,
    this.cancelToken,
  });
}

class AgentToolResult {
  final UserContentPart? content;
  final List<UserContentPart>? contents;
  final bool stopFlag;
  final Map<String, dynamic>? metadata;

  AgentToolResult({
    this.content,
    this.contents,
    this.stopFlag = false,
    this.metadata,
  });
}

class ExecutionToolResult {
  final String id;
  final String name;
  final String arguments;
  final List<UserContentPart> content;
  final Map<String, dynamic>? metadata;
  final bool stopFlag;
  final bool isError;

  ExecutionToolResult({
    required this.id,
    required this.name,
    required this.arguments,
    required this.content,
    this.stopFlag = false,
    this.isError = false,
    this.metadata,
  });
}

class CallLLMParams {
  final List<LLMMessage> messages;
  final List<Tool>? tools;
  final ToolChoice? toolChoice;
  final ModelConfig modelConfig;
  final bool stream;

  CallLLMParams({
    required this.messages,
    this.tools,
    this.toolChoice,
    required this.modelConfig,
    required this.stream,
  });
}

/// Callback type for intercepting and modifying system_message, tools, and request_messages
/// before each LLM call. Receives the StatefulAgent instance as the first argument.
typedef SystemCallback =
    Future<(SystemMessage?, List<Tool>, List<LLMMessage>)> Function(
      StatefulAgent agent,
      SystemMessage? systemMessage,
      List<Tool> tools,
      List<LLMMessage> requestMessages,
    );

class StatefulAgent {
  final Logger _logger = Logger('StatefulAgent');
  final String name;
  final String id = uuid.v4();
  final LLMClient client;
  final ModelConfig modelConfig;
  final List<Tool>? tools;
  final List<String> systemPrompts;
  final ToolChoice? toolChoice;
  final AgentState state;
  final ContextCompressor? compressor;
  late final Planner _planner;
  final PlanMode? planMode;
  final List<Skill>? skills;
  final List<SubAgent>? subAgents;
  final bool disableSubAgents;
  final bool withGeneralPrinciples;
  final AgentController? controller;
  final bool isSubAgent;
  late final LoopDetector loopDetector;
  final Function(AgentState state)? autoSaveStateFunc;
  final SystemCallback? systemCallback;

  StatefulAgent({
    required this.name,
    List<String>? systemPrompts,
    required this.client,
    required this.modelConfig,
    required this.state,
    this.tools,
    this.toolChoice,
    this.compressor,
    this.planMode,
    this.skills,
    this.subAgents,
    this.withGeneralPrinciples = true,
    this.autoSaveStateFunc,
    this.controller,
    LoopDetector? loopDetector,
    this.isSubAgent = false,
    this.disableSubAgents = false,
    this.systemCallback,
  }) : systemPrompts = systemPrompts ?? [] {
    _planner = Planner(this, controller);
    this.loopDetector =
        loopDetector ??
        DefaultLoopDetector(
          state: state,
          client: client,
          modelConfig: modelConfig,
        );
  }

  SystemMessage? composeSystemMessage() {
    List<SystemPromptPart> parts = [];

    // 1. User System Prompt
    if (systemPrompts.isNotEmpty) {
      parts.add(
        SystemPromptPart(
          name: 'system_prompt',
          content: systemPrompts.join('\n\n'),
        ),
      );
    }

    //2. Sub Agents
    if (!isSubAgentMode(state)) {
      if (!disableSubAgents) {
        final subAgentInstruction = buildSubAgentSystemPrompt(state, subAgents);
        if (subAgentInstruction != null) {
          parts.add(subAgentInstruction);
        }
      }
    }

    // 3. Skills
    if (skills != null && skills!.isNotEmpty) {
      final skillInstruction = buildSkillSystemPrompt(state, skills);
      if (skillInstruction != null) {
        parts.add(skillInstruction);
      }
    }

    // 4. General instructions
    if (withGeneralPrinciples) {
      final buffer = StringBuffer("# General Principles:\n");
      buffer.writeln("- Concise output (< 4 lines unless asked for detail)");
      buffer.writeln("- No \"Here is.\" or \"| will..\" —just do it");
      buffer.writeln("- Do work with tools, not text explanations");
      buffer.writeln(
        "- Run independent tools in parallel; execute dependent tools sequentially",
      );
      if (planMode != null &&
          (planMode == PlanMode.auto || planMode == PlanMode.must)) {
        buffer.writeln("- Track tasks with Planner");
      }
      parts.add(
        SystemPromptPart(
          name: 'general_principles',
          content: buffer.toString(),
        ),
      );
    }

    if (parts.isEmpty) return null;

    return SystemMessage(parts.map((p) => p.content).join('\n\n'));
  }

  List<Tool> composeTools() {
    List<Tool> toolsCopy = List.from(tools ?? []);

    // 1. Inject planner tools
    if (planMode != null &&
        (planMode == PlanMode.auto || planMode == PlanMode.must)) {
      toolsCopy.addAll(_planner.tools);
    }

    // 2. Inject skill tools
    if (skills != null && skills!.isNotEmpty) {
      // Only inject skill operation tools if not all skills are force activate
      if (!skills!.every((s) => s.forceActivate)) {
        toolsCopy.addAll(skillOperationTools);
      }

      final forceActiveSkillNames = skills!
          .where((s) => s.forceActivate)
          .map((s) => s.name)
          .toList();
      final activeSkillNames = ({
        ...?(state.activeSkills),
        ...forceActiveSkillNames,
      }).toList();
      for (var skillName in activeSkillNames) {
        final skill = skills!.firstWhere((s) => s.name == skillName);
        toolsCopy.addAll(skill.tools ?? []);
      }
    }

    // 3. Inject sub agent tools
    if (!isSubAgentMode(state)) {
      if (!disableSubAgents) {
        toolsCopy.addAll(subAgentTools);
      }
    }

    // 4. Inject memory tools
    if (state.history.episodicMemories.isNotEmpty) {
      toolsCopy.addAll(memoryTools);
    }

    return toolsCopy;
  }

  Future<List<LLMMessage>> resume({bool useStream = true}) async {
    if (!state.isRunning) {
      throw AgentException(
        AgentExceptionCode.resumeFailed,
        'Agent is not running',
      );
    }
    if (controller != null) {
      final response = await controller!.request(
        ResumeAgentRequest(this),
        ResumeAgentResponse(stop: false),
      );
      if (response.stop) {
        throw AgentException(
          AgentExceptionCode.stopByController,
          'Agent stopped by controller',
          error: response.err,
        );
      }
      controller!.publish(AgentResumedEvent(this));
    }
    return run([], useStream: useStream);
  }

  Stream<StreamingEvent> resumeStream({bool useStream = true}) async* {
    if (!state.isRunning) {
      throw AgentException(
        AgentExceptionCode.resumeFailed,
        'Agent is not running',
      );
    }
    if (controller != null) {
      final response = await controller!.request(
        ResumeAgentRequest(this),
        ResumeAgentResponse(stop: false),
      );
      if (response.stop) {
        throw AgentException(
          AgentExceptionCode.stopByController,
          'Agent stopped by controller',
          error: response.err,
        );
      }
      controller!.publish(AgentResumedEvent(this));
    }
    yield* runStream([], useStream: useStream);
  }

  Future<List<LLMMessage>> run(
    List<LLMMessage> messages, {
    CancelToken? cancelToken,
    bool useStream = true,
  }) async {
    final streamResponse = runStream(
      messages,
      cancelToken: cancelToken,
      useStream: useStream,
    );
    final responses = <LLMMessage>[];
    await for (final event in streamResponse) {
      if (event.eventType == StreamingEventType.fullModelMessage ||
          event.eventType == StreamingEventType.functionCallResult) {
        responses.add(event.data);
      }
    }
    return responses;
  }

  Stream<StreamingEvent> runStream(
    List<LLMMessage> messages, {
    CancelToken? cancelToken,
    bool useStream = true,
  }) async* {
    AgentException? error;
    List<ModelMessage> modelMessages = [];
    try {
      if (controller != null) {
        final response = await controller!.request(
          BeforeRunAgentRequest(this, messages),
          BeforeRunAgentResponse(stop: false),
        );
        if (response.stop) {
          throw AgentException(
            AgentExceptionCode.stopByController,
            'Agent stopped by controller',
            error: response.err,
          );
        }
        controller!.publish(AgentStartedEvent(this, messages));
      }

      if (messages.isNotEmpty) {
        state.history.messages.addAll(messages);
      }
      state.currentLoopCount = 0;
      state.currentLoopUsages.clear();
      // To prevent infinite loops in streams or complex state, we might limit turns?
      // For now, simple loop.
      int? lastSystemPromptHash;
      int? lastToolsHash;
      String stopReason;

      state.isRunning = true;
      state.lastError = null;
      while (true) {
        if (compressor != null) {
          await compressor!.compress(state);
        }

        // 3. Build request messages
        var systemMessage = composeSystemMessage();
        var requestMessages = List<LLMMessage>.from(state.history.messages);

        _injectSystemReminder(requestMessages);

        // 4. copy tools
        List<Tool> toolsCopy = composeTools();

        // System callback interception point
        if (systemCallback != null) {
          try {
            final (
              newSystemMessage,
              newTools,
              newRequestMessages,
            ) = await systemCallback!(
              this,
              systemMessage,
              toolsCopy,
              requestMessages,
            );
            systemMessage = newSystemMessage;
            toolsCopy = newTools;
            requestMessages = newRequestMessages;
          } catch (e) {
            _logger.warning(
              '[$name] system_callback execution error: $e. Using original values.',
            );
          }
        }

        // Insert system_message at the front of request_messages
        if (systemMessage != null) {
          requestMessages.insert(0, systemMessage);
        }

        // Check for changes in System Prompt and Tools
        // Use hashCode for lighter weight change detection compared to MD5
        final currentSystemPromptHash = systemMessage?.content.hashCode ?? 0;

        final toolNames = toolsCopy.map((t) => t.name).toList()..sort();
        final currentToolsHash = toolNames.join(',').hashCode;

        // Log specific changes
        // We check for null to avoid logging on the very first iteration if that is preferred,
        // generally "changed" implies comparison with a previous state.
        // However, if we want to track initialization, the very first turn last*Hash is null.
        // The user prompt "if next time... changes", implies we compare with previous.
        // System Prompt History
        if (lastSystemPromptHash == null ||
            currentSystemPromptHash != lastSystemPromptHash) {
          if (lastSystemPromptHash != null) {
            _logger.info(
              '[$name] 🔄 System Prompt changed! Hash: $lastSystemPromptHash -> $currentSystemPromptHash',
            );
          }
          state.systemPromptHistory.add(
            SystemPromptHistoryItem(
              content: systemMessage?.content ?? '',
              validFromMessageIndex: state.history.messages.length,
            ),
          );
        }

        // Tools History
        if (lastToolsHash == null || currentToolsHash != lastToolsHash) {
          if (lastToolsHash != null) {
            _logger.info(
              '[$name] 🔄 Tools attributes changed! Hash: $lastToolsHash -> $currentToolsHash',
            );
          }
          state.toolsHistory.add(
            ToolsHistoryItem(
              tools: toolsCopy.map((t) => t.toJson()).toList(),
              validFromMessageIndex: state.history.messages.length,
            ),
          );
        }

        lastSystemPromptHash = currentSystemPromptHash;
        lastToolsHash = currentToolsHash;

        final params = CallLLMParams(
          messages: requestMessages,
          tools: toolsCopy,
          toolChoice: toolChoice,
          modelConfig: modelConfig,
          stream: useStream,
        );

        if (controller != null) {
          final response = await controller!.request(
            BeforeCallLLMRequest(this, params),
            BeforeCallLLMResponse(approve: true),
          );
          if (!response.approve) {
            throw AgentException(
              AgentExceptionCode.stopByController,
              'Agent stopped by controller',
              error: response.err,
            );
          }
          controller!.publish(BeforeCallLLMEvent(this, params));
        }

        yield StreamingEvent(
          eventType: StreamingEventType.beforeCallModel,
          data: params,
        );

        if (cancelToken?.isCancelled ?? false) {
          throw AgentException(
            AgentExceptionCode.cancelled,
            'Agent cancelled by user',
            error: cancelToken!.cancelError,
          );
        }
        state.currentLoopCount++;
        state.totalLoopCount++;

        final StringBuffer aggregatedText = StringBuffer();
        final StringBuffer aggregatedThought = StringBuffer();
        final List<FunctionCall> aggregatedTools = [];
        final List<ModelImagePart> imageOutputs = [];
        final List<ModelVideoPart> videoOutputs = [];
        final List<ModelAudioPart> audioOutputs = [];
        String? finalStopReason;
        ModelUsage? finalUsage;
        String? thoughtSignature;
        String? finalResponseId;
        Map<String, dynamic>? finalMetadata;

        if (useStream) {
          final stream = await client.stream(
            params.messages,
            tools: params.tools,
            toolChoice: params.toolChoice,
            modelConfig: params.modelConfig,
            cancelToken: cancelToken,
          );

          await for (final streamingMessage in stream) {
            if (streamingMessage.modelMessage != null) {
              final chunk = streamingMessage.modelMessage!;
              _logModelMessage(chunk, true);
              final loopDetectResult = await loopDetector.detect(chunk);
              if (loopDetectResult.isLoop) {
                throw AgentException(
                  AgentExceptionCode.loopDetection,
                  'Loop detected, ${loopDetectResult.message}',
                );
              }
              if (chunk.textOutput != null) {
                aggregatedText.write(chunk.textOutput);
              }
              if (chunk.functionCalls.isNotEmpty) {
                aggregatedTools.addAll(chunk.functionCalls);
              }
              if (chunk.imageOutputs.isNotEmpty) {
                imageOutputs.addAll(chunk.imageOutputs);
              }
              if (chunk.videoOutputs.isNotEmpty) {
                videoOutputs.addAll(chunk.videoOutputs);
              }
              if (chunk.audioOutputs.isNotEmpty) {
                audioOutputs.addAll(chunk.audioOutputs);
              }
              if (chunk.stopReason != null) {
                finalStopReason = chunk.stopReason;
              }
              if (chunk.usage != null) {
                finalUsage = chunk.usage;
              }
              if (chunk.metadata != null) {
                finalMetadata = chunk.metadata;
              }
              if (chunk.thought != null) {
                aggregatedThought.write(chunk.thought!);
              }
              if (chunk.thoughtSignature != null) {
                thoughtSignature = chunk.thoughtSignature;
              }
              if (chunk.responseId != null) {
                finalResponseId = chunk.responseId;
              }

              controller?.publish(LLMChunkEvent(this, params, chunk));

              yield StreamingEvent(
                eventType: StreamingEventType.modelChunkMessage,
                data: chunk,
              );
            } else if (streamingMessage.controlMessage != null) {
              final controlMessage = streamingMessage.controlMessage!;
              if (controlMessage.controlFlag == StreamingControlFlag.retry) {
                final retryReason = controlMessage.data?["retryReason"];
                _logger.warning(
                  '[$name] 🔄 Model requested retry!, reason:$retryReason',
                );
                yield StreamingEvent(
                  eventType: StreamingEventType.modelRetrying,
                  data: controlMessage.data,
                );
                aggregatedText.clear();
                aggregatedTools.clear();
                imageOutputs.clear();
                videoOutputs.clear();
                audioOutputs.clear();
                finalStopReason = null;
                finalUsage = null;
                finalMetadata = null;
                aggregatedThought.clear();
                thoughtSignature = null;
                controller?.publish(LLMRetryingEvent(this, retryReason));
              }
            }
          }
        } else {
          final fullMessage = await client.generate(
            params.messages,
            tools: params.tools,
            toolChoice: params.toolChoice,
            modelConfig: params.modelConfig,
            cancelToken: cancelToken,
          );
          _logModelMessage(fullMessage, true);
          final loopDetectResult = await loopDetector.detect(fullMessage);
          if (loopDetectResult.isLoop) {
            throw AgentException(
              AgentExceptionCode.loopDetection,
              'Loop detected, ${loopDetectResult.message}',
            );
          }
          if (fullMessage.textOutput != null) {
            aggregatedText.write(fullMessage.textOutput);
          }
          if (fullMessage.functionCalls.isNotEmpty) {
            aggregatedTools.addAll(fullMessage.functionCalls);
          }
          if (fullMessage.imageOutputs.isNotEmpty) {
            imageOutputs.addAll(fullMessage.imageOutputs);
          }
          if (fullMessage.videoOutputs.isNotEmpty) {
            videoOutputs.addAll(fullMessage.videoOutputs);
          }
          if (fullMessage.audioOutputs.isNotEmpty) {
            audioOutputs.addAll(fullMessage.audioOutputs);
          }
          if (fullMessage.stopReason != null) {
            finalStopReason = fullMessage.stopReason;
          }
          if (fullMessage.usage != null) {
            finalUsage = fullMessage.usage;
          }
          if (fullMessage.metadata != null) {
            finalMetadata = fullMessage.metadata;
          }
          if (fullMessage.thought != null) {
            aggregatedThought.write(fullMessage.thought);
          }
          if (fullMessage.thoughtSignature != null) {
            thoughtSignature = fullMessage.thoughtSignature;
          }
          if (fullMessage.responseId != null) {
            finalResponseId = fullMessage.responseId;
          }

          controller?.publish(LLMChunkEvent(this, params, fullMessage));

          yield StreamingEvent(
            eventType: StreamingEventType.modelChunkMessage,
            data: fullMessage,
          );
        }

        if (finalStopReason == null) {
          _logger.warning(
            '[$name] ⚠️ Model returned empty stop reason, retry again',
          );
          yield StreamingEvent(
            eventType: StreamingEventType.modelRetrying,
            data: {"retryReason": "Model returned empty stop reason"},
          );
          controller?.publish(
            LLMRetryingEvent(this, "Model returned empty stop reason"),
          );
          continue;
        }

        if (aggregatedTools.isEmpty &&
            aggregatedText.isEmpty &&
            finalResponseId == null) {
          _logger.warning(
            '[$name] ⚠️ Model returned empty response, retry again',
          );
          yield StreamingEvent(
            eventType: StreamingEventType.modelRetrying,
            data: {"retryReason": "Model returned empty response"},
          );
          controller?.publish(
            LLMRetryingEvent(this, "Model returned empty response"),
          );
          continue;
        }

        // Reconstruct full message for history
        final fullMessage = ModelMessage(
          textOutput: aggregatedText.isNotEmpty
              ? aggregatedText.toString()
              : null,
          functionCalls: aggregatedTools,
          imageOutputs: imageOutputs,
          videoOutputs: videoOutputs,
          audioOutputs: audioOutputs,
          stopReason: finalStopReason,
          usage: finalUsage,
          metadata: finalMetadata,
          model: modelConfig.model,
          thought: aggregatedThought.isNotEmpty
              ? aggregatedThought.toString()
              : null,
          thoughtSignature: thoughtSignature,
          responseId: finalResponseId,
        );

        _logModelMessage(fullMessage, false);
        stopReason = fullMessage.stopReason ?? "unknown";

        controller?.publish(
          AfterCallLLMEvent(this, params, fullMessage, stopReason),
        );

        yield StreamingEvent(
          eventType: StreamingEventType.fullModelMessage,
          data: fullMessage,
        );
        modelMessages.add(fullMessage);

        if (fullMessage.usage != null) {
          state.usages.add(fullMessage.usage!);
          state.currentLoopUsages.add(fullMessage.usage!);
        }

        if (aggregatedTools.isEmpty) {
          state.history.messages.add(fullMessage);
          break;
        }

        yield StreamingEvent(
          eventType: StreamingEventType.functionCallRequest,
          data: aggregatedTools,
        );

        _logger.info(
          '[$name] 🔧 Executing tools\n:  ${aggregatedTools.map((e) => '${e.name}: ${e.arguments}').join("\n  ")}',
        );

        if (controller != null) {
          for (final toolCall in aggregatedTools) {
            final response = await controller!.request(
              BeforeToolCallRequest(this, toolCall),
              BeforeToolCallResponse(approve: true),
            );
            if (!response.approve) {
              throw AgentException(
                AgentExceptionCode.stopByController,
                'Agent stopped by controller',
                error: response.err,
              );
            }
            controller!.publish(BeforeToolCallEvent(this, toolCall));
          }
        }

        final toolExecutionResults = await _executeTools(
          aggregatedTools,
          toolsCopy,
          state,
          cancelToken: cancelToken,
        );
        final List<FunctionExecutionResult> functionExecutionResults =
            toolExecutionResults
                .map(
                  (result) => FunctionExecutionResult(
                    id: result.id,
                    name: result.name,
                    isError: result.isError,
                    arguments: result.arguments,
                    content: result.content,
                    metadata: result.metadata,
                  ),
                )
                .toList();
        final toolExecutionMessage = FunctionExecutionResultMessage(
          results: functionExecutionResults,
        );

        if (controller != null) {
          for (final toolResult in functionExecutionResults) {
            final response = await controller!.request(
              AfterToolCallRequest(this, toolResult),
              AfterToolCallResponse(stop: false),
            );
            if (response.stop) {
              throw AgentException(
                AgentExceptionCode.stopByController,
                'Agent stopped by controller',
                error: response.err,
              );
            }
            controller!.publish(AfterToolCallEvent(this, toolResult));
          }
        }

        _logger.info(
          '[$name] 🔧 Executed tools\n: ${functionExecutionResults.map((e) => '${e.name}: Success:${e.isError ? '❌ No' : '✅ Yes'}').join("\n  ")}',
        );

        yield StreamingEvent(
          eventType: StreamingEventType.functionCallResult,
          data: toolExecutionMessage,
        );

        state.history.messages.addAll([fullMessage, toolExecutionMessage]);

        if (autoSaveStateFunc != null) {
          await autoSaveStateFunc!(state);
        }

        // Check if any tool returned an stop flag
        final stopFlag = toolExecutionResults.any((result) => result.stopFlag);
        if (stopFlag) {
          _logger.info('[$name] 🤖 Stop flag hit, breaking loop');
          break;
        }

        if (cancelToken?.isCancelled ?? false) {
          _logger.warning(
            '[$name] 🤖 Agent run cancelled: ${cancelToken!.cancelError}',
          );
          throw AgentException(
            AgentExceptionCode.cancelled,
            'Agent cancelled by user',
            error: cancelToken.cancelError,
          );
        }

        // Loop continues to stream the NEXT response
      }
      state.isRunning = false;

      controller?.publish(
        AgentRunSuccessedEvent(this, messages, modelMessages, stopReason),
      );
    } on AgentException catch (e) {
      error = e;
      _logger.severe('[$name] ❌ Agent run failed: $e');
      rethrow;
    } on DioException catch (e) {
      state.lastError = e.error?.toString() ?? e.message;
      if (isCancelled(e)) {
        _logger.warning(
          '[$name] 🤖 Agent run cancelled: ${e.message}, reason: ${e.error?.toString()}',
        );
        controller?.publish(OnAgentCancelEvent(this, e, e.error?.toString()));
        error = AgentException(
          AgentExceptionCode.cancelled,
          'Agent cancelled by user, reason: ${e.error?.toString()}',
          error: e,
        );
        throw error;
      } else {
        _logger.severe('[$name] ❌ Agent run failed: $e');
        controller?.publish(OnAgentExceptionEvent(this, e));
        error = AgentException(
          AgentExceptionCode.unknown,
          'Agent run failed, msg: ${e.toString()}',
          error: e,
        );
        throw error;
      }
    } on Exception catch (e) {
      _logger.severe('[$name] ❌ Agent run failed: $e');
      state.lastError = e.toString();
      controller?.publish(OnAgentExceptionEvent(this, e));
      error = AgentException(
        AgentExceptionCode.unknown,
        'Agent run failed, msg: ${e.toString()}',
        error: e,
      );
      throw error;
    } on Error catch (e) {
      _logger.severe('[$name] ❌ Agent run failed: $e');
      state.lastError = e.toString();
      controller?.publish(OnAgentErrorEvent(this, e.toString()));
      error = AgentException(
        AgentExceptionCode.unknown,
        'Agent run failed, msg: ${e.toString()}',
        error: e,
      );
      throw error;
    } finally {
      if (autoSaveStateFunc != null) {
        await autoSaveStateFunc!(state);
      }
      controller?.publish(
        AgentStoppedEvent(this, messages, modelMessages, error: error),
      );
    }
  }

  void _logModelMessage(ModelMessage message, bool isChunk) {
    StringBuffer buffer = StringBuffer();
    if (!isChunk) {
      buffer.writeln('======= Full Agent Message ($name) =========');
    }
    buffer.writeln('🤖 Agent:');
    if (message.thought != null && message.thought!.isNotEmpty) {
      buffer.writeln('  🤔 [Thought]: ${message.thought!.trim()}');
    }

    if (message.textOutput != null && message.textOutput!.isNotEmpty) {
      if (isChunk) {
        buffer.writeln('  📖 [Chunk]:  ${message.textOutput!.trim()}');
      } else {
        buffer.writeln('  📖 [Text Output]: ${message.textOutput!.trim()}');
      }
    }

    if (message.functionCalls.isNotEmpty) {
      buffer.writeln('  🔧 [Function Calls]');
      for (var call in message.functionCalls) {
        buffer.writeln('    > ${call.name}: ${call.arguments}');
      }
    }

    if (message.imageOutputs.isNotEmpty) {
      buffer.writeln('  🖼️ Images: ${message.imageOutputs.length}');
    }
    if (message.videoOutputs.isNotEmpty) {
      buffer.writeln('  📹 Video: ${message.videoOutputs.length}');
    }
    if (message.audioOutputs.isNotEmpty) {
      buffer.writeln('  🔊 Audio: ${message.audioOutputs.length}');
    }

    if (message.usage != null) {
      buffer.writeln(
        '  📊 [Usage]: Input: ${message.usage!.promptTokens}(cached: ${message.usage!.cachedToken}) | Output: ${message.usage!.completionTokens}(thought: ${message.usage!.thoughtToken}) | Total: ${message.usage!.totalTokens}',
      );
    }

    if (message.stopReason != null) {
      buffer.writeln('  [Stop Reason]: ${message.stopReason}');
    }

    _logger.info(buffer.toString());
  }

  Future<List<ExecutionToolResult>> _executeTools(
    List<FunctionCall> calls,
    List<Tool>? tools,
    AgentState state, {
    CancelToken? cancelToken,
  }) async {
    final batchCallId = uuid.v4();
    final futures = calls.map((call) async {
      final tool = tools?.firstWhere(
        (t) => t.name == call.name,
        orElse: () => Tool(name: 'unknown', description: '', parameters: {}),
      );
      if (tool == null || tool.executable == null) {
        return ExecutionToolResult(
          id: call.id,
          name: call.name,
          arguments: call.arguments,
          content: [TextPart('Function ${call.name} failed or not found.')],
          isError: true,
        );
      }

      try {
        // Handle positional and named arguments
        final positionalArgs = <dynamic>[];
        final namedArgs = <Symbol, dynamic>{};

        Map<String, dynamic> decodedArgs;
        try {
          if (call.arguments.trim().isEmpty) {
            decodedArgs = {};
          } else {
            decodedArgs = (jsonDecode(call.arguments) as Map)
                .cast<String, dynamic>();
          }
        } catch (e) {
          return ExecutionToolResult(
            id: call.id,
            name: call.name,
            arguments: call.arguments,
            content: [TextPart('Error decoding arguments: $e')],
            isError: true,
          );
        }

        // We need to know which parameters are named and their types.
        final properties = (tool.parameters['properties'] as Map? ?? {})
            .cast<String, dynamic>();

        void addArgument(String key, dynamic value) {
          dynamic castedValue = value;
          final prop = (properties[key] as Map?)?.cast<String, dynamic>();

          if (prop != null) {
            final type = prop['type'];

            if (value is List && type == 'array') {
              final items = (prop['items'] as Map?)?.cast<String, dynamic>();
              if (items != null) {
                final itemType = items['type'];
                if (itemType == 'string') {
                  castedValue = value.cast<String>();
                } else if (itemType == 'integer') {
                  castedValue = value.cast<int>();
                } else if (itemType == 'number') {
                  castedValue = value
                      .map((e) => (e as num).toDouble())
                      .toList();
                } else if (itemType == 'boolean') {
                  castedValue = value.cast<bool>();
                }
              }
            } else if (type == 'integer' && value is num) {
              castedValue = value.toInt();
            } else if (type == 'number' && value is num) {
              castedValue = value.toDouble();
            }
          }

          if (tool.namedParameters.contains(key)) {
            namedArgs[Symbol(key)] = castedValue;
          } else {
            positionalArgs.add(castedValue);
          }
        }

        // Logic: Iterate over keys defined in Schema (ordered)
        for (var key in properties.keys) {
          if (decodedArgs.containsKey(key)) {
            addArgument(key, decodedArgs[key]);
          } else {
            // Missing argument handling
            if (!tool.namedParameters.contains(key)) {
              // Vital: Positional arg missing in JSON. Must pad with null to maintain alignment.
              positionalArgs.add(null);
            }
          }
        }

        final result = runZoned(
          () => Function.apply(tool.executable!, positionalArgs, namedArgs),
          zoneValues: {
            AgentCallToolContext.ZoneKey: AgentCallToolContext(
              state: state,
              agent: this,
              batchCallId: batchCallId,
              cancelToken: cancelToken,
            ),
          },
        );

        dynamic resultValue;
        // Handle Futures if the tool returns a Future
        if (result is Future) {
          resultValue = (await result);
        } else {
          resultValue = result;
        }
        bool stopFlag = false;
        List<UserContentPart> resultContent = [];
        Map<String, dynamic>? metadata;
        if (resultValue is AgentToolResult) {
          if (resultValue.content != null) {
            resultContent.add(resultValue.content!);
          }
          if (resultValue.contents != null) {
            resultContent.addAll(resultValue.contents!);
          }
          stopFlag = resultValue.stopFlag;
          metadata = resultValue.metadata;
        } else {
          resultContent.add(TextPart(resultValue.toString()));
        }
        return ExecutionToolResult(
          id: call.id,
          name: call.name,
          arguments: call.arguments,
          content: resultContent,
          stopFlag: stopFlag,
          isError: false,
          metadata: metadata,
        );
      } catch (e) {
        _logger.severe(
          '[$name] ❌ Error executing ${call.name} with args ${call.arguments}: $e',
        );
        return ExecutionToolResult(
          id: call.id,
          name: call.name,
          arguments: call.arguments,
          content: [TextPart('Error executing ${call.name}: $e')],
          isError: true,
        );
      }
    });

    return Future.wait(futures);
  }

  bool isSuspend(DioException error) {
    if (CancelToken.isCancel(error) && error.message == "Suspend") {
      return true;
    }
    return false;
  }

  bool isCancelled(Object error) {
    if (error is DioException && CancelToken.isCancel(error)) {
      return true;
    }
    return false;
  }

  void _injectSystemReminder(List<LLMMessage> requestMessages) {
    if (state.systemReminders.isEmpty) return;

    final buffer = StringBuffer();
    bool hasReminders = false;

    buffer.writeln("<system-reminders>");
    buffer.writeln("<note>Note: This is for your information only.</note>");

    for (var entry in state.systemReminders.entries) {
      if (entry.value.isNotEmpty) {
        buffer.writeln("<system-reminder>");
        buffer.writeln("<key>${entry.key}</key>");
        buffer.writeln("<content>");
        buffer.writeln(entry.value);
        buffer.writeln("</content>");
        buffer.writeln("</system-reminder>");
        hasReminders = true;
      }
    }
    buffer.writeln("</system-reminders>");

    if (hasReminders && requestMessages.isNotEmpty) {
      // Find the last UserMessage index
      int insertIndex = -1;
      for (var i = requestMessages.length - 1; i >= 0; i--) {
        if (requestMessages[i] is UserMessage) {
          insertIndex = i;
          break;
        }
      }

      if (insertIndex != -1) {
        requestMessages.insert(
          insertIndex,
          UserMessage.text(buffer.toString()),
        );
      } else {
        // Fallback: if no user message found, insert at the beginning
        requestMessages.insert(0, UserMessage.text(buffer.toString()));
      }
    }
  }
}
