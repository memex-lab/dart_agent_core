import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import '../core/http_util.dart';
import '../core/llm_client.dart';
import '../core/message.dart';
import '../core/tool.dart';
import 'package:logging/logging.dart';

class OpenAIClient extends LLMClient {
  final Logger _logger = Logger('OpenAIClient');
  final String apiKey;
  final String baseUrl;
  final Dio _client;
  final Duration timeout;
  final Duration connectTimeout;
  final String? proxyUrl;
  final int maxRetries;
  final int initialRetryDelayMs;
  final int maxRetryDelayMs;

  OpenAIClient({
    required this.apiKey,
    this.baseUrl = 'https://api.openai.com',
    this.timeout = const Duration(seconds: 300),
    this.connectTimeout = const Duration(seconds: 60),
    this.proxyUrl,
    this.maxRetries = 3,
    this.initialRetryDelayMs =
        1000, // OpenAI might be faster/slower, defaulting to 1s start
    this.maxRetryDelayMs = 10000,
    Dio? client,
  }) : _client = client ?? Dio() {
    configureProxy(_client, proxyUrl);
    _client.options.connectTimeout = connectTimeout;
  }

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    final url = '$baseUrl/chat/completions';
    final body = _createRequestBody(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
    );

    int retryCount = 0;
    int currentDelayMs = initialRetryDelayMs;

    Future<void> waitForRetry(String reason) async {
      _logger.warning(
        'OpenAI API: $reason. Retrying in ${currentDelayMs}ms... (Attempt ${retryCount + 1}/$maxRetries)',
      );
      await Future.delayed(Duration(milliseconds: currentDelayMs));
      retryCount++;
      currentDelayMs = (currentDelayMs * 2);
      if (currentDelayMs > maxRetryDelayMs) {
        currentDelayMs = maxRetryDelayMs;
      }
    }

    while (true) {
      try {
        _logger.info(
          'Sending request to OpenAI (Attempt ${retryCount + 1}), timeout: ${timeout.inSeconds} seconds, proxy:${proxyUrl ?? 'none'} , message length: ${messages.length}, tools: ${tools?.length}, model: ${modelConfig.model}',
        );
        final startTime = DateTime.now();
        final response = await _client.post(
          url,
          data: body,
          options: Options(
            sendTimeout: timeout,
            receiveTimeout: timeout,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            validateStatus: (code) => true,
          ),
          cancelToken: cancelToken,
        );
        final endTime = DateTime.now();
        _logger.info(
          'Received response from OpenAI, status code: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds} ms',
        );
        if (response.statusCode == 200) {
          // Dio automatically decodes JSON if Content-Type is application/json
          final data = response.data is String
              ? jsonDecode(response.data)
              : response.data;
          return _parseResponse(data, modelConfig);
        } else {
          // Retry for 429 and 5xx errors
          if (response.statusCode != null &&
              (response.statusCode == 429 || response.statusCode! >= 500)) {
            if (retryCount < maxRetries) {
              await waitForRetry('Returned status code ${response.statusCode}');
              continue;
            }
          }
          throw Exception(
            'Failed to generate from OpenAI: ${response.statusCode} ${response.statusMessage} ${response.data}',
          );
        }
      } on DioException catch (e) {
        if (retryCount < maxRetries) {
          await waitForRetry('DioException: ${e.message}');
          continue;
        }
        rethrow;
      }
    }
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    final url = '$baseUrl/chat/completions';
    final body = _createRequestBody(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      stream: true,
      jsonOutput: jsonOutput,
    );

    StreamController<StreamingMessage> controller =
        StreamController<StreamingMessage>();
    int retryCount = 0;
    int currentDelayMs = initialRetryDelayMs;

    Future<void> waitForRetry(String reason) async {
      _logger.warning(
        'OpenAI Stream API: $reason. Retrying in ${currentDelayMs}ms... (Attempt ${retryCount + 1}/$maxRetries)',
      );
      await Future.delayed(Duration(milliseconds: currentDelayMs));
      retryCount++;
      currentDelayMs = (currentDelayMs * 2);
      if (currentDelayMs > maxRetryDelayMs) {
        currentDelayMs = maxRetryDelayMs;
      }
    }

