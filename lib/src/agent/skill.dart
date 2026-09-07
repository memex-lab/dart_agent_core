import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/src/core/fs.dart';
import 'package:logging/logging.dart';

final _logger = Logger('Skill');

abstract class Skill {
  final String name;
  final String description;
  final String systemPrompt;
  final List<Tool>? tools;
  bool forceActivate;

  Skill({
    required this.name,
    required this.description,
    required this.systemPrompt,
    this.tools,
    this.forceActivate = false,
  });
}

class DirectorySkillMetadata {
  final String name;
  final String description;
  final String pathToSkillMd;

  DirectorySkillMetadata({
    required this.name,
    required this.description,
    required this.pathToSkillMd,
  });
}

class DirectorySkillLoadError {
  final String path;
  final String message;

  DirectorySkillLoadError({required this.path, required this.message});
}

class DirectorySkillLoadResult {
  final List<DirectorySkillMetadata> skills;
  final List<DirectorySkillLoadError> errors;

  DirectorySkillLoadResult({required this.skills, required this.errors});
}

class DirectorySkillInjections {
  final List<UserMessage> items;
  final List<String> warnings;

  DirectorySkillInjections({required this.items, required this.warnings});
}

final skillOperationTools = [_activateSkillsTool, _deactivateSkillsTool];

final _activateSkillsTool = Tool(
  name: 'activate_skills',
  description:
      'Activate specific skills from the registry to gain their capabilities and instructions.',
  parameters: {
    'type': 'object',
    'properties': {
      'skill_names': {
        'type': 'array',
        'items': {'type': 'string'},
        'description':
            'A list of skill names to activate (case-sensitive, must match registry).',
      },
    },
    'required': ['skill_names'],
  },
  executable: _activateSkills,
);

final _deactivateSkillsTool = Tool(
  name: 'deactivate_skills',
  description:
      'Deactivate specific skills to remove their instructions and tools from the context.',
  parameters: {
    'type': 'object',
    'properties': {
      'skill_names': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'A list of skill names to deactivate.',
      },
    },
    'required': ['skill_names'],
  },
  executable: _deactivateSkills,
);

