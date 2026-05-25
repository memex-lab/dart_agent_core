import 'dart:convert';
import 'dart:io';

import '../core/eval_suite.dart';
import '../core/eval_task.dart';
import '../core/reference_solution.dart';
import '../graders/grader.dart';
import 'grader_registry.dart';
import 'json_eval_task.dart';

/// Loads an [EvalSuite] from a directory laid out as:
///
/// ```
/// suites/<suite_name>/
///   suite.json                 ← suite metadata (incl. agent_name)
///   tasks/                     ← one JSON file per task; sub-folders
///     positive/                  are allowed for organization
///       my_task.json
///     negative/
///       my_other_task.json
/// ```
///
/// `suite.json` schema:
/// ```json
/// {
///   "name": "card_agent_capability",
///   "agent_name": "card_agent",
///   "kind": "capability",
///   "requireReferenceSolution": true,
///   "taskPassThreshold": 1.0
/// }
/// ```
///
/// Each `<task>.json` follows the schema documented on [JsonEvalTask].
/// Note that `agent_name` belongs on the suite, not on individual tasks
/// — every task in a suite targets the same agent.
///
/// **Why a directory layout?** Big task sets quickly outgrow a single
/// JSON blob. One file per task lets product owners review/PR a task
/// at a time, lets git diffs be readable, and lets sub-folders group
/// tasks by failure bucket / source / difficulty.
EvalSuite loadEvalSuiteFromDir(
  Directory root, {
  required GraderRegistry graderRegistry,
}) {
  if (!root.existsSync()) {
    throw ArgumentError('Suite directory does not exist: ${root.path}');
  }

  // 1. Suite metadata.
  final suiteFile = File('${root.path}/suite.json');
  if (!suiteFile.existsSync()) {
    throw StateError(
      'Missing suite.json at ${suiteFile.path}. '
      'Every suite directory must declare its name + kind.',
    );
  }
  final suiteJson =
      jsonDecode(suiteFile.readAsStringSync()) as Map<String, dynamic>;
  final name = (suiteJson['name'] as String?)?.trim();
  if (name == null || name.isEmpty) {
    throw StateError('${suiteFile.path}: "name" is required and non-empty.');
  }
  final agentName = (suiteJson['agent_name'] as String?)?.trim();
  if (agentName == null || agentName.isEmpty) {
    throw StateError(
      '${suiteFile.path}: "agent_name" is required and non-empty.',
    );
  }
  final kindStr = (suiteJson['kind'] as String?)?.trim() ?? 'mixed';
  final kind = SuiteKind.values.firstWhere(
    (k) => k.name == kindStr,
    orElse: () => throw StateError(
      '${suiteFile.path}: invalid kind "$kindStr". '
      'Use one of ${SuiteKind.values.map((k) => k.name).toList()}',
    ),
  );
  final requireReferenceSolution =
      suiteJson['requireReferenceSolution'] as bool? ?? false;
  final taskPassThreshold =
      (suiteJson['taskPassThreshold'] as num?)?.toDouble() ?? 1.0;

  // 2. Task files (recursive, alphabetical within each folder).
  final tasksDir = Directory('${root.path}/tasks');
  if (!tasksDir.existsSync()) {
    throw StateError(
      'Missing tasks/ directory at ${tasksDir.path}. '
      'Place one task JSON file per test under tasks/.',
    );
  }
  final taskFiles = <File>[];
  for (final entity in tasksDir.listSync(recursive: true)) {
    if (entity is File && entity.path.toLowerCase().endsWith('.json')) {
      taskFiles.add(entity);
    }
  }
  if (taskFiles.isEmpty) {
    throw StateError(
      'No task files found under ${tasksDir.path}. '
      'Add at least one task JSON before loading the suite.',
    );
  }
  // Stable order: alphabetical by full path. Same task, same position
  // across runs — important for diff/saturation reports.
  taskFiles.sort((a, b) => a.path.compareTo(b.path));

  final tasks = <EvalTask>[
    for (final f in taskFiles)
      _decodeTask(f, rootDir: root, graderRegistry: graderRegistry),
  ];

  return EvalSuite(
    name: name,
    agentName: agentName,
    kind: kind,
    tasks: tasks,
    requireReferenceSolution: requireReferenceSolution,
    taskPassThreshold: taskPassThreshold,
  );
}

JsonEvalTask _decodeTask(
  File file, {
  required Directory rootDir,
  required GraderRegistry graderRegistry,
}) {
  final relPath = file.path.replaceFirst('${rootDir.path}/', '');
  Map<String, dynamic> json;
  try {
    json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  } catch (e) {
    throw StateError('$relPath: failed to parse JSON — $e');
  }

  String require(String key) {
    final v = json[key];
    if (v is! String || v.trim().isEmpty) {
      throw StateError('$relPath: "$key" is required and must be a string.');
    }
    return v;
  }

  final id = require('id');
  final description = require('description');

  final input = (json['input'] as Map?)?.cast<String, dynamic>() ?? const {};
  final metadata =
      (json['metadata'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ??
      const <String, String>{};

  final trialsPerRun = (json['trials_per_run'] as num?)?.toInt() ?? 1;
  final timeoutSecs = (json['timeout_seconds'] as num?)?.toInt();

  ReferenceSolution? ref;
  final refJson = json['reference_solution'];
  if (refJson is Map) {
    final refMap = refJson.cast<String, dynamic>();
    final sourceStr = (refMap['source'] as String?) ?? 'manual';
    final source = ReferenceSolutionSource.values.firstWhere(
      (s) => s.name == sourceStr,
      orElse: () => ReferenceSolutionSource.manual,
    );
    ref = ReferenceSolution(
      expectedOutcome: (refMap['expected_outcome'] as Map?)
          ?.cast<String, dynamic>(),
      source: source,
    );
  }

  // 3. Resolve graders by name through the registry.
  final gradersJson = json['graders'];
  if (gradersJson is! List || gradersJson.isEmpty) {
    throw StateError('$relPath: "graders" must be a non-empty list.');
  }
  final graders = <Grader>[];
  for (final raw in gradersJson) {
    if (raw is! Map) {
      throw StateError(
        '$relPath: every grader must be an object, got ${raw.runtimeType}',
      );
    }
    final entry = raw.cast<String, dynamic>();
    final name = entry['name'];
    if (name is! String || name.trim().isEmpty) {
      throw StateError('$relPath: grader entry missing "name".');
    }
    final config =
        (entry['config'] as Map?)?.cast<String, dynamic>() ?? const {};
    if (!graderRegistry.contains(name)) {
      throw StateError(
        '$relPath: grader "$name" is not registered. '
        'Known graders: ${graderRegistry.registeredNames.toList()}',
      );
    }
    graders.add(graderRegistry.build(name, config));
  }

  return JsonEvalTask(
    id: id,
    description: description,
    input: input,
    referenceSolution: ref,
    metadata: metadata,
    graders: graders,
    trialsPerRun: trialsPerRun,
    timeout: timeoutSecs == null ? null : Duration(seconds: timeoutSecs),
  );
}
