import 'dart:convert';
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:logging/logging.dart';

class LoopDetectorResult {
  final bool isLoop;
  final String? message;
  LoopDetectorResult({required this.isLoop, this.message});
}

abstract class LoopDetector {
  Future<LoopDetectorResult> detect(ModelMessage chunkMessage);
}

class _ToolCallEntry {
  final String id;
  String signature;

  _ToolCallEntry(this.id, this.signature);
}

class DefaultLoopDetector implements LoopDetector {
  final Logger _logger = Logger('DefaultLoopDetector');
  final AgentState state;
  final LLMClient? client;
  final ModelConfig? modelConfig;

  // Configuration
  final int toolLoopThreshold;
  final int llmCheckAfterTurns;
  final int llmCheckHistorySize;
  final int llmCheckInterval;

  // Tool Loop State
  final List<_ToolCallEntry> _recentToolCalls = [];

  // LLM Loop State
  int _lastLLMCheckTurn = 0;

  DefaultLoopDetector({
    required this.state,
    this.client,
    this.modelConfig,
    this.toolLoopThreshold = 5,
    this.llmCheckAfterTurns = 30,
    this.llmCheckHistorySize = 20,
    this.llmCheckInterval = 10,
  }) {
    _initializeRecentToolCalls();
  }

  void _initializeRecentToolCalls() {
    // Extract recent tool calls from history to populate memory
    // Iterate in reverse to find last calls efficiently?
    // Or just iterate standard and keep last N.
    // Flatten all calls relative to message order.

    // We iterate all messages to rebuild state correctly (simplest logic)
    // or just take last few messages if we assume density.
    // Safer to scan from end.

    final calls = <_ToolCallEntry>[];

    for (final message in state.history.messages) {
      if (message is ModelMessage && message.functionCalls.isNotEmpty) {
        for (final call in message.functionCalls) {
          calls.add(_ToolCallEntry(call.id, _getSignature(call)));
        }
      }
    }

    // Keep only the necessary amount to detect loops
    // If we have 1000 calls, we only need the last 'toolLoopThreshold'
    // BUT to detect "5 consecutive same", we effectively just need the tail.
    // If we have [A, B, C, D, E], we check equality.
    // So keeping last toolLoopThreshold is sufficient.

    if (calls.length > toolLoopThreshold) {
      _recentToolCalls.addAll(calls.sublist(calls.length - toolLoopThreshold));
    } else {
      _recentToolCalls.addAll(calls);
    }
  }

  String _getSignature(FunctionCall call) => '${call.name}:${call.arguments}';

  @override
  Future<LoopDetectorResult> detect(ModelMessage chunkMessage) async {
    // 1. Tool Call Loop Detection (Optimized In-Memory)
    if (chunkMessage.functionCalls.isNotEmpty) {
      _updateToolCalls(chunkMessage.functionCalls);
      final toolLoop = _checkToolCallLoop();
      if (toolLoop.isLoop) return toolLoop;
    }

    // 2. LLM Smart Diagnosis (Periodic)
    if (client != null && modelConfig != null) {
      if (state.totalLoopCount > llmCheckAfterTurns &&
          (state.totalLoopCount - _lastLLMCheckTurn) >= llmCheckInterval) {
        _lastLLMCheckTurn = state.totalLoopCount;
        final llmLoop = await _checkForLoopWithLLM();
        if (llmLoop.isLoop) return llmLoop;
      }
    }

    return LoopDetectorResult(isLoop: false);
  }

  void _updateToolCalls(List<FunctionCall> calls) {
    for (final call in calls) {
      final signature = _getSignature(call);

      // Handle streaming updates: if ID matches last entry, update it.
      if (_recentToolCalls.isNotEmpty && _recentToolCalls.last.id == call.id) {
        _recentToolCalls.last.signature = signature;
      } else {
        _recentToolCalls.add(_ToolCallEntry(call.id, signature));
        // Maintain fixed size buffer
        if (_recentToolCalls.length > toolLoopThreshold) {
          _recentToolCalls.removeAt(0);
        }
      }
    }
  }

  LoopDetectorResult _checkToolCallLoop() {
    if (_recentToolCalls.length < toolLoopThreshold) {
      return LoopDetectorResult(isLoop: false);
    }

    final firstSig = _recentToolCalls.first.signature;
    for (var i = 1; i < _recentToolCalls.length; i++) {
      if (_recentToolCalls[i].signature != firstSig) {
        return LoopDetectorResult(isLoop: false);
      }
    }

    return LoopDetectorResult(
      isLoop: true,
      message:
          'Tool call loop detected: Same tool called $toolLoopThreshold times.',
    );
  }

  Future<LoopDetectorResult> _checkForLoopWithLLM() async {
    _logger.info('🧠 Triggering LLM Loop Diagnosis...');

    var history = state.history.messages.takeLast(llmCheckHistorySize).toList();

    // Sanitize history to prevent API errors
    // 1. Remove leading FunctionExecutionResultMessages (orphaned tool outputs)
    while (history.isNotEmpty &&
        history.first is FunctionExecutionResultMessage) {
      history.removeAt(0);
    }

    // 2. Ensure history starts with UserMessage (or System, but not Model)
    // If it starts with ModelMessage, the API will complain about strict alternation or unexpected start.
    if (history.isNotEmpty && history.first is ModelMessage) {
      history.insert(0, UserMessage.text("...previous context..."));
    }

    final prompt =
        """
You are an AI Loop Diagnosis Expert.
Analyze the following conversation history (last $llmCheckHistorySize messages).
Determine if the Agent is stuck in a meaningless loop or cognitive stagnation.
A loop is defined as:
1. Repeating the same wrong action despite errors.
2. Repeating the same question or text without progress.
3. Alternating between two states (flip-flop) without progress.

Return JSON format:
{
  "is_loop": true/false,
  "reason": "explanation",
  "confidence": 0.0-1.0
}
""";

    try {
      final messages = [
        SystemMessage(prompt),
        ...history,
        UserMessage.text("Diagnose the status now."),
      ];

      final response = await client!.generate(
        messages,
        modelConfig: modelConfig!,
      );

      final text = response.textOutput ?? '';
      final jsonMatch = RegExp(r'\{.*\}', dotAll: true).firstMatch(text);
      if (jsonMatch != null) {
        final jsonStr = jsonMatch.group(0)!;
        final data = json.decode(jsonStr);
        if (data['is_loop'] == true && (data['confidence'] ?? 0) > 0.8) {
          return LoopDetectorResult(
            isLoop: true,
            message: 'LLM Diagnosis detected loop: ${data['reason']}',
          );
        }
      }
    } catch (e) {
      _logger.warning('LLM Loop Diagnosis failed', e);
    }

    return LoopDetectorResult(isLoop: false);
  }
}

extension ListTakeLast<T> on List<T> {
  List<T> takeLast(int n) {
    if (length <= n) return this;
    return sublist(length - n);
  }
}