    void pumpStream() async {
      while (true) {
        try {
          _logger.info(
            'Sendings streaming request to OpenAI, timeout: ${timeout.inSeconds} seconds, message length: ${messages.length}, tools: ${tools?.length}, model: ${modelConfig.model}',
          );
          final startTime = DateTime.now();

          final response = await _client.post(
            url,
            data: body,
            options: Options(
              responseType: ResponseType.stream,
              sendTimeout: timeout,
              receiveTimeout: timeout,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $apiKey',
              },
              validateStatus: (code) => true,
            ),
            cancelToken: cancelToken,
          );
          final endTime = DateTime.now();

          _logger.info(
            'Received streaming response from OpenAI, status code: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds} ms',
          );

          if (response.statusCode != 200) {
            // Retry for 429 and 5xx errors
            if (response.statusCode != null &&
                (response.statusCode == 429 || response.statusCode! >= 500)) {
              if (retryCount < maxRetries) {
                await waitForRetry(
                  'Returned status code ${response.statusCode}',
                );
                // Notify retry
                controller.add(
                  StreamingMessage(
                    controlMessage: StreamingControlMessage(
                      controlFlag: StreamingControlFlag.retry,
                      data: {
                        'retryReason':
                            'Returned status code ${response.statusCode}',
                      },
                    ),
                  ),
                );
                continue;
              }
            }

            final responseBody = await utf8.decodeStream(
              (response.data.stream as Stream).cast<List<int>>(),
            );
            throw Exception(
              'Failed to stream from OpenAI: ${response.statusCode} ${response.statusMessage} $responseBody',
            );
          }

          final stream = (response.data.stream as Stream).cast<List<int>>();

          final transformedStream = stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .transform(OpenAIChunkDecoder())
              .transform(OpenAIResponseTransformer(modelConfig))
              .map((chunk) => StreamingMessage(modelMessage: chunk));

          await for (final message in transformedStream) {
            controller.add(message);
          }

          controller.close();
          break;
        } on DioException catch (e) {
          if (retryCount < maxRetries) {
            await waitForRetry('DioException: ${e.message}');
            controller.add(
              StreamingMessage(
                controlMessage: StreamingControlMessage(
                  controlFlag: StreamingControlFlag.retry,
                  data: {'retryReason': 'DioException: ${e.message}'},
                ),
              ),
            );
            continue;
          }
          controller.addError(e);
          controller.close();
          break;
        } on SocketException catch (e) {
          if (retryCount < maxRetries) {
            await waitForRetry('SocketException: ${e.message}');
            controller.add(
              StreamingMessage(
                controlMessage: StreamingControlMessage(
                  controlFlag: StreamingControlFlag.retry,
                  data: {'retryReason': 'SocketException: ${e.message}'},
                ),
              ),
            );
            continue;
          }
          controller.addError(e);
          controller.close();
          break;
        } on HttpException catch (e) {
          if (retryCount < maxRetries) {
            await waitForRetry('HttpException: ${e.message}');
            controller.add(
              StreamingMessage(
                controlMessage: StreamingControlMessage(
                  controlFlag: StreamingControlFlag.retry,
                  data: {'retryReason': 'HttpException: ${e.message}'},
                ),
              ),
            );
            continue;
          }
          controller.addError(e);
          controller.close();
          break;
        } catch (e) {
          controller.addError(e);
          controller.close();
          break;
        }
      }
    }

    pumpStream();
    return controller.stream;
  }
}

