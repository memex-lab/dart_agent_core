import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';

import '../_shared/agent_harness.dart';
import 'agent.dart';

class CardAgentHarnessFactory implements AgentHarnessFactory {
  final ModelConfig modelConfig;
  const CardAgentHarnessFactory({required this.modelConfig});

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
      agentName: 'card_agent_demo',
      systemPrompt: cardAgentSystemPrompt,
      buildTools: buildCardAgentTools,
      captureOutcome: _captureCardOutcome,
    );
  }
}

Outcome _captureCardOutcome(Directory ws, SessionState state) {
  final factId = _findFactId(state);
  final cardFile = factId == null
      ? null
      : File('${ws.path}/cards/$factId.yaml');
  final declinedFile = File('${ws.path}/declined.txt');

  Map<String, dynamic>? cardSummary;
  if (cardFile != null && cardFile.existsSync()) {
    final raw = cardFile.readAsStringSync();
    cardSummary = _parseSimpleYaml(raw);
  }

  String? declined;
  if (declinedFile.existsSync()) {
    declined = declinedFile.readAsStringSync().trim();
  }

  return Outcome(
    environmentState: {
      'fact_id': ?factId,
      'card_saved': cardSummary != null,
      'card_status': ?cardSummary?['status'],
      'card_template_id': ?cardSummary?['template_id'],
      'card_title': ?cardSummary?['title'],
      'card_tags': ?cardSummary?['tags'],
      'card_fields': ?cardSummary?['fields'],
      'declined': declined != null,
      'declined_reason': ?declined,
    },
    workspaceDiff: WorkspaceDiff(
      created: [
        if (cardFile != null && cardFile.existsSync()) 'cards/$factId.yaml',
        if (declinedFile.existsSync()) 'declined.txt',
      ],
    ),
  );
}

/// Pull the fact_id from the most recent successful save_timeline_card
/// tool call. Falls back to the fact_id in the input prompt.
String? _findFactId(SessionState state) {
  for (final tc in state.toolCalls.reversed) {
    if (tc.toolName == 'save_timeline_card' && !tc.isError) {
      final fid = tc.arguments['fact_id'];
      if (fid is String) return fid;
    }
  }
  return null;
}

/// Tiny YAML parser for the subset our demo writes. Returns scalars as
/// strings, lists as `List<String>`, and maps as `Map<String, dynamic>`.
Map<String, dynamic> _parseSimpleYaml(String text) {
  final out = <String, dynamic>{};
  String? currentKey;
  Map<String, dynamic>? currentMap;
  List<String>? currentList;
  for (final raw in text.split('\n')) {
    final line = raw;
    if (line.trim().isEmpty) continue;

    if (line.startsWith('  - ')) {
      currentList ??= <String>[];
      currentList.add(_unquote(line.substring(4).trim()));
      if (currentKey != null) out[currentKey] = currentList;
      continue;
    }
    if (line.startsWith('  ') && currentMap != null) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final k = line.substring(2, colon).trim();
      final v = line.substring(colon + 1).trim();
      currentMap[k] = _unquote(v);
      if (currentKey != null) out[currentKey] = currentMap;
      continue;
    }

    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final key = line.substring(0, colon).trim();
    final rest = line.substring(colon + 1).trim();
    currentKey = key;
    currentMap = null;
    currentList = null;
    if (rest.isEmpty) {
      // Collection follows.
      currentMap = <String, dynamic>{};
      currentList = null;
      out[key] = currentMap;
    } else {
      out[key] = _unquote(rest);
    }
  }
  return out;
}

String _unquote(String s) {
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    return s.substring(1, s.length - 1).replaceAll(r'\"', '"');
  }
  return s;
}
