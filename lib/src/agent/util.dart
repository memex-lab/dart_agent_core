import 'dart:math';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:uuid/uuid.dart';

const uuid = Uuid();

String buildConversationHistory(
  List<LLMMessage> messages, {
  bool includeIndex = false,
}) {
  final buffer = StringBuffer("conversation_history:\n");
  for (int i = 0; i < messages.length; i++) {
    final msg = messages[i];
    final indexStr = includeIndex ? "    index: $i\n" : "";

    if (msg is UserMessage) {
      final content = msg.contents
          .map((p) {
            if (p is TextPart) return p.text;
            if (p is ImagePart) return '[Media: Image (${p.mimeType})]';
            if (p is VideoPart) return '[Media: Video (${p.mimeType})]';
            if (p is AudioPart) return '[Media: Audio (${p.mimeType})]';
            if (p is DocumentPart) return '[Media: Document (${p.mimeType})]';
            return '[Media]';
          })
          .join(' ');
      // Escape multiline content
      final formattedContent = content.contains('\n')
          ? '|\n${content.split('\n').map((l) => "      $l").join('\n')}'
          : content;

      buffer.writeln("  - role: user");
      if (includeIndex) buffer.write(indexStr);
      buffer.writeln("    message: $formattedContent");
    } else if (msg is ModelMessage) {
      buffer.writeln("  - role: agent");
      if (includeIndex) buffer.write(indexStr);
      if (msg.thought != null && msg.thought!.isNotEmpty) {
        final thought = msg.thought!.contains('\n')
            ? '|\n${msg.thought!.split('\n').map((l) => "      $l").join('\n')}'
            : msg.thought;
        buffer.writeln("    thought: $thought");
      }
      if (msg.textOutput != null && msg.textOutput!.isNotEmpty) {
        final output = msg.textOutput!.contains('\n')
            ? '|\n${msg.textOutput!.split('\n').map((l) => "      $l").join('\n')}'
            : msg.textOutput;
        buffer.writeln("    output: $output");
      }
      if (msg.imageOutputs.isNotEmpty) {
        buffer.writeln(
          "    output: [Media: ${msg.imageOutputs.length} Images]",
        );
      }
      if (msg.functionCalls.isNotEmpty) {
        final funcNames = msg.functionCalls.map((f) => f.name).join(', ');
        buffer.writeln("    function_call: [$funcNames]");
      }
    } else if (msg is FunctionExecutionResultMessage) {
      buffer.writeln("  - role: function_execution_result");
      if (includeIndex) buffer.write(indexStr);
      buffer.writeln("    results:");
      for (final r in msg.results) {
        buffer.writeln("      - name: ${r.name}");
        final args = r.arguments.contains('\n')
            ? '|\n${r.arguments.split('\n').map((l) => "          $l").join('\n')}'
            : r.arguments;
        buffer.writeln("        args: $args");

        final resultParts = r.content
            .map((p) {
              if (p is TextPart) return p.text;
              return '[Media]';
            })
            .join(' ');
        final result = resultParts.contains('\n')
            ? '|\n${resultParts.split('\n').map((l) => "          $l").join('\n')}'
            : resultParts;
        buffer.writeln("        result: $result");
      }
    } else if (msg is SystemMessage) {
      // Optional: System messages are often implicit, but we can include them if needed.
      // Based on user prompt structure, skipping explicitly or adding as 'system'.
      // Adding for completeness as 'system' if it appears in history list.
      buffer.writeln("  - role: system");
      if (includeIndex) buffer.write(indexStr);
      final content = msg.content.contains('\n')
          ? '|\n${msg.content.split('\n').map((l) => "      $l").join('\n')}'
          : msg.content;
      buffer.writeln("    message: $content");
    }
  }
  return buffer.toString();
}

bool isSubAgentMode(AgentState state) {
  return state.metadata['sub_agent_mode'] ?? false;
}

String generateEpisodeId(String type) {
  const chars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final rnd = Random();
  final randomString = List.generate(
    6,
    (index) => chars[rnd.nextInt(chars.length)],
  ).join();
  return "${type}_$randomString";
}