Map<String, dynamic> _createRequestBody(
  List<LLMMessage> messages, {
  List<Tool>? tools,
  ToolChoice? toolChoice,
  required ModelConfig modelConfig,
  bool stream = false,
  bool? jsonOutput,
}) {
  // ... existing implementation ...
  final List<Map<String, dynamic>> finalMessages = [];
  for (final m in messages) {
    // ... existing loop ...
    if (m is SystemMessage) {
      finalMessages.add({'role': 'system', 'content': m.content});
    } else if (m is UserMessage) {
      final content = m.contents
          .map((part) {
            if (part is TextPart) {
              return {'type': 'text', 'text': part.text};
            } else if (part is ImagePart) {
              return {
                'type': 'image_url',
                'image_url': {
                  'url': _convertBase64ToUrl(part.base64Data, part.mimeType),
                  if (part.detail != null) 'detail': part.detail,
                },
              };
            } else if (part is AudioPart) {
              String format = 'wav';
              if (part.mimeType.toLowerCase().contains('mp3') ||
                  part.mimeType.toLowerCase().contains('mpeg')) {
                format = 'mp3';
              }
              return {
                'type': 'input_audio',
                'input_audio': {'data': part.base64Data, 'format': format},
              };
            } else if (part is DocumentPart) {
              // Assuming source is base64 encoded data for file_data
              return {
                'type': 'file',
                'file': {'file_data': part.base64Data},
              };
            } else {
              throw Exception(
                'Unsupported content type for model ${modelConfig.model}: ${part.runtimeType}',
              );
            }
          })
          .whereType<Map<String, dynamic>>()
          .toList();

      if (content.length == 1 && content.first['type'] == 'text') {
        finalMessages.add({'role': 'user', 'content': content.first['text']});
      } else {
        finalMessages.add({'role': 'user', 'content': content});
      }
    } else if (m is ModelMessage) {
      final msg = <String, dynamic>{'role': 'assistant'};
      if (m.textOutput != null) msg['content'] = m.textOutput;
      if (m.thought != null && m.thought!.isNotEmpty) {
        msg['reasoning_content'] = m.thought;
      }
      if (m.functionCalls.isNotEmpty) {
        msg['tool_calls'] = m.functionCalls
            .map(
              (fc) => {
                'id': fc.id,
                'type': 'function',
                'function': {'name': fc.name, 'arguments': fc.arguments},
              },
            )
            .toList();
      }
      finalMessages.add(msg);
    } else if (m is FunctionExecutionResultMessage) {
      for (final res in m.results) {
        final List<String> textParts = [];
        for (final part in res.content) {
          if (part is TextPart) {
            textParts.add(part.text);
          } else {
            throw Exception(
              'Unsupported tool call result content type for model ${modelConfig.model}: ${part.runtimeType}',
            );
          }
        }
        final textContent = textParts.join('\n');
        finalMessages.add({
          'role': 'tool',
          'tool_call_id': res.id,
          'content': textContent,
        });
      }
    }
  }

  final body = {
    'model': modelConfig.model,
    'messages': finalMessages,
    'stream': stream,
  };

  if (modelConfig.temperature != null) {
    body['temperature'] = modelConfig.temperature!;
  }
  if (modelConfig.maxTokens != null) {
    body['max_completion_tokens'] = modelConfig.maxTokens!;
  }
  if (modelConfig.topP != null) {
    body['top_p'] = modelConfig.topP!;
  }
  if (jsonOutput == true) {
    body['response_format'] = {'type': 'json_object'};
  }

  if (stream) {
    body["stream_options"] = {"include_usage": true};
  }

  if (tools != null && tools.isNotEmpty) {
    body['tools'] = tools
        .map(
          (t) => {
            'type': 'function',
            'function': {
              'name': t.name,
              'description': t.description,
              'parameters': t.parameters,
            },
          },
        )
        .toList();

    switch (toolChoice?.mode) {
      case ToolChoiceMode.none:
        body['tool_choice'] = 'none';
        break;
      case ToolChoiceMode.auto:
        body['tool_choice'] = 'auto';
        break;
      case ToolChoiceMode.required:
        if (toolChoice?.allowedFunctionNames != null &&
            toolChoice!.allowedFunctionNames!.isNotEmpty) {
          body['tool_choice'] = {
            'type': 'function',
            'function': {'name': toolChoice.allowedFunctionNames![0]},
          };
        } else {
          body['tool_choice'] = 'required';
        }
        break;
      case null:
        // Do nothing
        break;
    }
  }

  if (modelConfig.extra != null) {
    if (modelConfig.extra!.containsKey("reasoning_effort")) {
      body['reasoning_effort'] = modelConfig.extra!["reasoning_effort"];
    }
    if (modelConfig.extra!.containsKey("modalities")) {
      body['modalities'] = modelConfig.extra!["modalities"];
    }
    if (modelConfig.extra!.containsKey("audio")) {
      body['audio'] = modelConfig.extra!["audio"];
    }
  }

  return body;
}

