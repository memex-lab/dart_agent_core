import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../core/http_util.dart';
import '../core/llm_client.dart';
import '../core/message.dart';
import '../core/tool.dart';

/// Client for the Anthropic Messages API (direct, not via AWS Bedrock).
///
/// Uses `x-api-key` header authentication and SSE for streaming.
///
/// ```dart
/// final client = ClaudeClient(
///   apiKey: Platform.environment['ANTHROPIC_API_KEY'] ?? '',
/// );
/// ```
class ClaudeClient extends LLMClient {
  final Logger _logger = Logger('ClaudeClient');
  final String apiKey;
  final String baseUrl;
  final String anthropicVersion;
  final Dio _client;
  final Duration timeout;
  final String? proxyUrl;

  final int maxRetries;
  final int initialRetryDelayMs;
  final int maxRetryDelayMs;

  ClaudeClient({
    required this.apiKey,
    this.baseUrl = 'https://api.anthropic.com',
    this.anthropicVersion = '2023-06-01',
    Dio? client,
    this.timeout = const Duration(seconds: 300),
    this.proxyUrl,
    this.maxRetries = 3,
    this.initialRetryDelayMs = 1000,
    this.maxRetryDelayMs = 10000,
  }) : _client = client ?? Dio() {
    configureProxy(_client, proxyUrl);
  }

  Map<String, String> get _headers => {
        'x-api-key': apiKey,
        'anthropic-version': anthropicVersion,
        'content-type': 'application/json',
      };

