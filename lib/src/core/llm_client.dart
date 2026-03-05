import 'message.dart';
import 'tool.dart'; // Keep for Tool definition in generate params
import 'package:dio/dio.dart';

abstract class LLMClient {
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  });
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  });
}

class StreamingMessage {
  final ModelMessage? modelMessage;
  final StreamingControlMessage? controlMessage;

  StreamingMessage({this.modelMessage, this.controlMessage});

  Map<String, dynamic> toJson() {
    return {
      'modelMessage': modelMessage?.toJson(),
      'controlMessage': controlMessage?.toJson(),
    };
  }

  factory StreamingMessage.fromJson(Map<String, dynamic> json) {
    return StreamingMessage(
      modelMessage: ModelMessage.fromJson(json['modelMessage']),
      controlMessage: StreamingControlMessage.fromJson(json['controlMessage']),
    );
  }
}

class StreamingControlMessage {
  final StreamingControlFlag controlFlag;
  final Map<String, dynamic>? data;

  StreamingControlMessage({required this.controlFlag, this.data});

  Map<String, dynamic> toJson() {
    return {
      'controlFlag': controlFlag.toString().split('.').last,
      'data': data,
    };
  }

  factory StreamingControlMessage.fromJson(Map<String, dynamic> json) {
    return StreamingControlMessage(
      controlFlag: StreamingControlFlag.values.firstWhere(
        (e) => e.toString().split('.').last == json['controlFlag'],
      ),
      data: json['data'],
    );
  }
}

enum StreamingControlFlag { retry }

enum ToolChoiceMode { none, auto, required }

class ToolChoice {
  final ToolChoiceMode mode;
  final List<String>? allowedFunctionNames;

  ToolChoice({required this.mode, this.allowedFunctionNames});

  Map<String, dynamic> toJson() => {
    'mode': mode.toString().split('.').last,
    if (allowedFunctionNames != null)
      'allowedFunctionNames': allowedFunctionNames,
  };

  factory ToolChoice.fromJson(Map<String, dynamic> json) {
    return ToolChoice(
      mode: ToolChoiceMode.values.firstWhere(
        (e) => e.toString().split('.').last == json['mode'],
      ),
      allowedFunctionNames: (json['allowedFunctionNames'] as List?)
          ?.cast<String>(),
    );
  }
}

class ModelConfig {
  final String model;
  final double? temperature;
  final int? maxTokens;
  final double? topP;
  final double? topK;
  final Map<String, dynamic>? extra;
  final Map<String, dynamic>? generationConfig;

  ModelConfig({
    required this.model,
    this.temperature,
    this.maxTokens,
    this.topP,
    this.topK,
    this.generationConfig,
    this.extra,
  });

  Map<String, dynamic> toJson() => {
    'model': model,
    if (temperature != null) 'temperature': temperature,
    if (maxTokens != null) 'maxTokens': maxTokens,
    if (topP != null) 'topP': topP,
    if (topK != null) 'topK': topK,
    if (generationConfig != null) 'generationConfig': generationConfig,
    if (extra != null) 'extra': extra,
  };

  factory ModelConfig.fromJson(Map<String, dynamic> json) {
    return ModelConfig(
      model: json['model'] as String,
      temperature: (json['temperature'] as num?)?.toDouble(),
      maxTokens: json['maxTokens'] as int?,
      topP: (json['topP'] as num?)?.toDouble(),
      topK: (json['topK'] as num?)?.toDouble(),
      generationConfig: json['generationConfig'] as Map<String, dynamic>?,
      extra: json['extra'] as Map<String, dynamic>?,
    );
  }
}