ModelMessage _parseResponse(
  Map<String, dynamic> data,
  ModelConfig modelConfig,
) {
  try {
    final choices = data['choices'] as List? ?? [];
    if (choices.isEmpty)
      return ModelMessage(textOutput: '', model: modelConfig.model);

    final choice = choices[0];
    final message = choice['message'];
    final content = message['content'];
    final reasoningContent = message['reasoning_content'] as String?;
    final audio = message['audio'];
    final toolCalls = message['tool_calls'] as List? ?? [];
    final finishReason = choice['finish_reason'];

    List<FunctionCall> functionCalls = [];
    for (var tc in toolCalls) {
      if (tc['type'] == 'function') {
        final fn = tc['function'];
        functionCalls.add(
          FunctionCall(
            id: tc['id'],
            name: fn['name'],
            arguments: fn['arguments'],
          ),
        );
      }
    }

    ModelUsage? usage;
    if (data['usage'] != null) {
      final u = data['usage'];
      usage = ModelUsage(
        promptTokens: u['prompt_tokens'] ?? 0,
        completionTokens: u['completion_tokens'] ?? 0,
        totalTokens: u['total_tokens'] ?? 0,
        cachedToken: u['prompt_tokens_details']?['cached_tokens'] ?? 0,
        thoughtToken: u['completion_tokens_details']?['reasoning_tokens'] ?? 0,
        originalUsage: u,
        model: modelConfig.model,
      );
    }

    List<ModelAudioPart> audioOutputs = [];
    if (audio != null) {
      audioOutputs.add(
        ModelAudioPart(
          base64Data: audio["data"],
          transcript: audio["transcript"],
          metadata: {"expires_at": audio["expires_at"], "id": audio["id"]},
        ),
      );
    }

    final metadata = {
      'model': data["model"],
      'object': data["object"],
      'created': data["created"],
      'usage': data["usage"],
      'prompt_filter_results': data["prompt_filter_results"],
      'system_fingerprint': data["system_fingerprint"],
    };

    return ModelMessage(
      thought: reasoningContent,
      textOutput: content,
      audioOutputs: audioOutputs,
      functionCalls: functionCalls,
      usage: usage,
      metadata: metadata,
      stopReason: finishReason,
      model: modelConfig.model,
    );
  } catch (e) {
    throw Exception('Unexpected response format from OpenAI: $data');
  }
}

String _convertBase64ToUrl(String base64Data, String mimeType) {
  if (base64Data.startsWith("data")) {
    return base64Data;
  }
  return 'data:$mimeType;base64,$base64Data';
}

class OpenAIChunkDecoder
    extends StreamTransformerBase<String, Map<String, dynamic>> {
  @override
  Stream<Map<String, dynamic>> bind(Stream<String> stream) async* {
    await for (final line in stream) {
      if (line.startsWith('data: ')) {
        final data = line.substring(6).trim();
        if (data == '[DONE]') return;
        try {
          yield jsonDecode(data);
        } catch (e) {
          // ignore
        }
      }
    }
  }
}

