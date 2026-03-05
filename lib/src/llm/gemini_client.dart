import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import '../core/http_util.dart';
import '../core/llm_client.dart';
import '../core/message.dart';
import '../core/tool.dart';
import 'package:logging/logging.dart';

final Logger _geminiLogger = Logger('GeminiClient');

class GeminiClient extends LLMClient {
  final String apiKey;
  final Dio _client;
  final Duration timeout;
  final Duration connectTimeout;
  final String? proxyUrl;
  final int maxRetries;
  final int initialRetryDelayMs;
  final int maxRetryDelayMs;

  GeminiClient({
    required this.apiKey,
    Dio? client,
    this.timeout = const Duration(seconds: 300),
    this.connectTimeout = const Duration(seconds: 60),
    this.proxyUrl,
    this.maxRetries = 3,
    this.initialRetryDelayMs = 5000,
    this.maxRetryDelayMs = 3000,
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
    final requestBody = _createRequestBody(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
    );
    final model = modelConfig.model;
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey';
    int retryCount = 0;
    int currentDelayMs = initialRetryDelayMs;

    Future<void> waitForRetry(String reason) async {
      _geminiLogger.warning(
        'Gemini API: $reason. Retrying in ${currentDelayMs}ms... (Attempt ${retryCount + 1}/$maxRetries)',
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
        _geminiLogger.info(
          'Sending request to Gemini, timeout: ${timeout.inSeconds} seconds, proxy:${proxyUrl ?? 'none'} ,message length: ${messages.length}, tools: ${tools?.length}, model: $model',
        );
        final startTime = DateTime.now();
        final response = await _client.post(
          url,
          data: requestBody,
          options: Options(
            sendTimeout: timeout,
            receiveTimeout: timeout,
            headers: {'Content-Type': 'application/json'},
            validateStatus: (code) => true,
          ),
          cancelToken: cancelToken,
        );
        final endTime = DateTime.now();
        _geminiLogger.info(
          'Received response from Gemini, status code: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds} ms',
        );

        if (response.statusCode == 200) {
          // Check for retry conditions on 200 OK
          bool shouldRetry = false;
          String retryReason = '';
          final modelMessage = _parseResponse(response.data, modelConfig);
          if (modelMessage == null) {
            shouldRetry = true;
            retryReason = 'Gemini returned no candidates';
          } else {
            final stopReason = modelMessage.stopReason;
            if (stopReason == 'MALFORMED_FUNCTION_CALL' ||
                stopReason == 'OTHER') {
              shouldRetry = true;
              retryReason = 'Stop reason is $stopReason';
            } else {
              return modelMessage;
            }
          }
          if (shouldRetry) {
            if (retryCount < maxRetries) {
              await waitForRetry(retryReason);
              continue;
            } else {
              throw Exception(retryReason);
            }
          }
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
            'Failed to generate from Gemini: ${response.statusCode} ${response.statusMessage} ${response.data}',
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
    final model = modelConfig.model;
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/$model:streamGenerateContent?key=$apiKey';

    final body_json = _createRequestBody(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
    );

    StreamController<StreamingMessage> controller =
        StreamController<StreamingMessage>();
    int retryCount = 0;
    int currentDelayMs = initialRetryDelayMs;

    Future<void> waitForRetry(String reason) async {
      _geminiLogger.warning(
        'Gemini Stream API: $reason. Retrying in ${currentDelayMs}ms... (Attempt ${retryCount + 1}/$maxRetries)',
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
          _geminiLogger.info(
            'Sending streaming request to Gemini, timeout: ${timeout.inSeconds} seconds, proxy:${proxyUrl ?? 'none'} ,message length: ${messages.length}, tools: ${tools?.length}, model: $model',
          );
          final startTime = DateTime.now();

          final response = await _client.post(
            url,
            data: body_json,
            options: Options(
              responseType: ResponseType.stream,
              sendTimeout: timeout,
              receiveTimeout: timeout,
              headers: {'Content-Type': 'application/json'},
              validateStatus: (code) => true,
            ),
            cancelToken: cancelToken,
          );
          final endTime = DateTime.now();

          _geminiLogger.info(
            'Received streaming response from Gemini, status code: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds} ms',
          );

          if (response.statusCode != 200) {
            // Retry for 429 and 5xx errors
            if (response.statusCode != null &&
                (response.statusCode == 429 || response.statusCode! >= 500)) {
              if (retryCount < maxRetries) {
                await waitForRetry(
                  'Returned status code ${response.statusCode}',
                );
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
              'Failed to stream from Gemini: ${response.statusCode} ${response.statusMessage} $responseBody',
            );
          }

          final stream = (response.data.stream as Stream).cast<List<int>>();
          final transformedStream = stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .transform(GeminiChunkDecoder())
              .map((data) => _parseResponse(data, modelConfig));

          bool retryNeeded = false;
          String? stopReason;
          await for (final message in transformedStream) {
            if (message == null) continue;
            stopReason = message.stopReason;
            if (stopReason != null &&
                (stopReason == 'MALFORMED_FUNCTION_CALL' ||
                    stopReason == 'OTHER')) {
              // Trigger retry logic
              retryNeeded = true;
              break;
            }
            controller.add(StreamingMessage(modelMessage: message));
          }

          if (retryNeeded) {
            if (retryCount < maxRetries) {
              await waitForRetry('Stop reason:$stopReason unexcepted');
              controller.add(
                StreamingMessage(
                  controlMessage: StreamingControlMessage(
                    controlFlag: StreamingControlFlag.retry,
                    data: {'retryReason': 'Stop reason:$stopReason unexcepted'},
                  ),
                ),
              );
              continue;
            } else {
              _geminiLogger.warning(
                'Gemini Stream API returned stop reason:$stopReason, but max retries reached.',
              );
              // We stop here, the controller closes below
            }
          }

          // If implementation reaches here (and not retryNeeded), it means stream completed successfully
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
  bool? jsonOutput,
}) {
  final contents = messages.where((m) => m is! SystemMessage).map((m) {
    String role = 'user';
    if (m is ModelMessage)
      role = 'model';
    else if (m is FunctionExecutionResultMessage)
      role = 'function';

    List<Map<String, dynamic>> parts = [];

    if (m is UserMessage) {
      for (var part in m.contents) {
        if (part is TextPart) {
          parts.add({'text': part.text});
        } else if (part is ImagePart) {
          parts.add({
            'inlineData': {'mimeType': part.mimeType, 'data': part.base64Data},
          });
        } else if (part is AudioPart) {
          parts.add({
            'inlineData': {'mimeType': part.mimeType, 'data': part.base64Data},
          });
        } else if (part is VideoPart) {
          parts.add({
            'inlineData': {'mimeType': part.mimeType, 'data': part.base64Data},
          });
        } else if (part is DocumentPart) {
          parts.add({
            'inlineData': {'mimeType': part.mimeType, 'data': part.base64Data},
          });
        } else {
          throw Exception(
            'Unsupported content type for model ${modelConfig.model}: ${part.runtimeType}',
          );
        }
      }
    } else if (m is ModelMessage) {
      if (m.textOutput != null) parts.add({'text': m.textOutput});
      for (var fc in m.functionCalls) {
        parts.add({
          'functionCall': {'name': fc.name, 'args': jsonDecode(fc.arguments)},
        });
      }
      // Attach thoughtSignature if present
      if (m.thoughtSignature != null && parts.isNotEmpty) {
        // If function calls exist, attach to the first function call part
        final fcIndex = parts.indexWhere((p) => p.containsKey('functionCall'));
        if (fcIndex != -1) {
          parts[fcIndex]['thoughtSignature'] = m.thoughtSignature;
        } else {
          // Otherwise attach to the last part (e.g. text)
          parts.last['thoughtSignature'] = m.thoughtSignature;
        }
      }
    } else if (m is FunctionExecutionResultMessage) {
      for (var res in m.results) {
        final partsList = <Map<String, dynamic>>[];

        for (var part in res.content) {
          if (part is TextPart) {
            // Keep implementation simple for text
          } else if (part is ImagePart) {
            partsList.add({
              'inlineData': {
                'mimeType': part.mimeType,
                'data': part.base64Data,
              },
            });
          } else if (part is AudioPart) {
            partsList.add({
              'inlineData': {
                'mimeType': part.mimeType,
                'data': part.base64Data,
              },
            });
          } else if (part is VideoPart) {
            partsList.add({
              'inlineData': {
                'mimeType': part.mimeType,
                'data': part.base64Data,
              },
            });
          } else if (part is DocumentPart) {
            partsList.add({
              'inlineData': {
                'mimeType': part.mimeType,
                'data': part.base64Data,
              },
            });
          } else {
            throw Exception(
              'Unsupported content type for model ${modelConfig.model}: ${part.runtimeType}',
            );
          }
        }

        final textContent = res.content
            .whereType<TextPart>()
            .map((t) => t.text)
            .join('\n');

        parts.add({
          'functionResponse': {
            'name': res.id,
            'response': {'content': textContent},
            if (partsList.isNotEmpty) 'parts': partsList,
          },
        });
      }
    }

    return {'role': role, 'parts': parts};
  }).toList();

  final systemMessages = messages.whereType<SystemMessage>().toList();

  final generationConfig = <String, dynamic>{
    'temperature': modelConfig.temperature,
    'maxOutputTokens': modelConfig.maxTokens,
    'topP': modelConfig.topP,
    'topK': modelConfig.topK,
  };

  if (jsonOutput == true) {
    generationConfig['responseMimeType'] = 'application/json';
  }

  if (modelConfig.extra != null) {
    if (modelConfig.extra!["thinkingConfig"] != null) {
      generationConfig["thinkingConfig"] =
          modelConfig.extra!["thinkingConfig"]!;
    }
  }

  final body = {'contents': contents, 'generationConfig': generationConfig};

  if (systemMessages.isNotEmpty) {
    body['systemInstruction'] = {
      'parts': [
        {'text': systemMessages.map((m) => m.content).join('\n')},
      ],
    };
  }

  if (tools != null && tools.isNotEmpty) {
    body['tools'] = [
      {
        'functionDeclarations': tools
            .map(
              (t) => {
                'name': t.name,
                'description': t.description,
                'parameters': t.parameters,
              },
            )
            .toList(),
      },
    ];

    switch (toolChoice?.mode) {
      case ToolChoiceMode.none:
        body['toolConfig'] = {
          'functionCallingConfig': {'mode': 'NONE'},
        };
        break;
      case ToolChoiceMode.auto:
        body['toolConfig'] = {
          'functionCallingConfig': {'mode': 'AUTO'},
        };
        break;
      case ToolChoiceMode.required:
        final toolConfig = <String, dynamic>{'mode': 'ANY'};
        if (toolChoice?.allowedFunctionNames != null) {
          toolConfig['allowedFunctionNames'] = toolChoice!.allowedFunctionNames;
        }
        body['toolConfig'] = toolConfig;
        break;
      case null:
        // Do nothing
        break;
    }
  }
  return body;
}

ModelMessage? _parseResponse(
  Map<String, dynamic> data,
  ModelConfig modelConfig,
) {
  try {
    final candidates = data['candidates'] as List? ?? [];
    if (candidates.isEmpty) {
      _geminiLogger.warning('Gemini returned no candidates, data: $data');
      return null;
    }

    final candidate = candidates[0];
    final contentParts = candidate['content']['parts'] as List? ?? [];

    String? textOutput;
    List<FunctionCall> functionCalls = [];
    String? thoughtSignature;
    String? thought;

    for (var part in contentParts) {
      if (part.containsKey('thought') && part['thought'] == true) {
        thought = (thought ?? '') + (part['text'] ?? '');
      } else if (part.containsKey('text')) {
        textOutput = (textOutput ?? '') + part['text'];
      }

      if (part.containsKey('functionCall')) {
        final fc = part['functionCall'];
        functionCalls.add(
          FunctionCall(
            id: fc['name'],
            name: fc['name'],
            arguments: jsonEncode(fc['args'] ?? {}),
          ),
        );
      }
      if (part.containsKey('thoughtSignature')) {
        thoughtSignature = part['thoughtSignature'];
      }
    }

    // stream/non-stream thoughtSignature is often at the candidate level
    if (candidate.containsKey('thoughtSignature')) {
      thoughtSignature = candidate['thoughtSignature'];
    }

    ModelUsage? usage;
    if (data['usageMetadata'] != null) {
      final u = data['usageMetadata'];
      usage = ModelUsage(
        promptTokens: u['promptTokenCount'] ?? 0,
        completionTokens: u['candidatesTokenCount'] ?? 0,
        totalTokens: u['totalTokenCount'] ?? 0,
        cachedToken: u['cachedContentTokenCount'] ?? 0,
        thoughtToken: u['thoughtsTokenCount'] ?? 0,
        model: modelConfig.model,
        originalUsage: u,
      );
    }

    final metadata = {
      'modelVersion': data['modelVersion'],
      'responseId': data['responseId'],
    };
    if (data['promptFeedback'] != null) {
      metadata['promptFeedback'] = data['promptFeedback'];
    }

    return ModelMessage(
      textOutput: textOutput,
      functionCalls: functionCalls,
      usage: usage,
      metadata: metadata,
      stopReason: candidate['finishReason'],
      thoughtSignature: thoughtSignature,
      thought: thought,
      model: modelConfig.model,
    );
  } catch (e) {
    throw Exception('Unexpected response format from Gemini: $data');
  }
}

/// Decodes a stream of JSON lines (potentially multi-line) from Gemini into JSON objects.
class GeminiChunkDecoder
    extends StreamTransformerBase<String, Map<String, dynamic>> {
  @override
  Stream<Map<String, dynamic>> bind(Stream<String> stream) async* {
    final buffer = StringBuffer();
    int braceCount = 0;
    bool inObject = false;

    await for (final line in stream) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // Skip array brackets at the very top level if they appear alone
      if (!inObject && (trimmed == '[' || trimmed == ']')) continue;

      for (int i = 0; i < line.length; i++) {
        final char = line[i];
        if (char == '{') {
          if (braceCount == 0) inObject = true;
          braceCount++;
        }

        if (inObject) {
          buffer.write(char);
        }

        if (char == '}') {
          braceCount--;
          if (braceCount == 0 && inObject) {
            // End of object
            inObject = false;
            final jsonStr = buffer.toString();
            buffer.clear();

            try {
              final data = jsonDecode(jsonStr);
              if (data is Map<String, dynamic>) {
                yield data;
              }
            } catch (e) {
              _geminiLogger.warning(
                'Error decoding JSON chunk: $e\nChunk: $jsonStr',
              );
            }
          }
        }
      }
      // Handle newline if we are inside an object
      if (inObject) {
        buffer.write('\n');
      }
    }
  }
}
