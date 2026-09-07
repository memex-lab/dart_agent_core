import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../../core/tool.dart';

/// Computes a stable hash of an LLM request, used as the cache key for
/// recording / replay.
///
/// Stability requirements:
///   - The hash must be deterministic given the same logical request.
///   - It must ignore non-deterministic fields (timestamps, UUIDs, ids).
///   - It must be sensitive to anything that would change the model's
///     output (messages, tools, model id, sampling parameters).
///
/// Non-determinism caveat: when `trialsPerRun > 1`, every trial sends
/// the **same** request (same messages, same tools, same model). Without
/// extra signal the hash collapses across trials and the cache forces
/// every trial to receive an identical response — which silently
/// destroys the non-determinism that pass^k / pass@k are supposed to
/// measure (Anthropic Step 6).
///
/// To preserve per-trial variation, callers can pass [trialSalt] (a
/// stable per-trial identifier such as `runName/taskId#trialIndex`).
/// Each trial then computes a distinct hash and the recording store
/// keeps a separate cache entry per trial. A null salt means "no
/// per-trial axis" — appropriate for one-off requests, judges, or any
/// other call that should be cached once across all trials.
abstract class LLMRequestHash {
  /// Compute the hash for a request.
  String compute({
    required List<LLMMessage> messages,
    required List<Tool>? tools,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    ToolChoice? toolChoice,
    String? trialSalt,
  });
}

/// Default SHA-256 based implementation. Hashes the JSON-encoded
/// `(messages, tools, modelConfig, jsonOutput, toolChoice, trialSalt)` tuple.
/// `Tool.executable` closures are ignored (they're not in toJson).
///
/// **Default-stripped keys**: `timestamp` is always stripped from
/// message JSON before hashing. UserMessage / ModelMessage /
/// FunctionExecutionResultMessage all carry `DateTime.now()`-derived
/// timestamps for tracing purposes, but those values are never
/// semantically part of the LLM request — including them would make
/// every hash unique per process invocation and defeat the cache.
class Sha256LLMRequestHash implements LLMRequestHash {
  /// Additional message-level keys to strip before hashing. `timestamp`
  /// is always stripped — see class docstring. Pass extra keys here
  /// when the application embeds non-deterministic fields in messages
  /// (e.g. trace ids inside system reminders).
  final Set<String> stripMessageKeys;

  /// Total set of keys actually stripped: union of [stripMessageKeys]
  /// and the framework defaults (`timestamp`).
  Set<String> get _effectiveStrip => {'timestamp', ...stripMessageKeys};

  const Sha256LLMRequestHash({this.stripMessageKeys = const {}});

  @override
  String compute({
    required List<LLMMessage> messages,
    required List<Tool>? tools,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    ToolChoice? toolChoice,
    String? trialSalt,
  }) {
    final payload = {
      'messages': messages.map((m) => _stripped(m.toJson())).toList(),
      'tools': tools?.map((t) => t.toJson()).toList(),
      'model': modelConfig.toJson(),
      'jsonOutput': ?jsonOutput,
      'toolChoice': ?toolChoice?.toJson(),
      'trialSalt': ?trialSalt,
    };
    final encoded = utf8.encode(_canonicalJson(payload));
    return sha256.convert(encoded).toString();
  }

  Map<String, dynamic> _stripped(Map<String, dynamic> json) {
    final keys = _effectiveStrip;
    return _strippedRecursive(json, keys) as Map<String, dynamic>;
  }

  Object? _strippedRecursive(Object? value, Set<String> keys) {
    if (value is Map) {
      final out = <String, dynamic>{};
      for (final entry in value.entries) {
        if (entry.key is String && keys.contains(entry.key as String)) {
          continue;
        }
        out['${entry.key}'] = _strippedRecursive(entry.value, keys);
      }
      return out;
    }
    if (value is List) {
      return value.map((e) => _strippedRecursive(e, keys)).toList();
    }
    return value;
  }

  /// Encode JSON with stable key ordering so hashes are deterministic.
  String _canonicalJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      final pairs = keys.map(
        (k) => '${jsonEncode(k)}:${_canonicalJson(value[k])}',
      );
      return '{${pairs.join(',')}}';
    }
    if (value is List) {
      return '[${value.map(_canonicalJson).join(',')}]';
    }
    return jsonEncode(value);
  }
}