SystemPromptPart? buildSkillSystemPrompt(
  AgentState state,
  List<Skill>? skills,
) {
  // If no skills are defined in the system, we don't output anything.
  if (skills == null || skills.isEmpty) return null;

  final buffer = StringBuffer();
  final forceActiveSkills = skills.where((s) => s.forceActivate).toList();
  final optionalSkills = skills.where((s) => !s.forceActivate).toList();

  final activeSkillNames = {
    ...(state.activeSkills ?? []),
    ...forceActiveSkills.map((s) => s.name),
  }.toList();

  // --- Header ---
  buffer.writeln("# DYNAMIC SKILL SYSTEM");
  buffer.writeln("You have access to a modular skill system. ");

  // If all skills are force activate, skip sections 1-3 and go directly to Section 4
  if (optionalSkills.isNotEmpty) {
    buffer.writeln(
      "Some skills are core parts of your identity, while others are optional tools you can activate on demand.\n",
    );

    // --- Section 1: Core Capabilities ---
    if (forceActiveSkills.isNotEmpty) {
      buffer.writeln("## 1. CORE CAPABILITIES (IMMUTABLE)");
      buffer.writeln(
        "These skills are PERMANENTLY ACTIVE. You cannot deactivate them.",
      );
      for (var skill in forceActiveSkills) {
        buffer.writeln("- **${skill.name}** [🔒 ACTIVE]: ${skill.description}");
      }
      buffer.writeln("");
    }

    // --- Section 2: Optional Capabilities ---
    if (optionalSkills.isNotEmpty) {
      buffer.writeln("## 2. OPTIONAL CAPABILITIES (DYNAMIC)");
      buffer.writeln(
        "These skills can be activated or deactivated based on current task needs.",
      );
      for (var skill in optionalSkills) {
        final isActive = activeSkillNames.contains(skill.name);
        final statusIcon = isActive ? "🟢 [ACTIVE]" : "⚪ [INACTIVE]";
        buffer.writeln("- **${skill.name}** $statusIcon: ${skill.description}");
      }
      buffer.writeln("");
    }

    // --- Section 3: Management Protocols ---
    // Teaches the agent HOW and WHEN to use the management tools.
    buffer.writeln("## 3. SKILL MANAGEMENT PROTOCOLS");
    buffer.writeln(
      "You must manage your own context to maintain focus and efficiency.",
    );

    if (forceActiveSkills.isNotEmpty) {
      buffer.writeln(
        "- **CRITICAL**: NEVER call `activate_skills` or `deactivate_skills` on the **Core Capabilities** listed in Section 1. They are built-in.",
      );
    }

    buffer.writeln(
      "- **WHEN TO ACTIVATE**: If a user request requires specific expertise listed in **Section 2 (Optional Capabilities)** and the skill is currently [INACTIVE], call the `activate_skills` tool with `skill_names: ['skill_name']`.",
    );
    buffer.writeln(
      "- **WHEN TO DEACTIVATE**: If an optional skill is no longer relevant to the current step (e.g., switching from coding to casual chat), call the `deactivate_skills` tool with `skill_names: ['skill_name']` to reduce noise.",
    );
    buffer.writeln(
      "- **NOTE**: You can have multiple skills active simultaneously.",
    );
    buffer.writeln("");
  }

  // --- Section 4: Active Skill Instructions ---
  // Only inject the heavy system prompts for skills that are actually turned on.
  // This saves context window and prevents rule conflicts.
  final sectionNumber = optionalSkills.isNotEmpty ? "4" : "1";
  if (activeSkillNames.isNotEmpty) {
    buffer.writeln("## $sectionNumber. ACTIVE SKILL INSTRUCTIONS");
    buffer.writeln(
      "The following rules apply strictly to your CURRENT context:\n",
    );

    // Filter to find the full Skill objects that match the active names
    final activeSkills = skills.where((s) => activeSkillNames.contains(s.name));

    for (var skill in activeSkills) {
      buffer.writeln("### 🔹 Skill: [${skill.name}]");
      buffer.writeln(skill.systemPrompt);
      buffer.writeln(""); // Separation
    }
  } else {
    buffer.writeln("## $sectionNumber. ACTIVE SKILL INSTRUCTIONS");
    buffer.writeln(
      "(No specific skills are currently active. You are operating in General Mode.)",
    );
  }

  return SystemPromptPart(name: "skills", content: buffer.toString());
}

String _activateSkills(List<String> skillNames) {
  final state = AgentCallToolContext.current!.state;
  // Initialize the list if it's null
  state.activeSkills ??= [];

  final skills = AgentCallToolContext.current!.agent.skills ?? [];
  final availableSkillNames = skills.map((s) => s.name).toList();
  final forceActiveSkillNames = skills
      .where((s) => s.forceActivate)
      .map((s) => s.name)
      .toList();

  // Logic: Add only if not already present
  final added = <String>[];
  final alreadyActive = <String>[];
  final forceActivated = <String>[];
  final notFound = <String>[];

  for (var name in skillNames) {
    if (!availableSkillNames.contains(name)) {
      notFound.add(name);
      continue;
    }
    if (forceActiveSkillNames.contains(name)) {
      forceActivated.add(name);
      continue;
    }
    if (!state.activeSkills!.contains(name)) {
      state.activeSkills!.add(name);
      added.add(name);
    } else {
      alreadyActive.add(name);
    }
  }

  final buffer = StringBuffer();
  if (forceActivated.isNotEmpty) {
    buffer.writeln(
      "Skills have been force activated: ${forceActivated.join(', ')}",
    );
  }
  if (added.isNotEmpty) {
    buffer.writeln("Skills have been activated: ${added.join(', ')}");
  }
  if (alreadyActive.isNotEmpty) {
    buffer.writeln("Skills are already active: ${alreadyActive.join(', ')}");
  }
  if (notFound.isNotEmpty) {
    buffer.writeln("Skills not found: ${notFound.join(', ')}");
  }

  _logger.info(buffer.toString());

  return buffer.toString();
}