  Future<void> _waitForRetry(int retryCount, String reason) async {
    int delay = initialRetryDelayMs * (1 << retryCount);
    if (delay > maxRetryDelayMs) delay = maxRetryDelayMs;

    _logger.warning(
      'Claude API: $reason. Retrying in ${delay}ms... (Attempt ${retryCount + 1}/$maxRetries)',
    );
    await Future.delayed(Duration(milliseconds: delay));
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
    final body = _createRequestBody(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
    );

    final url = '$baseUrl/v1/messages';

    int retryCount = 0;
    while (true) {
      try {
        _logger.info(
          'Sending request to Claude API, timeout: ${timeout.inSeconds}s, proxy: ${proxyUrl ?? 'none'}, messages: ${messages.length}, tools: ${tools?.length}, model: ${modelConfig.model}',
        );
        final startTime = DateTime.now();
        final response = await _client.post(
          url,
          data: jsonEncode(body),
          options: Options(
            headers: _headers,
            responseType: ResponseType.json,
            sendTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (status) => true,
          ),
          cancelToken: cancelToken,
        );
        final endTime = DateTime.now();
        _logger.info(
          'Received response from Claude API, status: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds}ms',
        );

        if (response.statusCode == 200) {
          return _parseResponse(response.data, modelConfig);
        }

        if (response.statusCode == 429 ||
            (response.statusCode != null && response.statusCode! >= 500)) {
          if (retryCount < maxRetries) {
            await _waitForRetry(retryCount, 'Status ${response.statusCode}');
            retryCount++;
            continue;
          }
        }

        final errorMsg = response.data.toString();
        throw Exception(
          'Claude API Error: ${response.statusCode} $errorMsg',
        );
      } on DioException catch (e) {
        if (retryCount < maxRetries) {
          await _waitForRetry(retryCount, 'DioException: ${e.message}');
          retryCount++;
          continue;
        }
        final errorMsg = e.response?.data ?? e.message;
        _logger.severe('Claude API Error: $errorMsg', e, e.stackTrace);
        throw Exception('Claude API Error: $errorMsg');
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
    final body = _createRequestBody(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
    );
    body['stream'] = true;

    final url = '$baseUrl/v1/messages';

    int retryCount = 0;
    while (true) {
      try {
        _logger.info(
          'Sending streaming request to Claude API, timeout: ${timeout.inSeconds}s, proxy: ${proxyUrl ?? 'none'}, messages: ${messages.length}, tools: ${tools?.length}, model: ${modelConfig.model}',
        );
        final startTime = DateTime.now();
        final response = await _client.post(
          url,
          data: jsonEncode(body),
          options: Options(
            headers: _headers,
            responseType: ResponseType.stream,
            sendTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (status) => true,
          ),
          cancelToken: cancelToken,
        );
        final endTime = DateTime.now();
        _logger.info(
          'Received streaming response from Claude API, status: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds}ms',
        );

        if (response.statusCode == 200) {
          final stream = (response.data.stream as Stream).cast<List<int>>();
          final controller = StreamController<StreamingMessage>();
          final parser = _ClaudeStreamParser(modelConfig);

          _processSSEStream(stream, parser, controller);

          return controller.stream;
        }

        if (response.statusCode == 429 ||
            (response.statusCode != null && response.statusCode! >= 500)) {
          if (retryCount < maxRetries) {
            await _waitForRetry(retryCount, 'Status ${response.statusCode}');
            retryCount++;
            continue;
          }
        }

        final errorBody = await utf8.decodeStream(
          (response.data.stream as Stream).cast<List<int>>(),
        );
        throw Exception(
          'Claude Stream API Error: ${response.statusCode} $errorBody',
        );
      } catch (e) {
        if (e is DioException) {
          if (retryCount < maxRetries) {
            await _waitForRetry(retryCount, 'DioException: ${e.message}');
            retryCount++;
            continue;
          }
          final errorMsg = e.response?.data ?? e.message;
          _logger.severe('Claude Stream Error: $errorMsg', e, e.stackTrace);
          throw Exception('Claude Stream Error: $errorMsg');
        }
        rethrow;
      }
    }
  }

  void _processSSEStream(
    Stream<List<int>> stream,
    _ClaudeStreamParser parser,
    StreamController<StreamingMessage> controller,
  ) {
    final buffer = StringBuffer();

    stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.startsWith('data: ')) {
              final data = line.substring(6);
              if (data == '[DONE]') return;

              try {
                final json = jsonDecode(data) as Map<String, dynamic>;
                final message = parser.parse(json);
                if (message != null) {
                  controller.add(StreamingMessage(modelMessage: message));
                }
              } catch (e) {
                _logger.warning('Error parsing SSE chunk: $e, data: $data');
              }
            } else if (line.startsWith('event: ')) {
              // Event type hint — parser handles type from the data payload
            } else if (line.startsWith('error: ')) {
              buffer.clear();
              try {
                final errorData = jsonDecode(line.substring(7));
                controller.addError(
                  Exception('Claude Stream Error: ${errorData['message']}'),
                );
              } catch (_) {
                controller.addError(
                  Exception('Claude Stream Error: $line'),
                );
              }
            }
            // Empty lines are SSE event delimiters — ignored
          },
          onError: (e) {
            controller.addError(e);
          },
          onDone: () {
            controller.close();
          },
        );
  }

  Map<String, dynamic> _createRequestBody(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
  }) {
    final body = <String, dynamic>{
      'model': modelConfig.model,
      'max_tokens': modelConfig.maxTokens ?? 64000,
      'messages': messages
          .where((m) => m is! SystemMessage)
          .map((m) {
            if (m is UserMessage) {
              final content = m.contents
                  .map((c) {
                    if (c is TextPart) {
                      return {'type': 'text', 'text': c.text};
                    } else if (c is ImagePart) {
                      return {
                        'type': 'image',
                        'source': {
                          'type': 'base64',
                          'media_type': c.mimeType,
                          'data': c.base64Data,
                        },
                      };
                    } else if (c is DocumentPart) {
                      return {
                        'type': 'document',
                        'source': {
                          'type': 'base64',
                          'media_type': c.mimeType,
                          'data': c.base64Data,
                        },
                      };
                    }
                    return null;
                  })
                  .where((e) => e != null)
                  .toList();

              return {
                'role': 'user',
                'content': content.isNotEmpty ? content : '',
              };
            } else if (m is ModelMessage) {
              final content = <Map<String, dynamic>>[];

              if (m.thought != null &&
                  m.thought!.isNotEmpty &&
                  m.thoughtSignature != null) {
                content.add({
                  'type': 'thinking',
                  'thinking': m.thought,
                  'signature': m.thoughtSignature,
                });
              }

              if (m.textOutput != null) {
                content.add({'type': 'text', 'text': m.textOutput});
              }
              if (m.functionCalls.isNotEmpty) {
                final validCalls = <FunctionCall>[];
                for (final call in m.functionCalls) {
                  if (call.id.isNotEmpty) {
                    validCalls.add(call);
                  } else if (validCalls.isNotEmpty) {
                    final previous = validCalls.last;
                    validCalls[validCalls.length - 1] = FunctionCall(
                      id: previous.id,
                      name: previous.name,
                      arguments: previous.arguments + call.arguments,
                    );
                  }
                }

                for (final call in validCalls) {
                  dynamic input;
                  if (call.arguments.isEmpty) {
                    input = {};
                  } else {
                    try {
                      input = jsonDecode(call.arguments);
                    } catch (e) {
                      _logger.warning(
                        'Error decoding tool input: ${call.arguments} - $e',
                      );
                      input = {};
                    }
                  }
                  content.add({
                    'type': 'tool_use',
                    'id': call.id,
                    'name': call.name,
                    'input': input,
                  });
                }
              }
              return {
                'role': 'assistant',
                'content': content.isNotEmpty ? content : '',
              };
            } else if (m is FunctionExecutionResultMessage) {
              final content = m.results.map((r) {
                return {
                  'type': 'tool_result',
                  'tool_use_id': r.id,
                  'content': r.content
                      .map((p) {
                        if (p is TextPart) {
                          return {'type': 'text', 'text': p.text};
                        }
                        if (p is ImagePart) {
                          return {
                            'type': 'image',
                            'source': {
                              'type': 'base64',
                              'media_type': p.mimeType,
                              'data': p.base64Data,
                            },
                          };
                        }
                        return null;
                      })
                      .where((e) => e != null)
                      .toList(),
                };
              }).toList();

              return {'role': 'user', 'content': content};
            }
            return null;
          })
          .where((e) => e != null)
          .toList(),
    };

    final systemPrompt = messages
        .whereType<SystemMessage>()
        .map((m) => m.content)
        .join('\n');
    if (systemPrompt.isNotEmpty) {
      body['system'] = systemPrompt;
    }

    if (modelConfig.temperature != null) {
      body['temperature'] = modelConfig.temperature;
    }
    if (modelConfig.topP != null) body['top_p'] = modelConfig.topP;
    if (modelConfig.topK != null) body['top_k'] = modelConfig.topK!.toInt();

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools.map((t) {
        return {
          'name': t.name,
          'description': t.description,
          'input_schema': t.parameters,
        };
      }).toList();

      if (toolChoice != null) {
        if (toolChoice.mode == ToolChoiceMode.auto) {
          body['tool_choice'] = {'type': 'auto'};
        } else if (toolChoice.mode == ToolChoiceMode.required) {
          if (toolChoice.allowedFunctionNames != null &&
              toolChoice.allowedFunctionNames!.isNotEmpty) {
            body['tool_choice'] = {
              'type': 'tool',
              'name': toolChoice.allowedFunctionNames!.first,
            };
          } else {
            body['tool_choice'] = {'type': 'any'};
          }
        }
      }
    }

    if (modelConfig.extra != null) {
      if (modelConfig.extra!['thinking'] != null) {
        body['thinking'] = modelConfig.extra!['thinking'];
      }
      if (modelConfig.extra!['output_config'] != null) {
        body['output_config'] = modelConfig.extra!['output_config'];
      }
    }

    if (jsonOutput == true && body['output_config'] == null) {
      _logger.warning(
        'jsonOutput is true but no output_config provided. '
        'Claude typically requires a JSON schema for structured output. '
        'Pass output_config in modelConfig.extra.',
      );
    }

    return body;
  }

  ModelMessage _parseResponse(
    Map<String, dynamic> data,
    ModelConfig modelConfig,
  ) {
    if (data['type'] == 'error') {
      throw Exception('Claude Error: ${data['error']?['message']}');
    }

    final content = data['content'] as List?;
    String text = '';
    final functionCalls = <FunctionCall>[];
    String? thought;
    String? thoughtSignature;

    if (content != null) {
      for (final part in content) {
        if (part['type'] == 'text') {
          text += part['text'] ?? '';
        } else if (part['type'] == 'tool_use') {
          dynamic input = part['input'];
          if (input is Map) {
            input = jsonEncode(input);
          }
          input ??= '';

          functionCalls.add(
            FunctionCall(
              id: part['id'],
              name: part['name'],
              arguments: input.toString(),
            ),
          );
        } else if (part['type'] == 'thinking') {
          thought = part['thinking'];
          thoughtSignature = part['signature'];
        }
      }
    }

    return ModelMessage(
      textOutput: text,
      functionCalls: functionCalls,
      model: modelConfig.model,
      stopReason: data['stop_reason'],
      thought: thought,
      thoughtSignature: thoughtSignature,
      usage: data['usage'] != null
          ? ModelUsage(
              promptTokens: data['usage']['input_tokens'] ?? 0,
              completionTokens: data['usage']['output_tokens'] ?? 0,
              totalTokens: (data['usage']['input_tokens'] ?? 0) +
                  (data['usage']['output_tokens'] ?? 0),
              cachedToken:
                  (data['usage']['cache_read_input_tokens'] ?? 0) +
                  (data['usage']['cache_creation_input_tokens'] ?? 0),
              model: modelConfig.model,
            )
          : null,
    );
  }
}

