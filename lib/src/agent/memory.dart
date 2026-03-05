import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/src/agent/util.dart';

class EpisodicMemory {
  final String id;
  final String summary;
  List<LLMMessage> messages;

  EpisodicMemory({
    required this.id,
    required this.summary,
    required this.messages,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'summary': summary,
    'messages': messages.map((e) => e.toJson()).toList(),
  };

  factory EpisodicMemory.fromJson(Map<String, dynamic> json) {
    return EpisodicMemory(
      id: json['id'] as String,
      summary: json['summary'] as String,
      messages: (json['messages'] as List)
          .map((e) => LLMMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class AgentMessageHistory {
  List<LLMMessage> messages;
  List<EpisodicMemory> episodicMemories;

  AgentMessageHistory({
    List<LLMMessage>? messages,
    List<EpisodicMemory>? episodicMemories,
  }) : messages = messages ?? [],
       episodicMemories = episodicMemories ?? [];

  factory AgentMessageHistory.fromJson(Map<String, dynamic> json) {
    return AgentMessageHistory(
      messages: (json['messages'] as List)
          .map((e) => LLMMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
      episodicMemories:
          (json['episodicMemories'] as List?)
              ?.map((e) => EpisodicMemory.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
    'messages': messages.map((e) => e.toJson()).toList(),
    'episodicMemories': episodicMemories.map((e) => e.toJson()).toList(),
  };
}

final memoryTools = [_retrieveMemoryTool];

final _retrieveMemoryTool = Tool(
  name: 'retrieve_memory',
  description:
      'Retrieve the original raw messages hidden behind a summarized memory ID. '
      'Use this when you need precise details from a past conversation that are summarized.',
  executable: _retrieveMemory,
  parameters: {
    'type': 'object',
    'properties': {
      'snapshot_id': {
        'type': 'string',
        'description': 'The ID of the memory to retrieve (e.g. episode_...).',
      },
      'limit': {
        'type': 'integer',
        'description': 'Max number of messages to retrieve (default 20).',
      },
      'offset': {
        'type': 'integer',
        'description': 'Pagination offset (default 0).',
      },
    },
    'required': ['snapshot_id'],
  },
  namedParameters: ['limit', 'offset'],
);

Future<AgentToolResult> _retrieveMemory(
  String snapshotId, {
  int? limit,
  int? offset,
}) async {
  final effectiveLimit = limit ?? 20;
  final effectiveOffset = offset ?? 0;

  final context = AgentCallToolContext.current!;
  final state = context.state;

  List<LLMMessage>? messages;

  // Search in Episodic Memory
  final episodic = state.history.episodicMemories.firstWhere(
    (m) => m.id == snapshotId,
    orElse: () => EpisodicMemory(id: '', summary: '', messages: []), // Dummy
  );

  if (episodic.id.isNotEmpty) {
    messages = episodic.messages;
  }
  if (messages == null || messages.isEmpty) {
    return AgentToolResult(
      content: TextPart(
        "Memory with ID '$snapshotId' not found or contains no messages.",
      ),
    );
  }

  // Apply pagination
  if (effectiveOffset >= messages.length) {
    return AgentToolResult(
      content: TextPart(
        "Offset out of bounds. Total messages: ${messages.length}",
      ),
    );
  }

  final end = (effectiveOffset + effectiveLimit < messages.length)
      ? effectiveOffset + effectiveLimit
      : messages.length;
  final slicedMessages = messages.sublist(effectiveOffset, end);
  final historyString = buildConversationHistory(
    slicedMessages,
    includeIndex: true,
  );

  return AgentToolResult(
    content: TextPart(
      "Original Messages for ID '$snapshotId' (Offset: $effectiveOffset, Limit: $effectiveLimit):\n$historyString",
    ),
  );
}
