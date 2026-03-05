// --- Events Definitions ---

import 'package:dart_agent_core/dart_agent_core.dart';

class BeforeRunAgentRequest extends Event {
  final StatefulAgent agent;
  final List<LLMMessage> input;
  BeforeRunAgentRequest(this.agent, this.input);
}

class BeforeRunAgentResponse {
  final Exception? err;
  final bool stop;
  BeforeRunAgentResponse({this.err, this.stop = false});
}

class AgentStartedEvent extends Event {
  final StatefulAgent agent;
  final List<LLMMessage> input;
  AgentStartedEvent(this.agent, this.input);
}

class ResumeAgentRequest extends Event {
  final StatefulAgent agent;
  ResumeAgentRequest(this.agent);
}

class ResumeAgentResponse {
  final Exception? err;
  final bool stop;
  ResumeAgentResponse({this.err, this.stop = false});
}

class AgentResumedEvent extends Event {
  final StatefulAgent agent;
  AgentResumedEvent(this.agent);
}

class AgentRunSuccessedEvent extends Event {
  final StatefulAgent agent;
  final List<LLMMessage> input;
  final List<ModelMessage> modelMessages;
  final String stopReason;
  AgentRunSuccessedEvent(
    this.agent,
    this.input,
    this.modelMessages,
    this.stopReason,
  );
}

class OnAgentExceptionEvent extends Event {
  final StatefulAgent agent;
  final Exception error;
  OnAgentExceptionEvent(this.agent, this.error);
}

class OnAgentErrorEvent extends Event {
  final StatefulAgent agent;
  final String error;
  OnAgentErrorEvent(this.agent, this.error);
}

class OnAgentCancelEvent extends Event {
  final StatefulAgent agent;
  final Exception exception;
  final String? reason;
  OnAgentCancelEvent(this.agent, this.exception, this.reason);
}

class BeforeCallLLMRequest extends Event {
  final StatefulAgent agent;
  final CallLLMParams params;
  BeforeCallLLMRequest(this.agent, this.params);
}

class BeforeCallLLMResponse {
  final Exception? err;
  final bool approve;
  BeforeCallLLMResponse({this.err, this.approve = true});
}

class BeforeCallLLMEvent extends Event {
  final StatefulAgent agent;
  final CallLLMParams params;
  BeforeCallLLMEvent(this.agent, this.params);
}

class AfterCallLLMEvent extends Event {
  final StatefulAgent agent;
  final CallLLMParams params;
  final ModelMessage response;
  final String stopReason;
  AfterCallLLMEvent(this.agent, this.params, this.response, this.stopReason);
}

class LLMChunkEvent extends Event {
  final StatefulAgent agent;
  final CallLLMParams params;
  final ModelMessage response;
  LLMChunkEvent(this.agent, this.params, this.response);
}

class LLMRetryingEvent extends Event {
  final StatefulAgent agent;
  final String reason;
  LLMRetryingEvent(this.agent, this.reason);
}

class BeforeToolCallRequest extends Event {
  final StatefulAgent agent;
  final FunctionCall functionCall;
  BeforeToolCallRequest(this.agent, this.functionCall);
}

class BeforeToolCallResponse {
  final Exception? err;
  final bool approve;
  BeforeToolCallResponse({this.err, this.approve = true});
}

class BeforeToolCallEvent extends Event {
  final StatefulAgent agent;
  final FunctionCall functionCall;
  BeforeToolCallEvent(this.agent, this.functionCall);
}

class AfterToolCallRequest extends Event {
  final StatefulAgent agent;
  final FunctionExecutionResult result;
  AfterToolCallRequest(this.agent, this.result);
}

class AfterToolCallResponse {
  final Exception? err;
  final bool stop;
  AfterToolCallResponse({this.err, this.stop = false});
}

class AfterToolCallEvent extends Event {
  final StatefulAgent agent;
  final FunctionExecutionResult result;
  AfterToolCallEvent(this.agent, this.result);
}

class PlanChangedEvent extends Event {
  final StatefulAgent agent;
  final PlanState plan;
  PlanChangedEvent(this.agent, this.plan);
}

class AgentStoppedEvent extends Event {
  final StatefulAgent agent;
  final List<LLMMessage> input;
  final List<ModelMessage> modelMessages;
  final AgentException? error;
  AgentStoppedEvent(this.agent, this.input, this.modelMessages, {this.error});
}
