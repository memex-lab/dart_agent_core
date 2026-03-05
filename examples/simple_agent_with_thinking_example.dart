import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';

double calculate(double a, double b, String operator) {
  switch (operator) {
    case '+':
      return a + b;
    case '-':
      return a - b;
    case '*':
      return a * b;
    case '/':
      return a / b;
    default:
      throw ArgumentError('Unknown operator $operator');
  }
}

void main() async {
  final awsAccessKeyId =
      Platform.environment['AWS_ACCESS_KEY_ID'] ?? 'YOUR_AWS_ACCESS_KEY';
  final awsSecretAccessKey =
      Platform.environment['AWS_SECRET_ACCESS_KEY'] ?? 'YOUR_AWS_SECRET_KEY';

  final client = BedrockClaudeClient(
    region: 'us-east-1',
    accessKeyId: awsAccessKeyId,
    secretAccessKey: awsSecretAccessKey,
  );

  final mathTool = Tool(
    name: 'calculate',
    description: 'Perform basic math calculations.',
    executable: calculate,
    namedParameters: ['operator'],
    parameters: {
      'type': 'object',
      'properties': {
        'a': {'type': 'number'},
        'b': {'type': 'number'},
        'operator': {
          'type': 'string',
          'enum': ['+', '-', '*', '/'],
        },
      },
      'required': ['a', 'b', 'operator'],
    },
  );

  final modelConfig = ModelConfig(
    model: 'us.anthropic.claude-opus-4-6-v1',
    maxTokens: 4000,
    extra: {
      'thinking': {'type': 'enabled', 'budget_tokens': 3000},
    },
  );

  final agent = StatefulAgent(
    name: 'thinking_agent',
    client: client,
    tools: [mathTool],
    modelConfig: modelConfig,
    state: AgentState.empty(),
    systemPrompts: [
      'You are a logical problem solving assistant. Show your thought process.',
    ],
  );

  print('Sending complex task to thinking agent...');
  final responses = await agent.run([
    UserMessage.text(
      'I have 146 apples. I give half of them away, then buy 34 more. How many do I have? Use the calculator.',
    ),
  ]);

  final lastMessage = responses.last as ModelMessage;

  if (lastMessage.thought != null) {
    print('Agent thought process:\n${lastMessage.thought}\n');
  }

  print('Agent response: ${lastMessage.textOutput}');
}
