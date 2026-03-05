import 'package:dart_agent_core/dart_agent_core.dart';
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
        "- **CRITICAL**: NEVER call `activateSkills` or `deactivateSkills` on the **Core Capabilities** listed in Section 1. They are built-in.",
      );
    }

    buffer.writeln(
      "- **WHEN TO ACTIVATE**: If a user request requires specific expertise listed in **Section 2 (Optional Capabilities)** and the skill is currently [INACTIVE], you MUST call `activateSkills(['skill_name'])`.",
    );
    buffer.writeln(
      "- **WHEN TO DEACTIVATE**: If an optional skill is no longer relevant to the current step (e.g., switching from coding to casual chat), call `deactivateSkills(['skill_name'])` to reduce noise.",
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

String _activateSkills(List<String> skill_names) {
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

  for (var name in skill_names) {
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

String _deactivateSkills(List<String> skill_names) {
  final state = AgentCallToolContext.current!.state;
  final skills = AgentCallToolContext.current!.agent.skills ?? [];
  final forceActiveSkillNames = skills
      .where((s) => s.forceActivate)
      .map((s) => s.name)
      .toList();

  final removed = <String>[];
  final notFound = <String>[];
  final forceActivated = <String>[];

  for (var name in skill_names) {
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
