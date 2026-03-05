enum MessageRole { system, user, assistant, tool }

abstract class LLMMessage {
  final MessageRole role;
  LLMMessage(this.role);

  Map<String, dynamic> toJson();

  static LLMMessage fromJson(Map<String, dynamic> json) {
    final roleStr = json['role'] as String;
    final role = MessageRole.values.firstWhere(
      (e) => e.toString().split('.').last == roleStr,
    );

    switch (role) {
      case MessageRole.system:
        return SystemMessage.fromJson(json);
      case MessageRole.user:
        return UserMessage.fromJson(json);
      case MessageRole.assistant:
        return ModelMessage.fromJson(json);
      case MessageRole.tool:
        return FunctionExecutionResultMessage.fromJson(json);
    }
  }
}

class SystemMessage extends LLMMessage {
  final String content;
  SystemMessage(this.content) : super(MessageRole.system);

  Map<String, dynamic> toJson() => {'role': 'system', 'content': content};

  factory SystemMessage.fromJson(Map<String, dynamic> json) {
    return SystemMessage(json['content'] as String);
  }
}

/// Base class for user content parts
abstract class UserContentPart {
  Map<String, dynamic> toJson();

  static UserContentPart fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    switch (type) {
      case 'text':
        return TextPart.fromJson(json);
      case 'image':
        return ImagePart.fromJson(json);
      case 'video':
        return VideoPart.fromJson(json);
      case 'audio':
        return AudioPart.fromJson(json);
      case 'document':
        return DocumentPart.fromJson(json);
      default:
        throw Exception('Unknown content part type: $type');
    }
  }
}

abstract class ModelContentPart {
  Map<String, dynamic> toJson();

  static ModelContentPart fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    switch (type) {
      case 'text':
        return ModelTextPart.fromJson(json);
      case 'image':
        return ModelImagePart.fromJson(json);
      case 'video':
        return ModelVideoPart.fromJson(json);
      default:
        throw Exception('Unknown content part type: $type');
    }
  }
}

class ModelTextPart extends ModelContentPart {
  final String text;
  ModelTextPart(this.text);

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};

  factory ModelTextPart.fromJson(Map<String, dynamic> json) {
    return ModelTextPart(json['text'] as String);
  }
}

class ModelImagePart extends ModelContentPart {
  final String base64Data;
  final String? mimeType;
  final Map<String, dynamic>? metadata;
  ModelImagePart(this.base64Data, {this.mimeType, this.metadata});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'base64Data': base64Data,
    if (mimeType != null) 'mimeType': mimeType,
    'metadata': metadata,
  };

  factory ModelImagePart.fromJson(Map<String, dynamic> json) {
    return ModelImagePart(
      json['base64Data'],
      mimeType: json['mimeType'] as String?,
      metadata: json['metadata'],
    );
  }
}

class ModelVideoPart extends ModelContentPart {
  final String base64Data;
  final String? mimeType;
  final Map<String, dynamic>? metadata;
  ModelVideoPart(this.base64Data, {this.mimeType, this.metadata});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'video',
    'base64Data': base64Data,
    if (mimeType != null) 'mimeType': mimeType,
    'metadata': metadata,
  };

  factory ModelVideoPart.fromJson(Map<String, dynamic> json) {
    return ModelVideoPart(
      json['base64Data'],
      mimeType: json['mimeType'] as String?,
      metadata: json['metadata'],
    );
  }
}

class ModelAudioPart extends ModelContentPart {
  final String? base64Data;
  final String? mimeType;
  final String? transcript;
  final Map<String, dynamic>? metadata;
  ModelAudioPart({
    this.base64Data,
    this.mimeType,
    this.metadata,
    this.transcript,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': 'audio',
    if (base64Data != null) 'base64Data': base64Data,
    if (mimeType != null) 'mimeType': mimeType,
    if (transcript != null) 'transcript': transcript,
    'metadata': metadata,
  };

  factory ModelAudioPart.fromJson(Map<String, dynamic> json) {
    return ModelAudioPart(
      base64Data: json['base64Data'] as String?,
      mimeType: json['mimeType'] as String?,
      transcript: json['transcript'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }
}

class TextPart extends UserContentPart {
  final String text;
  TextPart(this.text);

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};

  factory TextPart.fromJson(Map<String, dynamic> json) {
    return TextPart(json['text'] as String);
  }
}

class ImagePart extends UserContentPart {
  final String base64Data;
  final String mimeType;
  final String? detail;
  ImagePart(this.base64Data, this.mimeType, {this.detail});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'base64Data': base64Data,
    'mimeType': mimeType,
    if (detail != null) 'detail': detail,
  };

  factory ImagePart.fromJson(Map<String, dynamic> json) {
    return ImagePart(
      json['base64Data'],
      json['mimeType'] as String,
      detail: json['detail'],
    );
  }
}

class VideoPart extends UserContentPart {
  final String base64Data;
  final String mimeType;
  VideoPart(this.base64Data, this.mimeType);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'video',
    'base64Data': base64Data,
    'mimeType': mimeType,
  };

