import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';

import '../_shared/agent_harness.dart';
import 'agent.dart';

class PkmAgentHarnessFactory implements AgentHarnessFactory {
  final ModelConfig modelConfig;
  const PkmAgentHarnessFactory({required this.modelConfig});

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
      agentName: 'pkm_agent_demo',
      systemPrompt: pkmAgentSystemPrompt,
      buildTools: buildPkmAgentTools,
      captureOutcome: _capturePkmOutcome,
    );
  }
}

Outcome _capturePkmOutcome(Directory ws) {
  final pkmRoot = Directory('${ws.path}/PKM');
  final created = <String>[];
  final modifiedSnippets = <String, String>{};

  if (pkmRoot.existsSync()) {
    for (final entry in pkmRoot.listSync(recursive: true)) {
      if (entry is! File) continue;
      final rel = entry.path.replaceFirst('${pkmRoot.path}/', '');
      created.add(rel);
      final content = entry.readAsStringSync();
      modifiedSnippets[rel] = content.length > 4096
          ? content.substring(0, 4096)
          : content;
    }
  }

  // Insight & skipped sentinels.
  String? insight;
  final insightsDir = Directory('${ws.path}/insights');
  String? insightForFactId;
  if (insightsDir.existsSync()) {
    for (final f in insightsDir.listSync()) {
      if (f is! File) continue;
      insightForFactId = f.uri.pathSegments.last.replaceAll(
        RegExp(r'\.txt$'),
        '',
      );
      insight = f.readAsStringSync().trim();
      break;
    }
  }

  String? skippedReason;
  final skippedFile = File('${ws.path}/skipped.txt');
  if (skippedFile.existsSync()) {
    skippedReason = skippedFile.readAsStringSync().trim();
  }

  // Did any written file's body include the fact_id?
  final factIdInFiles = <String>{};
  modifiedSnippets.forEach((_, body) {
    final m = RegExp(r'fact_id\s*:\s*(\S+)').firstMatch(body);
    if (m != null) factIdInFiles.add(m.group(1)!);
  });

  return Outcome(
    environmentState: {
      'wrote_files': created,
      'pkm_files_created': created,
      'fact_ids_in_files': factIdInFiles.toList(),
      'insight': ?insight,
      'insight_for_fact_id': ?insightForFactId,
      'updated_insight': insight != null,
      'skipped': skippedReason != null,
      'skipped_reason': ?skippedReason,
    },
    workspaceDiff: WorkspaceDiff(
      created: created.map((p) => 'PKM/$p').toList(),
      contentSnippets: {
        for (final entry in modifiedSnippets.entries)
          'PKM/${entry.key}': entry.value,
      },
    ),
  );
}
