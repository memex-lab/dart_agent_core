/// Anthropic: the final state of the environment at the end of a trial.
///
/// IMPORTANT: this is intentionally **separate** from a [Transcript].
/// The transcript is "what the agent did/said"; the outcome is "what state
/// the environment is in afterwards". Graders should default to inspecting
/// the outcome (Anthropic Step 5: "grade what the agent produced, not the
/// path it took").
class Outcome {
  /// Application-defined environment state. Schema is decided by the
  /// application's outcome extractor.
  ///
  /// Examples:
  ///   - Card agent:    {card_file, card_status, card_template, ...}
  ///   - PKM agent:     {workspace_diff, fact_id_recorded, insight_updated}
  ///   - Schedule agent:{aggregation_yaml, dirty_state, ...}
  final Map<String, dynamic> environmentState;

  /// Optional structural diff of a workspace. Many graders need this.
  final WorkspaceDiff? workspaceDiff;

  const Outcome({required this.environmentState, this.workspaceDiff});

  Map<String, dynamic> toJson() => {
    'environmentState': environmentState,
    if (workspaceDiff != null) 'workspaceDiff': workspaceDiff!.toJson(),
  };

  factory Outcome.fromJson(Map<String, dynamic> json) {
    return Outcome(
      environmentState: (json['environmentState'] as Map)
          .cast<String, dynamic>(),
      workspaceDiff: json['workspaceDiff'] == null
          ? null
          : WorkspaceDiff.fromJson(
              json['workspaceDiff'] as Map<String, dynamic>,
            ),
    );
  }
}

/// Captures filesystem-level changes between fixture setup and trial end.
class WorkspaceDiff {
  /// Absolute paths (relative to workspace root) created during the trial.
  final List<String> created;

  /// Paths modified.
  final List<String> modified;

  /// Paths deleted.
  final List<String> deleted;

  /// Optional content snippets for created/modified files. Keys are paths.
  /// Values are utf-8 text content (trimmed if > 4 KiB).
  final Map<String, String> contentSnippets;

  const WorkspaceDiff({
    this.created = const [],
    this.modified = const [],
    this.deleted = const [],
    this.contentSnippets = const {},
  });

  bool get isEmpty => created.isEmpty && modified.isEmpty && deleted.isEmpty;

  Map<String, dynamic> toJson() => {
    'created': created,
    'modified': modified,
    'deleted': deleted,
    if (contentSnippets.isNotEmpty) 'contentSnippets': contentSnippets,
  };

  factory WorkspaceDiff.fromJson(Map<String, dynamic> json) {
    return WorkspaceDiff(
      created: ((json['created'] as List?) ?? []).cast<String>(),
      modified: ((json['modified'] as List?) ?? []).cast<String>(),
      deleted: ((json['deleted'] as List?) ?? []).cast<String>(),
      contentSnippets:
          ((json['contentSnippets'] as Map?)?.cast<String, String>()) ??
          const {},
    );
  }
}