class _ClaudeStreamParser {
  final ModelConfig modelConfig;
  String? _currentToolId;
  String? _currentToolName;
  final StringBuffer _currentToolJson = StringBuffer();

  int _promptTokens = 0;
  int _completionTokens = 0;
  int _cachedTokens = 0;
  int _thoughtTokens = 0;

  _ClaudeStreamParser(this.modelConfig);

  ModelMessage? parse(Map<String, dynamic> chunk) {
    final type = chunk['type'];

    if (type == 'content_block_start') {
      final start = chunk['content_block'];
      if (start['type'] == 'tool_use') {
        _currentToolId = start['id'];
        _currentToolName = start['name'];
        _currentToolJson.clear();
      } else if (start['type'] == 'thinking') {
        return ModelMessage(
          thought: '',
          model: modelConfig.model,
          usage: _currentUsage(),
        );
      }
    } else if (type == 'content_block_delta') {
      final delta = chunk['delta'];
      if (delta['type'] == 'text_delta') {
        return ModelMessage(
          textOutput: delta['text'],
          model: modelConfig.model,
          usage: _currentUsage(),
        );
      } else if (delta['type'] == 'thinking_delta') {
        return ModelMessage(
          thought: delta['thinking'],
          model: modelConfig.model,
          usage: _currentUsage(),
        );
      } else if (delta['type'] == 'signature_delta') {
        return ModelMessage(
          thoughtSignature: delta['signature'],
          model: modelConfig.model,
          usage: _currentUsage(),
        );
      } else if (delta['type'] == 'input_json_delta') {
        _currentToolJson.write(delta['partial_json']);
      }
    } else if (type == 'content_block_stop') {
      if (_currentToolId != null) {
        final toolCall = FunctionCall(
          id: _currentToolId!,
          name: _currentToolName!,
          arguments: _currentToolJson.toString(),
        );
        _currentToolId = null;
        _currentToolName = null;
        _currentToolJson.clear();
        return ModelMessage(
          functionCalls: [toolCall],
          model: modelConfig.model,
          usage: _currentUsage(),
        );
      }
    } else if (type == 'message_start') {
      final message = chunk['message'];
      if (message != null && message['usage'] != null) {
        final usage = message['usage'];
        _promptTokens = usage['input_tokens'] ?? 0;
        _cachedTokens =
            (usage['cache_read_input_tokens'] ?? 0) +
            (usage['cache_creation_input_tokens'] ?? 0);
        _completionTokens += (usage['output_tokens'] as int? ?? 0);
        return ModelMessage(usage: _currentUsage(), model: modelConfig.model);
      }
    } else if (type == 'message_delta') {
      final delta = chunk['delta'];
      String? stopReason;

      if (delta != null && delta['stop_reason'] != null) {
        stopReason = delta['stop_reason'];
      }

      if (chunk['usage'] != null) {
        final u = chunk['usage'];
        _completionTokens = (u['output_tokens'] as int? ?? 0);
        _thoughtTokens = u['output_tokens_details']?['reasoning_tokens'] ?? 0;
      }

      if (stopReason != null || chunk['usage'] != null) {
        return ModelMessage(
          stopReason: stopReason,
          usage: _currentUsage(),
          model: modelConfig.model,
        );
      }
    }

    return null;
  }

  ModelUsage _currentUsage() {
    return ModelUsage(
      promptTokens: _promptTokens,
      completionTokens: _completionTokens,
      totalTokens: _promptTokens + _completionTokens,
      cachedToken: _cachedTokens,
      thoughtToken: _thoughtTokens,
      model: modelConfig.model,
    );
  }
}