  factory VideoPart.fromJson(Map<String, dynamic> json) {
    return VideoPart(json['base64Data'], json['mimeType'] as String);
  }
}

class AudioPart extends UserContentPart {
  final String base64Data;
  final String mimeType;
  AudioPart(this.base64Data, this.mimeType);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'audio',
    'base64Data': base64Data,
    'mimeType': mimeType,
  };

  factory AudioPart.fromJson(Map<String, dynamic> json) {
    return AudioPart(json['base64Data'], json['mimeType'] as String);
  }
}

class DocumentPart extends UserContentPart {
  final String base64Data;
  final String mimeType;
  DocumentPart(this.base64Data, this.mimeType);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'document',
    'base64Data': base64Data,
    'mimeType': mimeType,
  };

  factory DocumentPart.fromJson(Map<String, dynamic> json) {
    return DocumentPart(json['base64Data'], json['mimeType'] as String);
  }
}

class UserMessage extends LLMMessage {
  final List<UserContentPart> contents;
  final int timestamp;
  final Map<String, dynamic>? metadata;

  UserMessage(this.contents, {int? timestamp, this.metadata})
    : timestamp = timestamp ?? DateTime.now().microsecondsSinceEpoch,
      super(MessageRole.user);

  /// Convenience constructor for single text content
  UserMessage.text(String text, {this.metadata})
    : contents = [TextPart(text)],
      timestamp = DateTime.now().microsecondsSinceEpoch,
      super(MessageRole.user);

  Map<String, dynamic> toJson() => {
    'role': 'user',
    'timestamp': timestamp,
    'contents': contents.map((e) => e.toJson()).toList(),
    if (metadata != null) 'metadata': metadata,
  };

  factory UserMessage.fromJson(Map<String, dynamic> json) {
    final contents = (json['contents'] as List)
        .map((e) => UserContentPart.fromJson(e as Map<String, dynamic>))
        .toList();
    return UserMessage(
      contents,
      timestamp: json['timestamp'],
      metadata: json['metadata'],
    );
  }
}

/// Represents a function call to be executed
class FunctionCall {
  final String id;
  final String name;
  final String arguments;

  FunctionCall({required this.id, required this.name, required this.arguments});

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
  };

  factory FunctionCall.fromJson(Map<String, dynamic> json) {
    return FunctionCall(
      id: json['id'] as String,
      name: json['name'] as String,
      arguments: json['arguments'] as String,
    );
  }
}

class ModelUsage {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int cachedToken;
  final int thoughtToken;
  final String? model;
  final dynamic originalUsage;
  final int timestamp;

  ModelUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
    this.model,
    this.originalUsage,
    this.cachedToken = 0,
    this.thoughtToken = 0,
    int? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().microsecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'totalTokens': totalTokens,
    'cachedToken': cachedToken,
    'thoughtToken': thoughtToken,
    'model': model,
    if (originalUsage != null) 'originalUsage': originalUsage,
    'timestamp': timestamp,
  };

  factory ModelUsage.fromJson(Map<String, dynamic> json) {
    return ModelUsage(
      promptTokens: json['promptTokens'] as int? ?? 0,
      completionTokens: json['completionTokens'] as int? ?? 0,
      totalTokens: json['totalTokens'] as int? ?? 0,
      model: json['model'],
      cachedToken: json['cachedToken'] as int? ?? 0,
      thoughtToken: json['thoughtToken'] as int? ?? 0,
      originalUsage: json['originalUsage'],
      timestamp: json['timestamp'] as int,
    );
  }
}

enum StreamingEventType {
  beforeCallModel,
  modelChunkMessage,
  modelRetrying,
  fullModelMessage,
  functionCallRequest,
  functionCallResult,
}

class StreamingEvent {
  final StreamingEventType eventType;
  final dynamic data;

  StreamingEvent({required this.eventType, required this.data});
}

class ModelMessage extends LLMMessage {
  final String? thought;
  final String? thoughtSignature; // Optional verification signature
  final List<FunctionCall> functionCalls;
  final String? textOutput;
  final List<ModelImagePart> imageOutputs;
  final List<ModelVideoPart> videoOutputs;
  final List<ModelAudioPart> audioOutputs;
  final ModelUsage? usage;
  final Map<String, dynamic>? metadata;
  final String? stopReason;
  final String model;
  final String? responseId;
  final int timestamp;

