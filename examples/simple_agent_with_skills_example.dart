import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';

// 1. Define a Skill with its own system prompt and tools

class TranslationSkill extends Skill {
  TranslationSkill()
    : super(
        name: 'translation',
        description:
            'Translate text between languages using the translation tool.',
        systemPrompt: '''
You are a professional translator. When asked to translate:
- Always use the translate tool to perform the translation.
- Provide the result clearly, noting the source and target languages.
''',
        tools: [_translateTool],
      );

  static final _translateTool = Tool(
    name: 'translate',
    description: 'Translate text to a target language.',
    executable: _translate,
    parameters: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'description': 'Text to translate'},
        'targetLanguage': {
          'type': 'string',
          'description': 'Target language, e.g. Spanish, French, Japanese',
        },
      },
      'required': ['text', 'targetLanguage'],
    },
  );

  static String _translate(String text, String targetLanguage) {
    // Simulated translation
    final translations = {
      'japanese': {'hello': 'こんにちは', 'goodbye': 'さようなら'},
      'spanish': {'hello': 'hola', 'goodbye': 'adiós'},
      'french': {'hello': 'bonjour', 'goodbye': 'au revoir'},
    };
    final lang = targetLanguage.toLowerCase();
    final word = text.toLowerCase().trim();
    return translations[lang]?[word] ?? '[$lang translation of "$text"]';
  }
}

class MathSkill extends Skill {
  MathSkill()
    : super(
        name: 'math',
        description: 'Perform mathematical calculations.',
        systemPrompt: 'You are a math assistant. Use the calculator tool for computations.',
        tools: [_calcTool],
      );

  static final _calcTool = Tool(
    name: 'calculator',
    description: 'Evaluate a math expression.',
    executable: _calculate,
    parameters: {
      'type': 'object',
      'properties': {
        'expression': {
          'type': 'string',
          'description': 'A simple math expression, e.g. "12 * 7"',
        },
      },
      'required': ['expression'],
    },
  );

  static String _calculate(String expression) {
    // Very simplified expression evaluator for demo
    final parts = expression.split(RegExp(r'\s+'));
    if (parts.length == 3) {
      final a = double.tryParse(parts[0]);
      final b = double.tryParse(parts[2]);
      if (a != null && b != null) {
        switch (parts[1]) {
          case '+':
            return '${a + b}';
          case '-':
            return '${a - b}';
          case '*':
            return '${a * b}';
          case '/':
            return b != 0 ? '${a / b}' : 'Error: division by zero';
        }
      }
    }
    return 'Could not evaluate: $expression';
  }
}

// 2. Run the agent with dynamic skills

void main() async {
  final apiKey = Platform.environment['OPENAI_API_KEY'] ?? 'YOUR_API_KEY';
  final client = OpenAIClient(apiKey: apiKey);
  final modelConfig = ModelConfig(model: 'gpt-4o-mini');

  final agent = StatefulAgent(
    name: 'skill_agent',
    client: client,
    modelConfig: modelConfig,
    state: AgentState.empty(),
    systemPrompts: ['You are a versatile assistant with optional skills.'],
    // Both skills start inactive. The agent will activate them as needed
    // using the built-in activate_skills / deactivate_skills tools.
    skills: [TranslationSkill(), MathSkill()],
  );

  // The agent should recognize it needs the translation skill and activate it
  print('Asking agent to translate (it should activate the translation skill)...\n');
  final responses = await agent.run([
    UserMessage.text('How do you say "hello" in Japanese?'),
  ]);

  print('Agent response: ${(responses.last as ModelMessage).textOutput}');
  print('Active skills: ${agent.state.activeSkills}');
}
