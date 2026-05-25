import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';

/// Demo of Memex's card_agent: turns multimodal user input into a
/// structured Timeline Card YAML and writes it to disk.
///
/// Tools (mirror `lib/agent/card_agent/`):
///   - get_card_metadata: return the catalog of available templates + tags
///   - save_timeline_card: persist a card YAML to the workspace
///   - decline: reject input that should not become a timeline card
///
/// Stop signal: `save_timeline_card` and `decline` set stopFlag = true so
/// the agent runs at most one of them per trial.
List<Tool> buildCardAgentTools(Directory workspace) {
  return [
    Tool(
      name: 'get_card_metadata',
      description:
          'Return the catalog of available card templates and the user\'s '
          'existing tags. Call this once before save_timeline_card so you '
          'can pick the right template_id.',
      parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
      executable: () async {
        final catalog = jsonEncode(_cardCatalog);
        return AgentToolResult(content: TextPart(catalog));
      },
    ),
    Tool(
      name: 'save_timeline_card',
      description:
          'Persist the structured timeline card. Call this exactly once '
          'after you have chosen a template and filled in the fields. '
          'After this call, your turn ends.',
      parameters: const {
        'type': 'object',
        'properties': {
          'fact_id': {
            'type': 'string',
            'description':
                'The fact_id from the user input. Must match exactly.',
          },
          'template_id': {
            'type': 'string',
            'description':
                'One of the template_id values returned by '
                'get_card_metadata.',
          },
          'title': {
            'type': 'string',
            'description': 'Concise card title (≤ 30 chars).',
          },
          'tags': {
            'type': 'array',
            'items': {'type': 'string'},
            'description':
                'Tags. Reuse existing tags from get_card_metadata when '
                'they match; only invent new ones if necessary.',
          },
          'fields': {
            'type': 'object',
            'description':
                'Template-specific fields. Schema depends on '
                'template_id.',
          },
        },
        'required': ['fact_id', 'template_id', 'title', 'fields'],
      },
      parameterMode: ToolParameterMode.object,
      executable: (Map<String, dynamic> args) async {
        final factId = args['fact_id'] as String;
        final templateId = args['template_id'] as String;
        final title = args['title'] as String;
        final tags =
            (args['tags'] as List?)?.cast<String>() ?? const <String>[];
        final fields =
            (args['fields'] as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{};

        final card = <String, dynamic>{
          'fact_id': factId,
          'template_id': templateId,
          'title': title,
          'tags': tags,
          'fields': fields,
          'status': 'completed',
          'persisted_at': DateTime.now().toIso8601String(),
        };

        // Naive YAML encoding. Demo only — production would use a real
        // YAML lib.
        final f = File('${workspace.path}/cards/$factId.yaml');
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(_toYaml(card));

        return AgentToolResult(
          content: TextPart('Saved card $factId with template $templateId.'),
          stopFlag: true,
        );
      },
    ),
    Tool(
      name: 'decline',
      description:
          'Decline the input when it should NOT become a timeline card '
          '(e.g. obvious spam, system test ping, empty content). After '
          'this call, your turn ends.',
      parameters: const {
        'type': 'object',
        'properties': {
          'reason': {'type': 'string'},
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

/// Sample template catalog returned by get_card_metadata. Closely
/// mirrors the shape that the real Memex `TimelineCardSkill` returns.
const Map<String, dynamic> _cardCatalog = {
  'templates': [
    {
      'template_id': 'note',
      'description': 'Plain note. Fields: body (string).',
      'fields_schema': {'body': 'string'},
    },
    {
      'template_id': 'event',
      'description':
          'Time-bound event. Fields: body, start_at (ISO-8601), '
          'location.',
      'fields_schema': {
        'body': 'string',
        'start_at': 'string',
        'location': 'string',
      },
    },
    {
      'template_id': 'task',
      'description':
          'Actionable item. Fields: body, due_at (optional), priority '
          '(low|medium|high).',
      'fields_schema': {
        'body': 'string',
        'due_at': 'string?',
        'priority': 'string',
      },
    },
    {
      'template_id': 'reading',
      'description':
          'Article / book quote. Fields: body, source_title, '
          'source_url (optional).',
      'fields_schema': {
        'body': 'string',
        'source_title': 'string',
        'source_url': 'string?',
      },
    },
  ],
  'existing_tags': ['work', 'health', 'meeting', 'reading', 'ideas', 'family'],
};

String _toYaml(Map<String, dynamic> m) {
  final b = StringBuffer();
  m.forEach((k, v) {
    if (v is List) {
      b.writeln('$k:');
      for (final e in v) {
        b.writeln('  - $e');
      }
    } else if (v is Map) {
      b.writeln('$k:');
      v.forEach((k2, v2) => b.writeln('  $k2: ${_yamlScalar(v2)}'));
    } else {
      b.writeln('$k: ${_yamlScalar(v)}');
    }
  });
  return b.toString();
}

String _yamlScalar(Object? v) {
  if (v == null) return '';
  if (v is num || v is bool) return '$v';
  // Quote strings to keep things simple and YAML-safe enough for the demo.
  return '"${'$v'.replaceAll('"', r'\"')}"';
}

/// System prompt for the card agent demo.
const cardAgentSystemPrompt = '''
You are a Timeline Card agent. Your job is to take the user's raw input
(some combination of text, time, location, asset description) and turn
it into ONE structured timeline card.

Workflow for every prompt:
1. Call `get_card_metadata` once to learn the available templates and
   the user's existing tag list.
2. Pick the best `template_id` for the input:
   - "note" for a plain reflection without strong time/place anchor.
   - "event" when the input clearly refers to a calendar-like event
     (meeting, appointment, gathering) with a date/time.
   - "task" when the input is something the user wants to DO later.
   - "reading" when the input is a quote or excerpt from another work.
3. Reuse tags from `existing_tags` when they fit. Only invent a new
   tag when none of the existing tags apply.
4. Call `save_timeline_card` exactly once. The fact_id must match the
   one in the user's input verbatim.
5. ONLY call `decline` when the input is clearly not worth saving
   (e.g. system ping like "test 123", empty content, obvious spam).

Never call `save_timeline_card` and `decline` in the same turn. Pick
exactly one. Do not repeat get_card_metadata.
''';