String _deactivateSkills(List<String> skillNames) {
  final state = AgentCallToolContext.current!.state;
  state.activeSkills ??= [];
  final skills = AgentCallToolContext.current!.agent.skills ?? [];
  final forceActiveSkillNames = skills
      .where((s) => s.forceActivate)
      .map((s) => s.name)
      .toList();

  final removed = <String>[];
  final notFound = <String>[];
  final forceActivated = <String>[];

  for (var name in skillNames) {
    if (forceActiveSkillNames.contains(name)) {
      forceActivated.add(name);
      continue;
    }
    if (state.activeSkills!.contains(name)) {
      state.activeSkills!.remove(name);
      removed.add(name);
    } else {
      notFound.add(name);
    }
  }
  final result = StringBuffer();
  if (removed.isNotEmpty) {
    result.write("Skills have been deactivated: ${removed.join(', ')}. ");
  }
  if (notFound.isNotEmpty) {
    result.write("Skills not found: ${notFound.join(', ')}. ");
  }
  if (forceActivated.isNotEmpty) {
    result.write(
      "Skills are force activated: ${forceActivated.join(', ')}. Do not try to deactivate.",
    );
  }

  _logger.info(result.toString());

  return result.toString();
}

Future<DirectorySkillLoadResult> loadDirectorySkillsFromRoot(
  String rootDirectoryPath, {
  int maxDepth = 6,
}) async {
  if (!fsDirectoryExistsSync(rootDirectoryPath)) {
    return DirectorySkillLoadResult(
      skills: [],
      errors: [
        DirectorySkillLoadError(
          path: rootDirectoryPath,
          message: 'skill directory does not exist',
        ),
      ],
    );
  }

  final skills = <DirectorySkillMetadata>[];
  final errors = <DirectorySkillLoadError>[];
  final seenPaths = <String>{};

  final files = await fsFindFiles(
    rootDirectoryPath,
    'SKILL.md',
    maxDepth: maxDepth,
  );
  for (final filePath in files) {
    final normalized = _normalizePath(filePath);
    if (!seenPaths.add(normalized)) continue;

    try {
      final metadata = await _parseDirectorySkillFile(filePath);
      skills.add(metadata);
    } catch (e) {
      errors.add(
        DirectorySkillLoadError(path: filePath, message: e.toString()),
      );
    }
  }

  skills.sort((a, b) => a.name.compareTo(b.name));
  return DirectorySkillLoadResult(skills: skills, errors: errors);
}

