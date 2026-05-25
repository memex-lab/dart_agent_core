import 'dart:io';

import 'package:dart_agent_core/eval.dart';

import 'graders.dart';

/// Registers the three PKM-agent graders so the loader can resolve
/// them from JSON `{"name": "...", "config": {...}}` entries.
GraderRegistry buildPkmGraderRegistry() {
  final reg = GraderRegistry();

  reg.register(
    'pkm_organized',
    (cfg) => PkmOrganizedGrader(
      expectedFactId: cfg['fact_id'] as String,
      expectedBuckets: (cfg['buckets'] as List).cast<String>(),
      mustContainSubstrings:
          (cfg['must_contain'] as List?)?.cast<String>() ?? const [],
    ),
  );

  reg.register('pkm_skipped', (_) => PkmSkippedGrader());
  reg.register('read_before_write', (_) => PkmReadBeforeWriteGrader());

  return reg;
}

/// Default suite path under `example/eval_demo/`. Resolves relative to
/// the repo root when run via `dart run example/eval_demo/main.dart`.
String defaultPkmSuiteDir() =>
    'example/eval_demo/pkm_agent/suites/pkm_capability';

/// Loads the demo suite from disk. Code path stays a single function so
/// callers can override the directory via env var or CLI flag.
EvalSuite buildPkmAgentDemoSuite({String? suiteDir}) {
  final dir = Directory(suiteDir ?? defaultPkmSuiteDir());
  return loadEvalSuiteFromDir(dir, graderRegistry: buildPkmGraderRegistry());
}
