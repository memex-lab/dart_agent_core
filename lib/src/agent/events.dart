// --- Events Definitions ---

import 'package:dart_agent_core/dart_agent_core.dart';

class AgentStartedEvent extends Event {
  final StatefulAgent agent;
  final List<LLMMessage> input;
  AgentStartedEvent(this.agent, this.input);
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

class BeforeToolCallEvent extends Event {
  final StatefulAgent agent;
  final FunctionCall functionCall;
  BeforeToolCallEvent(this.agent, this.functionCall);
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