SystemPromptPart? buildDirectorySkillsSystemPrompt(
  List<DirectorySkillMetadata> skills, {
  bool javaScriptExecutionEnabled = false,
}) {
  if (skills.isEmpty) return null;

  final lines = <String>[];
  lines.add("## Skills");
  lines.add(
    "A skill is a set of local instructions to follow that is stored in a `SKILL.md` file. Below is the list of skills that can be used. Each entry includes a name, description, and file path so you can open the source for full instructions when using a specific skill.",
  );
  lines.add("### Available skills");
  for (final skill in skills) {
    lines.add(
      "- ${skill.name}: ${skill.description} (file: ${skill.pathToSkillMd})",
    );
  }
  lines.add("### How to use skills");
  lines.add(
    "- Discovery: The list above is the skills available in this session (name + description + file path). Skill bodies live on disk at the listed paths.\n"
    "- Trigger rules: If the user names a skill (with `\$SkillName` or plain text) OR the task clearly matches a skill's description shown above, you must use that skill for that turn. Multiple mentions mean use them all.\n"
    "- Missing/blocked: If a named skill isn't in the list or the path can't be read, say so briefly and continue with the best fallback.\n"
    "- How to use a skill (progressive disclosure):\n"
    "  1) After deciding to use a skill, open its `SKILL.md`. Read only enough to follow the workflow.\n"
    "  2) When `SKILL.md` references relative paths (e.g., `references/foo.md`), resolve them relative to the skill directory listed above first, and only consider other paths if needed.\n"
    "  3) If `SKILL.md` points to extra folders such as `references/`, load only the specific files needed for the request; don't bulk-load everything.\n"
    "  4) If `assets/` or templates exist, reuse them instead of recreating from scratch.\n"
    "${javaScriptExecutionEnabled ? "  5) If `SKILL.md` references JavaScript scripts (`.js`), use `RunJavaScript` to execute them with minimal arguments and verify outputs.\\n" : ""}"
    "- Coordination and sequencing:\n"
    "  - If multiple skills apply, choose the minimal set that covers the request and state the order you'll use them.\n"
    "  - Announce which skill(s) you're using and why (one short line). If you skip an obvious skill, say why.\n"
    "- Context hygiene:\n"
    "  - Keep context small: summarize long sections instead of pasting them; only load extra files when needed.\n"
    "  - Avoid deep reference-chasing: prefer opening only files directly linked from `SKILL.md` unless you're blocked.\n"
    "  - When variants exist (frameworks, providers, domains), pick only the relevant reference file(s) and note that choice.\n"
    "- Safety and fallback: If a skill can't be applied cleanly (missing files, unclear instructions), state the issue, pick the next-best approach, and continue.",
  );
  final body = lines.join('\n');
  return SystemPromptPart(
    name: "directory_skills",
    content: "<skills_instructions>\n$body\n</skills_instructions>",
  );
}

List<DirectorySkillMetadata> collectExplicitDirectorySkillMentions(
  List<LLMMessage> messages,
  List<DirectorySkillMetadata> skills,
) {
  if (skills.isEmpty || messages.isEmpty) return const [];

  final mentionedNames = <String>{};
  final mentionedPaths = <String>{};

  for (final message in messages) {
    if (message is! UserMessage) continue;
    for (final part in message.contents) {
      if (part is! TextPart) continue;
      final text = part.text;
      for (final match in RegExp(
        r'\[\$([A-Za-z0-9_:\-]+)\]\(([^)]+)\)',
      ).allMatches(text)) {
        final name = match.group(1);
        final path = match.group(2);
        if (name != null && name.isNotEmpty) mentionedNames.add(name);
        if (path != null && path.trim().isNotEmpty) {
          mentionedPaths.add(_normalizePath(path.trim()));
        }
      }
      for (final match in RegExp(r'\$([A-Za-z0-9_:\-]+)').allMatches(text)) {
        final name = match.group(1);
        if (name != null && name.isNotEmpty) mentionedNames.add(name);
      }
    }
  }

  if (mentionedNames.isEmpty && mentionedPaths.isEmpty) return const [];

  final nameCounts = <String, int>{};
  for (final skill in skills) {
    nameCounts.update(skill.name, (value) => value + 1, ifAbsent: () => 1);
  }

  final selected = <DirectorySkillMetadata>[];
  final selectedPaths = <String>{};

  for (final skill in skills) {
    final path = _normalizePath(skill.pathToSkillMd);
    if (mentionedPaths.contains(path) ||
        mentionedPaths.contains('skill://$path')) {
      if (selectedPaths.add(path)) selected.add(skill);
    }
  }

  for (final skill in skills) {
    final path = _normalizePath(skill.pathToSkillMd);
    if (!mentionedNames.contains(skill.name)) continue;
    if ((nameCounts[skill.name] ?? 0) != 1) continue;
    if (selectedPaths.add(path)) selected.add(skill);
  }

  // fallback: allow plain-text skill-name references even without
  // `$skill_name` syntax when the match is unambiguous.
  for (final message in messages) {
    if (message is! UserMessage) continue;
    for (final part in message.contents) {
      if (part is! TextPart) continue;
      final text = part.text;
      for (final skill in skills) {
        final path = _normalizePath(skill.pathToSkillMd);
        if ((nameCounts[skill.name] ?? 0) != 1) continue;
        if (!_textContainsSkillName(text, skill.name)) continue;
        if (selectedPaths.add(path)) selected.add(skill);
      }
    }
  }

  return selected;
}