class OpenAIResponseTransformer
    extends StreamTransformerBase<Map<String, dynamic>, ModelMessage> {
  final ModelConfig modelConfig;

  OpenAIResponseTransformer(this.modelConfig);

  @override
  Stream<ModelMessage> bind(Stream<Map<String, dynamic>> stream) async* {
    final Map<int, Map<String, dynamic>> toolCallBuffer = {};
    String? pendingFinishReason;

    List<FunctionCall> finalizeToolCalls() {
      List<FunctionCall> finalFunctionCalls = [];
      if (toolCallBuffer.isNotEmpty) {
        final sortedIndices = toolCallBuffer.keys.toList()..sort();
        for (final index in sortedIndices) {
          final b = toolCallBuffer[index]!;
          try {
            if ((b['name'] as String).isNotEmpty ||
                (b['arguments'] as String).isNotEmpty ||
                (b['id'] as String).isNotEmpty) {
              var arguments = b['arguments'] as String;
              if (arguments.isEmpty) {
                arguments = '{}';
              }
              finalFunctionCalls.add(
                FunctionCall(
                  id: b['id'],
                  name: b['name'],
                  arguments: arguments,
                ),
              );
            }
          } catch (e) {
            // Ignore invalid JSON
          }
        }
        toolCallBuffer.clear();
      }
      return finalFunctionCalls;
    }

    await for (final data in stream) {
      final metadata = {
        'model': data["model"],
        'object': data["object"],
        'created': data["created"],
        'usage': data["usage"],
        'prompt_filter_results': data["prompt_filter_results"],
        'system_fingerprint': data["system_fingerprint"],
      };

      // 0. Handle Usage (often in last chunk with empty choices)
      if (data['usage'] != null) {
        final u = data['usage'];
        final modelUsage = ModelUsage(
          promptTokens: u['prompt_tokens'] ?? 0,
          completionTokens: u['completion_tokens'] ?? 0,
          totalTokens: u['total_tokens'] ?? 0,
          cachedToken: u['prompt_tokens_details']?['cached_tokens'] ?? 0,
          thoughtToken:
              u['completion_tokens_details']?['reasoning_tokens'] ?? 0,
          originalUsage: u,
          model: modelConfig.model,
        );

        // Some providers (e.g. GLM) send finish_reason and usage in the same
        // chunk. Extract finish_reason from choices if present so it is not lost.
        final usageChoices = data['choices'] as List? ?? [];
        if (usageChoices.isNotEmpty) {
          final usageChoice = usageChoices[0];
          final inlineFinishReason = usageChoice['finish_reason'];
          if (inlineFinishReason != null) {
            pendingFinishReason = inlineFinishReason;
          }
          // Also accumulate any tool_calls in this chunk
          final usageDelta = usageChoice['delta'];
          if (usageDelta != null && usageDelta['tool_calls'] != null) {
            final toolCalls = usageDelta['tool_calls'] as List;
            for (final tc in toolCalls) {
              final index = tc['index'] as int;
              if (!toolCallBuffer.containsKey(index)) {
                toolCallBuffer[index] = {'id': '', 'name': '', 'arguments': ''};
              }
              final buffer = toolCallBuffer[index]!;
              if (tc['id'] != null) buffer['id'] = tc['id'];
              final fn = tc['function'];
              if (fn != null) {
                if (fn['name'] != null) {
                  buffer['name'] = (buffer['name'] as String) + fn['name'];
                }
                if (fn['arguments'] != null) {
                  buffer['arguments'] =
                      (buffer['arguments'] as String) + fn['arguments'];
                }
              }
            }
          }
        }

        // If we have a pending finish reason, yield it now combined with usage
        if (pendingFinishReason != null) {
          yield ModelMessage(
            stopReason: pendingFinishReason,
            functionCalls: finalizeToolCalls(),
            usage: modelUsage,
            metadata: metadata,
            model: modelConfig.model,
          );
          pendingFinishReason = null;
        } else {
          // Just yield usage/metadata if no pending stop (or already yielded)
          yield ModelMessage(
            usage: modelUsage,
            metadata: metadata,
            model: modelConfig.model,
          );
        }
        continue;
      }

      final choices = data['choices'] as List? ?? [];
      if (choices.isEmpty) continue;

      final choice = choices[0];
      final delta = choice['delta'];
      final finishReason = choice['finish_reason'];

      // 1. Handle Text Content
      if (delta['content'] != null) {
        yield ModelMessage(
          textOutput: delta['content'],
          metadata: metadata,
          model: modelConfig.model,
        );
      }

      // 1.5. Handle Reasoning Content (e.g. Kimi thinking models)
      if (delta['reasoning_content'] != null) {
        yield ModelMessage(
          thought: delta['reasoning_content'],
          metadata: metadata,
          model: modelConfig.model,
        );
      }

      // 2. Handle Audio Content
      if (delta['audio'] != null) {
        final audio = delta['audio'];
        final audioContent = audio['data'] as String?;
        final audioTranscript = audio['transcript'] as String?;
        yield ModelMessage(
          audioOutputs: [
            ModelAudioPart(
              base64Data: audioContent,
              transcript: audioTranscript,
            ),
          ],
          metadata: metadata,
          model: modelConfig.model,
        );
      }

      // 3. Accumulate Tool Calls
      if (delta['tool_calls'] != null) {
        final toolCalls = delta['tool_calls'] as List;
        for (final tc in toolCalls) {
          final index = tc['index'] as int;

          if (!toolCallBuffer.containsKey(index)) {
            // Initialize buffer for this index
            toolCallBuffer[index] = {'id': '', 'name': '', 'arguments': ''};
          }

          final buffer = toolCallBuffer[index]!;
          if (tc['id'] != null) {
            buffer['id'] = tc['id'];
          }

          final fn = tc['function'];
          if (fn != null) {
            if (fn['name'] != null) {
              buffer['name'] = (buffer['name'] as String) + fn['name'];
            }
            if (fn['arguments'] != null) {
              buffer['arguments'] =
                  (buffer['arguments'] as String) + fn['arguments'];
            }
          }
        }
      }

      // 3. Handle Finish Reason
      if (finishReason != null) {
        // Buffer the finish reason and wait for potential usage chunk
        pendingFinishReason = finishReason;
      }
    }

    // Stream ended. If we still have a pending finish reason (meaning no usage chunk arrived),
    // yield it now.
    if (pendingFinishReason != null) {
      yield ModelMessage(
        stopReason: pendingFinishReason,
        functionCalls: finalizeToolCalls(),
        model: modelConfig.model,
      );
    }
  }
}
