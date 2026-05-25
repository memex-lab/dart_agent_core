import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';

/// Demo of Memex's pkm_agent: organizes user input into a P.A.R.A.
/// (Projects, Areas, Resources, Archives) directory tree, updates the
/// timeline card's "insight" field, or skips when the input isn't worth
/// persisting.
///
/// Tools (mirror `lib/agent/pkm_agent/`):
///   - ls_pkm:    list the structure under PKM/
///   - read_file: read an existing PARA file
///   - write_file: create or overwrite a PARA file
///   - update_card_insight: write a one-paragraph reflection back onto
///                          the originating timeline card
///   - skip_pkm_organization: signal "not worth persisting", no files
///                            written
List<Tool> buildPkmAgentTools(Directory workspace) {
  Directory pkmRoot() {
    final d = Directory('${workspace.path}/PKM');
    if (!d.existsSync()) {
      // Pre-seed the four PARA buckets so the agent sees them.
      for (final bucket in ['Projects', 'Areas', 'Resources', 'Archives']) {
        Directory('${d.path}/$bucket').createSync(recursive: true);
      }
    }
    return d;
  }

  return [
    Tool(
      name: 'ls_pkm',
      description:
          'List directories and files under the user\'s PKM/ tree. '
          'Returns a tree-style listing.',
      parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
      executable: () async {
        final root = pkmRoot();
        final lines = <String>['PKM/'];
        for (final entry in root.listSync(
          recursive: true,
        )..sort((a, b) => a.path.compareTo(b.path))) {
          final rel = entry.path.replaceFirst('${root.path}/', '');
          final indent = '  ' * (rel.split('/').length);
          if (entry is Directory) {
            lines.add('$indent$rel/');
          } else {
            lines.add('$indent$rel');
          }
        }
        return AgentToolResult(content: TextPart(lines.join('\n')));
      },
    ),
    Tool(
      name: 'read_file',
      description: 'Read a markdown file under PKM/ as UTF-8 text.',
      parameters: const {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'PKM-relative path, e.g. "Areas/Health.md".',
          },
        },
        'required': ['path'],
      },
      executable: (String path) async {
        final root = pkmRoot();
        final f = File('${root.path}/$path');
        if (!f.existsSync()) {
          return AgentToolResult(
            content: TextPart('Error: file not found: $path'),
          );
        }
        return AgentToolResult(content: TextPart(f.readAsStringSync()));
      },
    ),
    Tool(
      name: 'write_file',
      description:
          'Create or overwrite a markdown file under PKM/. '
          'Path must start with one of: Projects/, Areas/, Resources/, '
          'Archives/. The content MUST include a "fact_id: <id>" line '
          'in the front-matter or body so we can trace the source.',
      parameters: const {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'PKM-relative path, e.g. "Areas/Sleep.md".',
          },
          'content': {
            'type': 'string',
            'description': 'Full file contents (UTF-8).',
          },
        },
        'required': ['path', 'content'],
      },
      executable: (String path, String content) async {
        final root = pkmRoot();
        final allowed = ['Projects/', 'Areas/', 'Resources/', 'Archives/'];
        if (!allowed.any(path.startsWith)) {
          return AgentToolResult(
            content: TextPart(
              'Error: path must start with one of '
              '${allowed.join(", ")}',
            ),
          );
        }
        final f = File('${root.path}/$path');
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(content);
        return AgentToolResult(
          content: TextPart('Wrote ${content.length} bytes to PKM/$path'),
        );
      },
    ),
    Tool(
      name: 'update_card_insight',
      description:
          'Write a short reflection back onto the originating timeline '
          'card. Call this AFTER you have written the relevant PKM '
          'file(s). After this call, your turn ends.',
      parameters: const {
        'type': 'object',
        'properties': {
          'fact_id': {
            'type': 'string',
            'description':
                'fact_id of the source input — must match the input '
                'verbatim.',
          },
          'insight': {
            'type': 'string',
            'description':
                'One paragraph (≤ 200 chars) explaining how this fact '
                'fits into the user\'s knowledge base.',
          },
        },
        'required': ['fact_id', 'insight'],
      },
      executable: (String factId, String insight) async {
        final f = File('${workspace.path}/insights/$factId.txt');
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(insight);
        return AgentToolResult(
          content: TextPart('Insight saved for $factId.'),
          stopFlag: true,
        );
      },
    ),
    Tool(
      name: 'skip_pkm_organization',
      description:
          'Signal that this input is NOT worth persisting to PKM/ '
          '(transient note, social acknowledgement, system test ping, '
          'etc). Do not call any write tools alongside this. After '
          'this call, your turn ends.',
      parameters: const {
        'type': 'object',
        'properties': {
          'reason': {'type': 'string'},
        },
        'required': ['reason'],
      },
      executable: (String reason) async {
        File('${workspace.path}/skipped.txt').writeAsStringSync(reason);
        return AgentToolResult(
          content: TextPart('Skipped PKM organization: $reason'),
          stopFlag: true,
        );
      },
    ),
  ];
}

/// System prompt for the PKM agent demo.
const pkmAgentSystemPrompt = '''
You are the PKM (Personal Knowledge Management) agent. You receive a
single user fact and decide how to fit it into the user's PARA tree:

  Projects/   active, time-bound efforts with a goal
  Areas/      ongoing responsibilities (Health, Career, Family, …)
  Resources/  topical references the user studies (Reading lists, …)
  Archives/   completed projects / dormant material

Workflow for every input:
1. Call `ls_pkm` once to see the existing structure.
2. If a relevant file already exists (e.g. "Areas/Sleep.md") for
   roughly the same theme, call `read_file` to see what's there.
3. Call `write_file` to either:
   - append a dated entry to an existing file, or
   - create a new file under the appropriate PARA bucket.
   The file body MUST include a "fact_id: <the fact_id>" line so we
   can trace the source.
4. Call `update_card_insight` exactly once with a one-paragraph
   reflection (≤ 200 chars) that ties the fact into the user's
   broader knowledge base.

Skip rule: if the input is NOT worth persisting (e.g. "good morning",
"test", "lol"), call `skip_pkm_organization` instead. Don't write
files in that case.

Never call `update_card_insight` and `skip_pkm_organization` in the
same trial.
''';