Future<DirectorySkillInjections> buildDirectorySkillInjections(
  List<DirectorySkillMetadata> mentionedSkills,
) async {
  if (mentionedSkills.isEmpty) {
    return DirectorySkillInjections(items: const [], warnings: const []);
  }

  final items = <UserMessage>[];
  final warnings = <String>[];
  for (final skill in mentionedSkills) {
    try {
      final content = await fsReadAsString(skill.pathToSkillMd);
      final payload =
          "<skill>\n"
          "<name>${skill.name}</name>\n"
          "<path>${skill.pathToSkillMd}</path>\n"
          "$content\n"
          "</skill>";
      items.add(
        UserMessage.text(
          payload,
          metadata: {
            "type": "skill_instructions",
            "skill_name": skill.name,
            "skill_path": skill.pathToSkillMd,
          },
        ),
      );
    } catch (e) {
      warnings.add(
        "Failed to load skill ${skill.name} at ${skill.pathToSkillMd}: $e",
      );
    }
  }

  return DirectorySkillInjections(items: items, warnings: warnings);
}

Future<DirectorySkillMetadata> _parseDirectorySkillFile(
  String skillPath,
) async {
  final content = await fsReadAsString(skillPath);
  final frontmatter = _extractFrontmatter(content);
  if (frontmatter == null) {
    throw Exception('missing YAML frontmatter delimited by ---');
  }
  final parsed = _parseSimpleFrontmatter(frontmatter);
  final path = _normalizePath(fsAbsolutePath(skillPath));
  final fallbackName = _basename(_parentDir(path));
  final name = (parsed['name'] ?? fallbackName).trim();
  if (name.isEmpty) {
    throw Exception('missing skill name');
  }
  final description = (parsed['description'] ?? '').trim();
  if (description.isEmpty) {
    throw Exception('missing skill description');
  }
  return DirectorySkillMetadata(
    name: name,
    description: description,
    pathToSkillMd: path,
  );
}

String? _extractFrontmatter(String content) {
  final lines = const LineSplitter().convert(content);
  if (lines.isEmpty) return null;
  if (lines.first.trim() != '---') return null;
  final buffer = StringBuffer();
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim() == '---') {
      return buffer.isEmpty ? null : buffer.toString();
    }
    buffer.writeln(line);
  }
  return null;
}

Map<String, String> _parseSimpleFrontmatter(String frontmatter) {
  final out = <String, String>{};
  for (final rawLine in const LineSplitter().convert(frontmatter)) {
    final line = rawLine.trimRight();
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    final key = line.substring(0, idx).trim();
    var value = line.substring(idx + 1).trim();
    value = _stripWrappingQuotes(value);
    if (key.isNotEmpty && value.isNotEmpty) {
      out[key] = value;
    }
  }
  return out;
}

String _stripWrappingQuotes(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

bool _textContainsSkillName(String text, String skillName) {
  final escaped = RegExp.escape(skillName);
  final pattern = RegExp(
    '(^|[^A-Za-z0-9_:\\-])$escaped([^A-Za-z0-9_:\\-]|\\\$)',
  );
  return pattern.hasMatch(text);
}

String _normalizePath(String path) {
  if (path.startsWith('skill://')) {
    path = path.substring('skill://'.length);
  }
  return path.replaceAll('\\', '/');
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/');
  return parts.isEmpty ? normalized : parts.last;
}

String _parentDir(String path) {
  final normalized = path.replaceAll('\\', '/');
  final idx = normalized.lastIndexOf('/');
  if (idx <= 0) return normalized;
  return normalized.substring(0, idx);
}