  ModelMessage({
    this.thought,
    this.thoughtSignature,
    this.functionCalls = const [],
    this.textOutput,
    this.imageOutputs = const [],
    this.videoOutputs = const [],
    this.audioOutputs = const [],
    this.usage,
    this.metadata,
    this.stopReason,
    required this.model,
    this.responseId,
    int? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().microsecondsSinceEpoch,
       super(MessageRole.assistant);

  Map<String, dynamic> toJson() => {
    'role': 'assistant',
    if (thought != null) 'thought': thought,
    if (thoughtSignature != null) 'thoughtSignature': thoughtSignature,
    if (textOutput != null) 'textOutput': textOutput,
    if (functionCalls.isNotEmpty)
      'functionCalls': functionCalls.map((e) => e.toJson()).toList(),
    if (imageOutputs.isNotEmpty)
      'imageOutputs': imageOutputs.map((e) => e.toJson()).toList(),
    if (videoOutputs.isNotEmpty)
      'videoOutputs': videoOutputs.map((e) => e.toJson()).toList(),
    if (audioOutputs.isNotEmpty)
      'audioOutputs': audioOutputs.map((e) => e.toJson()).toList(),
    if (usage != null) 'usage': usage!.toJson(),
    if (metadata != null) 'metadata': metadata,
    if (stopReason != null) 'stopReason': stopReason,
    'model': model,
    if (responseId != null) 'responseId': responseId,
    'timestamp': timestamp,
  };

  factory ModelMessage.fromJson(Map<String, dynamic> json) {
    return ModelMessage(
      thought: json['thought'] as String?,
      thoughtSignature: json['thoughtSignature'] as String?,
      textOutput: json['textOutput'] as String?,
      functionCalls:
          (json['functionCalls'] as List?)
              ?.map((e) => FunctionCall.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      imageOutputs:
          (json['imageOutputs'] as List?)
              ?.map((e) => ModelImagePart.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      videoOutputs:
          (json['videoOutputs'] as List?)
              ?.map((e) => ModelVideoPart.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      audioOutputs:
          (json['audioOutputs'] as List?)
              ?.map((e) => ModelAudioPart.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      usage: json['usage'] != null
          ? ModelUsage.fromJson(json['usage'] as Map<String, dynamic>)
          : null,
      metadata: json['metadata'] as Map<String, dynamic>?,
      stopReason: json['stopReason'] as String?,
      model: json['model'] as String,
      responseId: json['responseId'] as String?,
      timestamp: json['timestamp'] as int,
    );
  }
}

class FunctionExecutionResult {
  final String id; // Matches FunctionCall.id
  final String name;
  final bool isError;
  final String arguments;
  final List<UserContentPart> content; // Structured multimodal content
  final Map<String, dynamic>? metadata;
  final int timestamp;

  FunctionExecutionResult({
    required this.id,
    required this.name,
    required this.isError,
    required this.arguments,
    required this.content,
    this.metadata,
    int? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().microsecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'isError': isError,
    'arguments': arguments,
    'content': content.map((e) => e.toJson()).toList(),
    'metadata': metadata,
    'timestamp': timestamp,
  };

  factory FunctionExecutionResult.fromJson(Map<String, dynamic> json) {
    return FunctionExecutionResult(
      id: json['id'] as String,
      name: json['name'] as String,
      isError: json['isError'] as bool,
      arguments: json['arguments'] as String,
      content: (json['content'] as List)
          .map((e) => UserContentPart.fromJson(e as Map<String, dynamic>))
          .toList(),
      metadata: json['metadata'] as Map<String, dynamic>?,
      timestamp: json['timestamp'] as int,
    );
  }
}

class FunctionExecutionResultMessage extends LLMMessage {
  final List<FunctionExecutionResult> results;
  final int timestamp;

  FunctionExecutionResultMessage({required this.results, int? timestamp})
    : timestamp = timestamp ?? DateTime.now().microsecondsSinceEpoch,
      super(MessageRole.tool);

  Map<String, dynamic> toJson() => {
    'role': 'tool',
    'results': results.map((e) => e.toJson()).toList(),
    'timestamp': timestamp,
  };

  factory FunctionExecutionResultMessage.fromJson(Map<String, dynamic> json) {
    return FunctionExecutionResultMessage(
      results: (json['results'] as List)
          .map(
            (e) => FunctionExecutionResult.fromJson(e as Map<String, dynamic>),
          )
          .toList(),
      timestamp: json['timestamp'] as int,
    );
  }
}
