import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/src/agent/util.dart';
import 'package:logging/logging.dart';

abstract class ContextCompressor {
  Future compress(AgentState state);
}

class LLMBasedContextCompressor implements ContextCompressor {
  final Logger _logger = Logger('LLMBasedContextCompressor');
  final LLMClient client;
  final ModelConfig modelConfig;
  final int totalTokenThreshold;
  final int keepRecentMessageSize;

  static const _summaryPromptTemplate = '''
You are the component that summarizes internal chat history into a given structure.

When the conversation history grows too large, you will be invoked to distill the entire history into a concise, structured XML snapshot. This snapshot is CRITICAL, as it will become the agent's *only* memory of the past. The agent will resume its work based solely on this snapshot. All crucial details, plans, errors, and user directives MUST be preserved.

First, you will think through the entire history in a private <scratchpad>. Review the user's overall goal, the agent's actions, tool outputs, file modifications, and any unresolved questions. Identify every piece of information that is essential for future actions.

After your reasoning is complete, generate the final <state_snapshot> XML object. Be incredibly dense with information. Omit any irrelevant conversational filler.

The structure MUST be as follows:

<state_snapshot>
    <overall_goal>
        <!-- A single, concise sentence describing the user's high-level objective. -->
        <!-- Example: "Refactor the authentication service to use a new JWT library." -->
    </overall_goal>

    <key_knowledge>
        <!-- Crucial facts, conventions, and constraints the agent must remember based on the conversation history and interaction with the user. Use bullet points. -->
        <!-- Example:
         - Build Command: `npm run build`
         - Testing: Tests are run with `npm test`. Test files must end in `.test.ts`.
         - API Endpoint: The primary API endpoint is `https://api.example.com/v2`.

        -->
    </key_knowledge>

    <file_system_state>
        <!-- List files that have been created, read, modified, or deleted. Note their status and critical learnings. -->
        <!-- Example:
         - CWD: `/home/user/project/src`
         - READ: `package.json` - Confirmed 'axios' is a dependency.
         - MODIFIED: `services/auth.ts` - Replaced 'jsonwebtoken' with 'jose'.
         - CREATED: `tests/new-feature.test.ts` - Initial test structure for the new feature.
        -->
    </file_system_state>

    <recent_actions>
        <!-- A summary of the last few significant agent actions and their outcomes. Focus on facts. -->
        <!-- Example:
         - Ran `grep 'old_function'` which returned 3 results in 2 files.
         - Ran `npm run test`, which failed due to a snapshot mismatch in `UserProfile.test.ts`.
         - Ran `ls -F static/` and discovered image assets are stored as `.webp`.
        -->
    </recent_actions>

    <current_plan>
        <!-- The agent's step-by-step plan. Mark completed steps. -->
        <!-- Example:
         1. [DONE] Identify all files using the deprecated 'UserAPI'.
         2. [IN PROGRESS] Refactor `src/components/UserProfile.tsx` to use the new 'ProfileAPI'.
         3. [TODO] Refactor the remaining files.
         4. [TODO] Update tests to reflect the API change.
        -->
    </current_plan>
</state_snapshot>
''';

  LLMBasedContextCompressor({
    required this.client,
    this.totalTokenThreshold = 64000,
    this.keepRecentMessageSize = 10,
    required this.modelConfig,
  });

  @override
  Future compress(AgentState state) async {
    if (state.usages.isEmpty) {
      return;
    }
    // Check if we have enough history to even consider compressing
    if (state.history.messages.length <= keepRecentMessageSize) {
      return;
    }

    final lastUsage = state.usages.last;
    if (lastUsage.promptTokens < totalTokenThreshold) {
      return;
    }

    // Summarize History into Episodic Memory
    await _compressToEpisodicMemory(state);
  }

  Future<void> _compressToEpisodicMemory(AgentState state) async {
    // Determine the split index
    // We want to keep the last 'keepRecentMessageSize' messages.
    int splitIndex = state.history.messages.length - keepRecentMessageSize;

    // Adjust splitIndex to respect FunctionCall/ToolResult pairs.
    // We scan backwards from the proposed splitIndex.
    while (splitIndex > 0) {
      final firstToKeep = state.history.messages[splitIndex];
      bool isToolCallResult = firstToKeep is FunctionExecutionResultMessage;
      if (isToolCallResult) {
        splitIndex--;
      } else {
        break;
      }
    }

    // Let's grab the messages to compress.
    final messagesToCompress = state.history.messages.sublist(0, splitIndex);
    final messagesToKeep = state.history.messages.sublist(splitIndex);

    // Filter out SystemMessages from the compression source
    final messagesToSummarize = messagesToCompress
        .where((m) => m is! SystemMessage)
        .toList();

    // If there are less than 3 messages to summarize, we don't need to compress.
    if (messagesToSummarize.length < 3) {
      return;
    }

    final input = <LLMMessage>[
      SystemMessage(_summaryPromptTemplate),
      ...messagesToSummarize,
      UserMessage.text(
        "First, reason in your scratchpad. Then, generate the <state_snapshot>.",
      ),
    ];

    final summaryResponse = await client.generate(
      input,
      modelConfig: modelConfig,
    );

    final summaryText = summaryResponse.textOutput;
    if (summaryText == null || summaryText.isEmpty) {
      _logger.warning("Warning: Empty summary generated.");
      return;
    }

    try {
      final String xmlString = _extractXmlFromResponse(summaryText);

      // Add to Episodic Memory
      EpisodicMemory newEpisodicMemory = EpisodicMemory(
        id: generateEpisodeId('episode'),
        summary: xmlString,
        messages: messagesToSummarize,
      );

      _logger.info(
        "Compression Complete. Added 1 Episodic Memory. ${messagesToSummarize.length} messages compressed.",
      );

      // Update State History (remove compressed messages)
      state.history.episodicMemories.add(newEpisodicMemory);

      final snapshotMessage =
          '$xmlString\n\n(Snapshot ID: ${newEpisodicMemory.id}. If you need to recall specific details from this compressed history, use the `retrieve_memory` tool with this ID.)';

      messagesToKeep.insertAll(0, [
        UserMessage.text(
          snapshotMessage,
          metadata: {"context_compression_reminder": true},
        ),
        ModelMessage(
          textOutput: "Got it. Thanks for the additional context!",
          model: modelConfig.model,
        ),
      ]);

      state.history.messages = messagesToKeep;

      _logger.info(
        "Context compressed. Original: ${state.history.messages.length + messagesToCompress.length}, New: ${state.history.messages.length}.",
      );
    } catch (e) {
      _logger.severe("❌ Error parsing summary XML: $e");
      _logger.fine("Raw Output: $summaryText");
    }
  }

  static String _extractXmlFromResponse(String response) {
    String xmlString = response;
    // Attempt to extract xml block
    if (xmlString.contains('```xml')) {
      final start = xmlString.indexOf('```xml') + 6;
      final end = xmlString.indexOf('```', start);
      if (end != -1) return xmlString.substring(start, end).trim();
    }
    if (xmlString.contains('```')) {
      final start = xmlString.indexOf('```') + 3;
      final end = xmlString.indexOf('```', start);
      if (end != -1) return xmlString.substring(start, end).trim();
    }

    // If no block, look for <state_snapshot> tags
    final startTag = '<state_snapshot>';
    final endTag = '</state_snapshot>';
    final startIdx = xmlString.indexOf(startTag);
    final endIdx = xmlString.lastIndexOf(endTag);

    if (startIdx != -1 && endIdx != -1) {
      return xmlString.substring(startIdx, endIdx + endTag.length).trim();
    }

    return xmlString.trim();
  }
}
