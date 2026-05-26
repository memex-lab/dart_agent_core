import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';

import '../_shared/agent_harness.dart';
import 'agent.dart';

class CalculatorAgentHarnessFactory implements AgentHarnessFactory {
  final ModelConfig modelConfig;

  const CalculatorAgentHarnessFactory({required this.modelConfig});

  @override
  Future<AgentHarnessSession> create({
    required EvalTask task,
    required Trial trial,
    required EvalContext context,
  }) async {
    return GenericAgentSession(
      task: task,
      trial: trial,
      context: context,
      modelConfig: modelConfig,
      agentName: 'calculator_demo_agent',
      systemPrompt: calculatorSystemPrompt,
      buildTools: (ws) => [
        ...buildCalculatorTools(),
        ...buildSubmissionTools(ws),
      ],
      captureOutcome: _captureOutcome,
    );
  }
}

Outcome _captureOutcome(Directory ws) {
  final answerFile = File('${ws.path}/answer.txt');
  final declinedFile = File('${ws.path}/declined.txt');
  final explanationFile = File('${ws.path}/explanation.txt');

  String? answer;
  if (answerFile.existsSync()) {
    answer = answerFile.readAsStringSync().trim();
  }
  String? declined;
  if (declinedFile.existsSync()) {
    declined = declinedFile.readAsStringSync().trim();
  }
  String? explanation;
  if (explanationFile.existsSync()) {
    explanation = explanationFile.readAsStringSync().trim();
  }

  return Outcome(
    environmentState: {
      'answer': ?answer,
      'declined_reason': ?declined,
      'explanation': ?explanation,
      'submitted': answer != null,
      'declined': declined != null,
    },
    workspaceDiff: WorkspaceDiff(
      created: [
        if (answer != null) 'answer.txt',
        if (declined != null) 'declined.txt',
        if (explanation != null) 'explanation.txt',
      ],
    ),
  );
}
