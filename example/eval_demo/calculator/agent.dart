import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';

/// Builds the four arithmetic tools used by the calculator agent.
/// Each tool writes nothing to disk — they only return numeric results.
List<Tool> buildCalculatorTools() {
  return [
    Tool(
      name: 'add',
      description: 'Add two numbers and return their sum.',
      parameters: {
        'type': 'object',
        'properties': {
          'a': {'type': 'number'},
          'b': {'type': 'number'},
        },
        'required': ['a', 'b'],
      },
      executable: (num a, num b) async {
        return AgentToolResult(content: TextPart('${a + b}'));
      },
    ),
    Tool(
      name: 'subtract',
      description: 'Subtract b from a and return the difference.',
      parameters: {
        'type': 'object',
        'properties': {
          'a': {'type': 'number'},
          'b': {'type': 'number'},
        },
        'required': ['a', 'b'],
      },
      executable: (num a, num b) async {
        return AgentToolResult(content: TextPart('${a - b}'));
      },
    ),
    Tool(
      name: 'multiply',
      description: 'Multiply two numbers and return their product.',
      parameters: {
        'type': 'object',
        'properties': {
          'a': {'type': 'number'},
          'b': {'type': 'number'},
        },
        'required': ['a', 'b'],
      },
      executable: (num a, num b) async {
        return AgentToolResult(content: TextPart('${a * b}'));
      },
    ),
    Tool(
      name: 'divide',
      description: 'Divide a by b. Returns an error if b is zero.',
      parameters: {
        'type': 'object',
        'properties': {
          'a': {'type': 'number'},
          'b': {'type': 'number'},
        },
        'required': ['a', 'b'],
      },
      executable: (num a, num b) async {
        if (b == 0) {
          throw ArgumentError('division by zero');
        }
        return AgentToolResult(content: TextPart('${a / b}'));
      },
    ),
  ];
}

/// Tool factory bound to a workspace directory. The `submit_answer` tool
/// writes the final answer to `${workspace}/answer.txt`. This is the
/// observable [Outcome] that graders inspect.
///
/// `decline` lets the agent gracefully refuse off-topic prompts (e.g.
/// "what should I eat tomorrow"). It writes a sentinel file `declined.txt`
/// whose presence the negative-case grader checks for.
List<Tool> buildSubmissionTools(Directory workspace) {
  return [
    Tool(
      name: 'submit_answer',
      description:
          'Submit the final numeric answer to the user\'s question. '
          'Call this exactly once after you have computed the result. '
          'After this call, your turn ends.',
      parameters: {
        'type': 'object',
        'properties': {
          'value': {'type': 'number', 'description': 'The numeric answer.'},
          'explanation': {
            'type': 'string',
            'description': 'Short rationale (one sentence).',
          },
        },
        'required': ['value'],
      },
      executable: (num value, String? explanation) async {
        final f = File('${workspace.path}/answer.txt');
        f.writeAsStringSync(value.toString());
        if (explanation != null) {
          File(
            '${workspace.path}/explanation.txt',
          ).writeAsStringSync(explanation);
        }
        return AgentToolResult(
          content: TextPart('Answer submitted: $value'),
          stopFlag: true,
        );
      },
    ),
    Tool(
      name: 'decline',
      description:
          'Decline the request when it is not a math question. '
          'Provide a short reason. After this call, your turn ends.',
      parameters: {
        'type': 'object',
        'properties': {
          'reason': {
            'type': 'string',
            'description': 'Why this prompt cannot be answered.',
          },
        },
        'required': ['reason'],
      },
      executable: (String reason) async {
        File('${workspace.path}/declined.txt').writeAsStringSync(reason);
        return AgentToolResult(
          content: TextPart('Declined: $reason'),
          stopFlag: true,
        );
      },
    ),
  ];
}

/// System prompt for the calculator agent.
const calculatorSystemPrompt = '''
You are a careful calculator agent.

Workflow for every user prompt:
1. If the prompt is NOT a math question (e.g. about food, weather, life
   advice), call the `decline` tool with a short reason. Do not invent a
   numeric answer.
2. Otherwise, decompose the problem into single arithmetic steps. Use only
   the provided tools (add / subtract / multiply / divide). You MUST use
   the tools — do not compute mentally.
3. When you have the final numeric answer, call `submit_answer` with the
   numeric value and a one-sentence explanation. After submitting, stop.

Never call `submit_answer` and `decline` in the same turn. Pick exactly one.
''';
