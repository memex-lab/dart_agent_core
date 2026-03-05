import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../core/http_util.dart';
import '../core/llm_client.dart';
import '../core/message.dart';
import '../core/tool.dart';

class BedrockClaudeClient extends LLMClient {
  final Logger _logger = Logger('BedrockClaudeClient');
  final String region;
  final String accessKeyId;
  final String secretAccessKey;
  final String? sessionToken;
  final String? service;
  final Dio _client;
  final Duration timeout;
  final String? proxyUrl;

  final int maxRetries;
  final int initialRetryDelayMs;
  final int maxRetryDelayMs;

  late final AWSSigV4Signer _signer;

  BedrockClaudeClient({
    required this.region,
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken,
    this.service = 'bedrock',
    Dio? client,
    this.timeout = const Duration(seconds: 300),
    this.proxyUrl,
    this.maxRetries = 3,
    this.initialRetryDelayMs = 1000,
    this.maxRetryDelayMs = 10000,
  }) : _client = client ?? Dio() {
    configureProxy(_client, proxyUrl);
    _signer = AWSSigV4Signer(
      credentialsProvider: AWSCredentialsProvider(
        AWSCredentials(accessKeyId, secretAccessKey, sessionToken),
      ),
    );
  }

  Future<void> _waitForRetry(int retryCount, String reason) async {
    int delay = initialRetryDelayMs * (1 << retryCount);
    if (delay > maxRetryDelayMs) delay = maxRetryDelayMs;

    _logger.warning(
      'Bedrock API: $reason. Retrying in ${delay}ms... (Attempt ${retryCount + 1}/$maxRetries)',
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
    final bodyMap = _createRequestBody(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
    );
    final bodyBytes = utf8.encode(jsonEncode(bodyMap));

    // Ensure model ID is properly encoded if it contains special characters like ':'
    final modelId = Uri.encodeComponent(modelConfig.model);
    final url = Uri.parse(
      'https://bedrock-runtime.$region.amazonaws.com/model/$modelId/invoke',
    );

    final request = AWSHttpRequest.post(
      url,
      body: bodyBytes,
      headers: {
        'content-type': 'application/json',
        'accept': 'application/json',
      },
    );

    final signedRequest = await _signer.sign(
      request,
      credentialScope: AWSCredentialScope(
        region: region,
        service: const AWSService('bedrock'),
      ),
    );

    int retryCount = 0;
    while (true) {
      try {
        _logger.info(
          'Sending request to Bedrock, timeout: ${timeout.inSeconds} seconds, proxy:${proxyUrl ?? 'none'} ,message length: ${messages.length}, tools: ${tools?.length}, model: ${modelConfig.model}',
        );
        final startTime = DateTime.now();
        final response = await _client.postUri(
          url,
          data: Stream.fromIterable([bodyBytes]),
          options: Options(
            headers: signedRequest.headers,
            responseType: ResponseType.json,
            sendTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (status) => true, // Handle status codes manually
          ),
          cancelToken: cancelToken,
        );
        final endTime = DateTime.now();
        _logger.info(
          'Received response from Bedrock, status code: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds} ms',
        );

        if (response.statusCode == 200) {
          return _parseResponse(response.data, modelConfig);
        }

        // Retry on 429 (Too Many Requests) or 5xx (Server Errors)
        if (response.statusCode == 429 ||
            (response.statusCode != null && response.statusCode! >= 500)) {
          if (retryCount < maxRetries) {
            await _waitForRetry(retryCount, 'Status ${response.statusCode}');
            retryCount++;
            continue;
          }
        }

        // Throw for other errors or if max retries reached
        final errorMsg = response.data.toString();
        throw Exception('Bedrock API Error: ${response.statusCode} $errorMsg');
      } on DioException catch (e) {
        if (retryCount < maxRetries) {
          // Retry on network errors or timeouts
          await _waitForRetry(retryCount, 'DioException: ${e.message}');
          retryCount++;
          continue;
        }
        final errorMsg = e.response?.data ?? e.message;
        _logger.severe('Bedrock API Error: $errorMsg', e, e.stackTrace);
        throw Exception('Bedrock API Error: $errorMsg');
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
    final bodyMap = _createRequestBody(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
    );
    final bodyBytes = utf8.encode(jsonEncode(bodyMap));

    final modelId = Uri.encodeComponent(modelConfig.model);
    final url = Uri.parse(
      'https://bedrock-runtime.$region.amazonaws.com/model/$modelId/invoke-with-response-stream',
    );

    final request = AWSHttpRequest.post(
      url,
      body: bodyBytes,
      headers: {
        'content-type': 'application/json',
        'accept': 'application/json',
      },
    );

    final signedRequest = await _signer.sign(
      request,
      credentialScope: AWSCredentialScope(
        region: region,
        service: const AWSService('bedrock'),
      ),
    );

    int retryCount = 0;
    while (true) {
      try {
        _logger.info(
          'Sending streaming request to Bedrock, timeout: ${timeout.inSeconds} seconds, proxy:${proxyUrl ?? 'none'} ,message length: ${messages.length}, tools: ${tools?.length}, model: ${modelConfig.model}',
        );
        final startTime = DateTime.now();
        final response = await _client.postUri(
          url,
          data: Stream.fromIterable([bodyBytes]),
          options: Options(
            headers: signedRequest.headers,
            responseType: ResponseType.stream,
            sendTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (status) => true,
          ),
          cancelToken: cancelToken,
        );
        final endTime = DateTime.now();
        _logger.info(
          'Received streaming response from Bedrock, status code: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds} ms',
        );

        if (response.statusCode == 200) {
          final stream = (response.data.stream as Stream).cast<List<int>>();
          final controller = StreamController<StreamingMessage>();
          final parser = _BedrockStreamParser(modelConfig);

          stream
              .transform(EventStreamDecoder())
              .listen(
                (event) {
                  // Bedrock EventStream structure:
                  // Headers: :event-type, :content-type, :message-type
                  // Payload: JSON
                  final eventType = event.headers[':event-type'];
                  if (eventType == 'chunk') {
                    try {
                      final payload = jsonDecode(event.payloadAsString);
                      final bytes = base64Decode(payload['bytes']);
                      final chunkJson = jsonDecode(utf8.decode(bytes));

                      // Parse Anthropic Chunk using stateful parser
                      final message = parser.parse(chunkJson);
                      if (message != null) {
                        controller.add(StreamingMessage(modelMessage: message));
                      }
                    } catch (e) {
                      _logger.warning('Error parsing chunk: $e');
                    }
                  } else if (eventType == 'usage') {
                    // Handle usage if provided in a separate event
                  } else if (eventType == 'exception') {
                    // Handle exception event in stream
                    final payload = jsonDecode(event.payloadAsString);
                    controller.addError(
                      Exception(
                        'Bedrock Stream Exception: ${payload['message']}',
                      ),
                    );
                  }
                },
                onError: (e) {
                  controller.addError(e);
                },
                onDone: () {
                  controller.close();
                },
              );

          return controller.stream;
        }

        // Retry on 429 or 5xx
        if (response.statusCode == 429 ||
            (response.statusCode != null && response.statusCode! >= 500)) {
          if (retryCount < maxRetries) {
            await _waitForRetry(retryCount, 'Status ${response.statusCode}');
            retryCount++;
            continue;
          }
        }

        // Handle error response body for streams (might be text or json)
        final errorBody = await utf8.decodeStream(
          (response.data.stream as Stream).cast<List<int>>(),
        );

        throw Exception(
          'Bedrock Stream API Error: ${response.statusCode} $errorBody',
        );
      } catch (e) {
        if (e is DioException) {
          if (retryCount < maxRetries) {
            await _waitForRetry(retryCount, 'DioException: ${e.message}');
            retryCount++;
            continue;
          }
          final errorMsg = e.response?.data ?? e.message;
          _logger.severe('Bedrock Stream Error: $errorMsg', e, e.stackTrace);
          throw Exception('Bedrock Stream Error: $errorMsg');
        }
        rethrow;
      }
    }
  }

  // Reuse logic from OpenAI/Claude clients for body creation
  Map<String, dynamic> _createRequestBody(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
  }) {
    // Bedrock expects standard Anthropic messages format
    // But puts 'anthropic_version' in the body
    final body = <String, dynamic>{
      'anthropic_version': 'bedrock-2023-05-31',
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
                    }
                    // TODO: Handle other parts like Audio/Video if supported by Claude on Bedrock
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

              // Add thinking block first if present
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
                // Sanitize function calls to handle fragmented history from previous bug
                // where partial streams were saved as separate calls with empty IDs.
                final validCalls = <FunctionCall>[];
                for (final call in m.functionCalls) {
                  if (call.id.isNotEmpty) {
                    validCalls.add(call);
                  } else if (validCalls.isNotEmpty) {
                    // unexpected empty ID, merge args to previous call
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
                // Bedrock/Claude expects tool_result
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

    // Support for Thinking and Output Config/Format
    if (modelConfig.extra != null) {
      if (modelConfig.extra!['thinking'] != null) {
        body['thinking'] = modelConfig.extra!['thinking'];
      }
      if (modelConfig.extra!['output_config'] != null) {
        body['output_config'] = modelConfig.extra!['output_config'];
      }
    }

    // Warn if jsonOutput is requested but no schema provided
    if (jsonOutput == true && body['output_config'] == null) {
      _logger.warning(
        'jsonOutput is true but no output_config provided. '
        'Bedrock/Claude typically requires a JSON schema for structured output. '
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
      throw Exception('Bedrock Error: ${data['error']?['message']}');
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
              totalTokens:
                  (data['usage']['input_tokens'] ?? 0) +
                  (data['usage']['output_tokens'] ?? 0),
              // Map cache_read_input_tokens to cachedToken
              cachedToken:
                  (data['usage']['cache_read_input_tokens'] ?? 0) +
                  (data['usage']['cache_creation_input_tokens'] ?? 0),
              // Note: ModelUsage also has thoughtToken, but Anthropic doesn't explicitly separate it in 'usage' object yet
              // unless it's part of output_tokens.
              model: modelConfig.model,
            )
          : null,
    );
  }
}

class _BedrockStreamParser {
  final ModelConfig modelConfig;
  String? _currentToolId;
  String? _currentToolName;
  final StringBuffer _currentToolJson = StringBuffer();

  // Accumulate usage across the stream
  int _promptTokens = 0;
  int _completionTokens = 0;
  int _cachedTokens = 0;
  int _thoughtTokens = 0;

  _BedrockStreamParser(this.modelConfig);

  ModelMessage? parse(Map<String, dynamic> chunk) {
    final type = chunk['type'];

    if (type == 'content_block_start') {
      final start = chunk['content_block'];
      // Handle tool_use start by resetting state
      if (start['type'] == 'tool_use') {
        _currentToolId = start['id'];
        _currentToolName = start['name'];
        _currentToolJson.clear();
        // Don't yield start event, wait for end to ensure complete call
      } else if (start['type'] == 'thinking') {
        // Start of thinking block
        return ModelMessage(
          thought: '', // Initialize thought
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
        // Don't yield partial arguments
      }
    } else if (type == 'content_block_stop') {
      // If we are aggregating a tool, finalize it here
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
      if (message['usage'] != null) {
        final usage = message['usage'];
        _promptTokens = usage['input_tokens'] ?? 0;
        _cachedTokens =
            (usage['cache_read_input_tokens'] ?? 0) +
            (usage['cache_creation_input_tokens'] ?? 0);

        // Even though completion tokens are 0 here, we verify
        _completionTokens += (usage['output_tokens'] as int? ?? 0);
        return ModelMessage(usage: _currentUsage(), model: modelConfig.model);
      }
    } else if (type == 'message_delta') {
      final delta = chunk['delta'];
      String? stopReason;

      if (delta['stop_reason'] != null) {
        stopReason = delta['stop_reason'];
      }

      if (chunk['usage'] != null) {
        final u = chunk['usage'];
        final newOutputTokens = (u['output_tokens'] as int? ?? 0);
        _completionTokens =
            newOutputTokens; // Usually this is the total output tokens so far or final

        // Bedrock/Anthropic might output reasoning_tokens inside output_tokens_details or similar
        // Check for 'output_tokens_details' -> 'reasoning_tokens'
        // If it's a delta, we might need to be careful, but message_delta usually has the final usage for the message
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

/// AWS EventStream Decoder for Dart.
/// Decodes binary `application/vnd.amazon.eventstream` data.
///
/// Reference: https://docs.aws.amazon.com/transcribe/latest/dg/event-stream.html
///
/// Message Structure:
/// -------------------------------------------------------------------
/// | Total len (4) | Headers len (4) | Prelude CRC (4) | Headers | Payload | Message CRC (4) |
/// -------------------------------------------------------------------
class EventStreamDecoder
    extends StreamTransformerBase<List<int>, EventStreamMessage> {
  @override
  Stream<EventStreamMessage> bind(Stream<List<int>> stream) async* {
    final buffer = <int>[];

    await for (final chunk in stream) {
      buffer.addAll(chunk);

      while (true) {
        if (buffer.length < 8) {
          // Not enough data for prelude (total len + headers len)
          break;
        }

        // 1. Read Total Length (4 bytes, big-endian)
        final totalLengthData = Uint8List.fromList(buffer.sublist(0, 4));
        final totalLength = ByteData.view(
          totalLengthData.buffer,
        ).getUint32(0, Endian.big);

        if (buffer.length < totalLength) {
          // Wait for more data
          break;
        }

        // 2. Extract full message bytes
        final messageBytes = Uint8List.fromList(buffer.sublist(0, totalLength));
        buffer.removeRange(0, totalLength);

        // 3. Parse Message
        try {
          final message = _parseMessage(messageBytes);
          yield message;
        } catch (e) {
          // If parsing fails (e.g. CRC mismatch), we might want to throw or skip?
          // Throwing is safer for stream integrity.
          throw FormatException('Failed to parse EventStream message: $e');
        }
      }
    }
  }

  EventStreamMessage _parseMessage(Uint8List bytes) {
    final view = ByteData.view(bytes.buffer);

    // 1. Prelude
    final totalLength = view.getUint32(0, Endian.big);
    final headersLength = view.getUint32(4, Endian.big);
    // final preludeCrc = view.getUint32(8, Endian.big);

    // TODO: Verify Prelude CRC
    // _verifyCrc(bytes.sublist(0, 8), preludeCrc);

    // 2. Headers
    final headersEnd = 12 + headersLength;
    final headersBytes = bytes.sublist(12, headersEnd);
    final headers = _parseHeaders(headersBytes);

    // 3. Payload
    // payload is between headers and the last 4 bytes (Message CRC)
    final payloadStart = headersEnd;
    final payloadEnd = totalLength - 4;
    final payload = bytes.sublist(payloadStart, payloadEnd);

    // 4. Message CRC
    // final messageCrc = view.getUint32(payloadEnd, Endian.big);

    // TODO: Verify Message CRC
    // _verifyCrc(bytes.sublist(0, payloadEnd), messageCrc);

    return EventStreamMessage(headers, payload);
  }

  Map<String, String> _parseHeaders(Uint8List headerBytes) {
    final headers = <String, String>{};
    var offset = 0;
    final view = ByteData.view(headerBytes.buffer);

    while (offset < headerBytes.length) {
      // Header Name Length (1 byte)
      final nameLen = headerBytes[offset];
      offset += 1;

      // Header Name
      final name = utf8.decode(headerBytes.sublist(offset, offset + nameLen));
      offset += nameLen;

      // Header Value Type (1 byte)
      final valueType = headerBytes[offset];
      offset += 1;

      // Value Content
      switch (valueType) {
        case 7: // String
          final valueLen = view.getUint16(offset, Endian.big);
          offset += 2;
          final value = utf8.decode(
            headerBytes.sublist(offset, offset + valueLen),
          );
          offset += valueLen;
          headers[name] = value;
          break;
        case 6: // Byte Array - we might not need this for text streams, but good for completeness
          final valueLen = view.getUint16(offset, Endian.big);
          offset += 2;
          // treating as base64 string for simplicity or creating a separate type?
          // For now assuming string headers as per common Bedrock usage
          offset += valueLen;
          break;

        // TODO: Handle other types (bool, byte, short, int, long, timestamp, UUID) if needed
        default:
          throw FormatException(
            'Unsupported header value type: $valueType for header $name',
          );
      }
    }
    return headers;
  }
}

class EventStreamMessage {
  final Map<String, String> headers;
  final Uint8List payload;

  EventStreamMessage(this.headers, this.payload);

  String get payloadAsString => utf8.decode(payload);

  // Helper to interpret payload as JSON
  Map<String, dynamic>? get jsonPayload {
    try {
      return jsonDecode(payloadAsString) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  @override
  String toString() =>
      'EventStreamMessage(headers: $headers, payload: ${payload.length} bytes)';
}
