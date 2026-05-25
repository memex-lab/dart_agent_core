/// Langfuse `/api/public/ingestion` 上的 event 包装格式。
///
/// 一条 event 长这样：
/// ```json
/// {
///   "id": "<uuid>",
///   "type": "trace-create" | "generation-create" | ... ,
///   "timestamp": "2026-05-22T...Z",
///   "body": { ... }
/// }
/// ```
///
/// Body schema 参见 langfuse 仓库 `packages/shared/src/server/ingestion/types.ts`
/// 的 `TraceBody` / `CreateGenerationBody` / `CreateSpanBody` / `ScoreBody`。
class LangfuseEvent {
  /// Event 自身的 UUID（不是 traceId）。Langfuse 用它做 dedup。
  final String id;

  /// `trace-create` / `generation-create` / `generation-update` /
  /// `span-create` / `span-update` / `score-create` 等。
  final String type;

  final DateTime timestamp;

  final Map<String, dynamic> body;

  const LangfuseEvent({
    required this.id,
    required this.type,
    required this.timestamp,
    required this.body,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'body': body,
  };
}
