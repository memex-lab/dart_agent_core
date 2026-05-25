/// Eval subsystem for `dart_agent_core`.
///
/// See [Anthropic — Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
/// for the underlying methodology, and `doc/eval-guide.zh-CN.md` for the
/// usage guide.
///
/// This entry point is intentionally separate from `dart_agent_core.dart`:
/// applications that don't need eval primitives should not pay the
/// import cost. Backward compatibility is preserved.
library;

// Core types
export 'src/eval/core/reference_solution.dart';
export 'src/eval/core/transcript.dart';
export 'src/eval/core/outcome.dart';
export 'src/eval/core/trial.dart';
export 'src/eval/core/trial_result.dart';
export 'src/eval/core/eval_task.dart';
export 'src/eval/core/eval_suite.dart';
export 'src/eval/core/eval_context.dart';
export 'src/eval/core/eval_environment.dart';
export 'src/eval/core/agent_harness_factory.dart';
export 'src/eval/core/eval_runner.dart';
export 'src/eval/core/eval_run_report.dart';
export 'src/eval/core/eval_run_config.dart';

// Graders
export 'src/eval/graders/grader.dart';
export 'src/eval/graders/score.dart';
export 'src/eval/graders/code_grader.dart';
export 'src/eval/graders/model_grader.dart';
export 'src/eval/graders/human_grader.dart';

// LLM (recording / replay / rate limit)
export 'src/eval/llm/llm_request_hash.dart';
export 'src/eval/llm/recording_store.dart';
export 'src/eval/llm/recording_llm_client.dart';
export 'src/eval/llm/replay_llm_client.dart';
export 'src/eval/llm/rate_limit_gate.dart';

// Observability
export 'src/eval/observability/trace_exporter.dart';
export 'src/eval/observability/jsonl_trace_exporter.dart';
export 'src/eval/observability/composite_trace_exporter.dart';
export 'src/eval/observability/transcript_viewer.dart';
export 'src/eval/observability/langfuse/langfuse_config.dart';
export 'src/eval/observability/langfuse/langfuse_event.dart';
export 'src/eval/observability/langfuse/langfuse_client.dart';
export 'src/eval/observability/langfuse/langfuse_trace_exporter.dart';

// Metrics
export 'src/eval/metrics/pass_at_k.dart';
export 'src/eval/metrics/pass_caret_k.dart';
export 'src/eval/metrics/classification_metrics.dart';

// Suite Health (Anthropic Step 7)
export 'src/eval/suite_health/saturation_status.dart';
export 'src/eval/suite_health/suite_health_report.dart';
export 'src/eval/suite_health/suite_health_analyzer.dart';

// Calibration (Anthropic Step 5)
export 'src/eval/calibration/calibration_report.dart';
export 'src/eval/calibration/judge_calibrator.dart';

// Reporting
export 'src/eval/reporting/report_store.dart';
export 'src/eval/reporting/report_generator.dart';
export 'src/eval/reporting/diff_reporter.dart';

// Loaders (data-driven suites)
export 'src/eval/loaders/grader_registry.dart';
export 'src/eval/loaders/json_eval_task.dart';
export 'src/eval/loaders/suite_loader.dart';
