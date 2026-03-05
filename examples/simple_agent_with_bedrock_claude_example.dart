import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';

String runTranslator(String text, String targetLang) {
  if (targetLang.toLowerCase() == 'spanish') return 'Hola mundo';
  if (targetLang.toLowerCase() == 'french') return 'Bonjour le monde';
  return 'Unknown translation';
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

  final modelConfig = ModelConfig(model: 'us.anthropic.claude-opus-4-6-v1');

  final translateTool = Tool(
    name: 'translate_text',
    description: 'Translate simple phrases into a target language.',
    executable: runTranslator,
    parameters: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'description': 'Text to translate'},
        'targetLang': {
          'type': 'string',
          'description': 'Language to translate to',
        },
      },
      'required': ['text', 'targetLang'],
    },
  );

  final agent = StatefulAgent(
    name: 'claude_bedrock_agent',
    client: client,
    tools: [translateTool],
    modelConfig: modelConfig,
    state: AgentState.empty(),
  );

  print('Sending message to Claude Bedrock agent to use translator...');
  final responses = await agent.run([
    UserMessage.text(
      'Please translate "Hello world" into French using the translation tool.',
    ),
  ]);

  print('Agent response:\n${(responses.last as ModelMessage).textOutput}');
}
