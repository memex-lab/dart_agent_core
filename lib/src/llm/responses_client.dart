import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import '../core/http_util.dart';
import '../core/llm_client.dart';
import '../core/message.dart';
import '../core/tool.dart';
import 'package:logging/logging.dart';

class ResponsesClient extends LLMClient {
  final Logger _logger = Logger('ResponsesClient');
  final String apiKey;
  final String baseUrl;
  final Dio _client;
  final Duration timeout;
  final Duration connectTimeout;
  final String? proxyUrl;
  final int maxRetries;
  final int initialRetryDelayMs;
  final int maxRetryDelayMs;

  /// When true (default), the client derives [previous_response_id] from the last
  /// [ModelMessage.responseId] in [messages] and only sends messages after that
  /// response. When false, no automatic derivation is done; you can still pass
  /// [ModelConfig.extra]['previous_response_id'] explicitly. Disable this if you
  /// prefer to always send full history or manage previous_response_id yourself.
  final bool autoPreviousResponseId;

  /// Keys from [ModelConfig.extra] allowed to be forwarded to the API request body.
  /// When null (default), uses: { 'reasoning', 'caching', 'expire_at', 'thinking', 'store' }.
  /// Pass a custom set at construction to allow additional or different keys.
  final Set<String>? extraAllowedKeys;

  ResponsesClient({
    required this.apiKey,
    this.baseUrl = 'https://api.openai.com',
    this.timeout = const Duration(seconds: 300),
    this.connectTimeout = const Duration(seconds: 60),
    this.proxyUrl,
    this.maxRetries = 3,
    this.initialRetryDelayMs = 1000,
    this.maxRetryDelayMs = 10000,
    this.autoPreviousResponseId = true,
    this.extraAllowedKeys,
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
    final url = '$baseUrl/responses';
    final body = _createRequestBody(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      stream: false,
      jsonOutput: jsonOutput,
      autoPreviousResponseId: autoPreviousResponseId,
      extraAllowedKeys: extraAllowedKeys,
    );

    int retryCount = 0;
    int currentDelayMs = initialRetryDelayMs;

    Future<void> waitForRetry(String reason) async {
      _logger.warning(
        'Responses API: $reason. Retrying in ${currentDelayMs}ms... (Attempt ${retryCount + 1}/$maxRetries)',
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
          'Sending request to OpenAI Responses API (Attempt ${retryCount + 1}), timeout: ${timeout.inSeconds} seconds, proxy:${proxyUrl ?? 'none'} , message length: ${messages.length}, tools: ${tools?.length}, model: ${modelConfig.model}',
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
          'Received response from OpenAI Responses API, status code: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds} ms',
        );

        if (response.statusCode == 200) {
          final data = response.data is String
              ? jsonDecode(response.data)
              : response.data;

          final modelMessage = _parseResponse(data, modelConfig);
          // Update the previousResponseId for the next turn
          // if (modelMessage.responseId != null) {
          //   previousResponseId = modelMessage.responseId;
          // }
          return modelMessage;
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
            'Failed to generate from OpenAI Responses API: ${response.statusCode} ${response.statusMessage} ${response.data}',
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

  /// Check if a responseId is valid by making a GET request
  Future<bool> checkResponseId(String responseId) async {
    try {
      final url = '$baseUrl/responses/$responseId';
      _logger.info('Checking responseId: $responseId');

      final response = await _client.get(
        url,
        options: Options(
          sendTimeout: connectTimeout,
          receiveTimeout: timeout,
          headers: {'Authorization': 'Bearer $apiKey'},
          validateStatus: (code) => true,
        ),
      );

      if (response.statusCode == 200) {
        _logger.info('ResponseId $responseId is valid');
        return true;
      } else if (response.statusCode == 404) {
        _logger.warning('ResponseId $responseId not found (404)');
        return false;
      } else {
        _logger.warning(
          'Unexpected status code ${response.statusCode} when checking responseId $responseId',
        );
        return false;
      }
    } catch (e) {
      _logger.warning('Error checking responseId $responseId: $e');
      return false;
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
    final url = '$baseUrl/responses';
    final body = _createRequestBody(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      stream: true,
      jsonOutput: jsonOutput,
      autoPreviousResponseId: autoPreviousResponseId,
      extraAllowedKeys: extraAllowedKeys,
    );

    StreamController<StreamingMessage> controller =
        StreamController<StreamingMessage>();
    int retryCount = 0;
    int currentDelayMs = initialRetryDelayMs;

    Future<void> waitForRetry(String reason) async {
      _logger.warning(
        'Responses API Stream: $reason. Retrying in ${currentDelayMs}ms... (Attempt ${retryCount + 1}/$maxRetries)',
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
            'Sending streaming request to OpenAI Responses API, timeout: ${timeout.inSeconds} seconds, message length: ${messages.length}, tools: ${tools?.length}, model: ${modelConfig.model}',
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
            'Received streaming response from OpenAI Responses API, status code: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds} ms',
          );

          if (response.statusCode != 200) {
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
              'Failed to stream from OpenAI Responses API: ${response.statusCode} ${response.statusMessage} $responseBody',
            );
          }

          final stream = (response.data.stream as Stream).cast<List<int>>();

          final transformedStream = stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .transform(ResponsesChunkDecoder()) // Reusing SSE decoder
              .transform(ResponsesAPIResponseTransformer(modelConfig))
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

// ----------------------------------------------------------------------
// Request Body & Parsing Logic
// ----------------------------------------------------------------------

Map<String, dynamic> _createRequestBody(
  List<LLMMessage> messages, {
  List<Tool>? tools,
  ToolChoice? toolChoice,
  required ModelConfig modelConfig,
  bool stream = false,
  bool? jsonOutput,
  bool autoPreviousResponseId = true,
  Set<String>? extraAllowedKeys,
}) {
  const defaultExtraAllowedKeys = {
    'reasoning',
    'caching',
    'expire_at',
    'thinking',
    'store',
  };
  final allowedKeys = extraAllowedKeys ?? defaultExtraAllowedKeys;
  // 1. Determine previous_response_id: explicit extra, or (if autoPreviousResponseId) from last ModelMessage
  String? previousResponseId =
      modelConfig.extra?['previous_response_id'] as String?;
  int cutoffIndex = -1;

  if (previousResponseId == null && autoPreviousResponseId) {
    for (int i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m is ModelMessage && m.responseId != null) {
        previousResponseId = m.responseId;
        cutoffIndex = i;
        break;
      }
    }
  } else if (previousResponseId != null) {
    // Explicit previous_response_id: still need cutoff so we only send messages after that point
    // Only when effectiveAuto did not set cutoff, we send all messages (cutoffIndex stays -1)
    for (int i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m is ModelMessage && m.responseId == previousResponseId) {
        cutoffIndex = i;
        break;
      }
    }
  }

  // 2. Collect pending messages (those after the cutoff)
  // If no previousResponseId found, we take all messages.
  // If found, we take messages physically after that index.
  final List<LLMMessage> pendingMessages = [];
  if (cutoffIndex == -1) {
    pendingMessages.addAll(messages);
  } else {
    // Add all messages AFTER the cutoff index
    if (cutoffIndex + 1 < messages.length) {
      pendingMessages.addAll(messages.sublist(cutoffIndex + 1));
    }
  }

  // 3. Construct input list
  final List<Map<String, dynamic>> inputList = [];

  for (final m in pendingMessages) {
    if (m is UserMessage) {
      final contentList = <Map<String, dynamic>>[];
      for (final part in m.contents) {
        if (part is TextPart) {
          contentList.add({'type': 'input_text', 'text': part.text});
        } else if (part is ImagePart) {
          contentList.add({
            'type': 'input_image',
            'image_url': _convertBase64ToUrl(part.base64Data, part.mimeType),
            if (part.detail != null) 'detail': part.detail,
          });
        } else if (part is AudioPart) {
          String format = 'wav';
          if (part.mimeType.toLowerCase().contains('mp3') ||
              part.mimeType.toLowerCase().contains('mpeg')) {
            format = 'mp3';
          }
          contentList.add({
            'type': 'input_audio',
            'input_audio': {'data': part.base64Data, 'format': format},
          });
        }
      }
      inputList.add({
        'type': 'message',
        'role': 'user',
        'content': contentList,
      });
    } else if (m is SystemMessage) {
      // System message as 'system' role message
      if (previousResponseId == null) {
        inputList.add({
          'type': 'message',
          'role': 'system',
          'content': [
            {'type': 'input_text', 'text': m.content},
          ],
        });
      }
    } else if (m is ModelMessage) {
      // Assistant message (ResponseOutputMessageParam)
      final contentList = <Map<String, dynamic>>[];
      if (m.textOutput != null && m.textOutput!.isNotEmpty) {
        contentList.add({'type': 'output_text', 'text': m.textOutput});
      }

      // For audio, transcript is usually partial, so we prefer textOutput if available.
      // If there's pure audio output to feed back, Responses API uses 'output_audio' item type?
      // But mapped to ResponseOutputMessageParam, content is Text or Refusal.
      // Tool calls are separate items in Input List?
      // Wait, SDK: ResponseOutputMessageParam content is Text or Refusal.
      // Tool calls are `ResponseFunctionToolCallParam` which are separate items in the input list.

      if (contentList.isNotEmpty) {
        inputList.add({
          'type': 'message',
          'role': 'assistant',
          'content': contentList,
          'status': 'completed',
        });
      }

      // Handle Tool Calls from ModelMessage
      for (final fc in m.functionCalls) {
        inputList.add({
          'type': 'function_call',
          'call_id': fc.id,
          'name': fc.name,
          'arguments': fc.arguments,
        });
      }
    } else if (m is FunctionExecutionResultMessage) {
      // Tool Output (FunctionCallOutput)
      for (final res in m.results) {
        // Create one input item per result
        dynamic outputContent;

        // Check if content is simple string or needs mixed parts
        // For now, assuming string is safest for 'output' unless we have specific file types
        // SDK: output is string or array.
        final textParts = <String>[];
        // final otherParts = [];

        for (final part in res.content) {
          if (part is TextPart) {
            textParts.add(part.text);
          }
          // Support other parts if needed according to SDK 'ResponseFunctionCallOutputItemListParam'
        }

        final textContent = textParts.join('\n');
        outputContent = textContent;

        inputList.add({
          'type': 'function_call_output',
          'call_id': res.id,
          'output': outputContent,
        });
      }
    }
  }

  final Map<String, dynamic> body = {
    'model': modelConfig.model,
    'stream': stream,
  };

  if (inputList.isNotEmpty) {
    body['input'] = inputList;
  }

  if (previousResponseId != null) {
    body['previous_response_id'] = previousResponseId;
  }

  // Tools logic (unchanged essentially, just verifying placement)
  if (tools != null && tools.isNotEmpty && previousResponseId == null) {
    body['tools'] = tools
        .map(
          (t) => {
            'type': 'function',
            'name': t.name,
            'description': t.description,
            'parameters': t.parameters,
          },
        )
        .toList();

    // Tool Choice
    if (toolChoice != null) {
      if (toolChoice.allowedFunctionNames != null &&
          toolChoice.allowedFunctionNames!.isNotEmpty) {
        if (toolChoice.mode == ToolChoiceMode.required &&
            toolChoice.allowedFunctionNames!.length == 1) {
          body['tool_choice'] = {
            'type': 'function',
            'name': toolChoice.allowedFunctionNames!.first,
          };
        } else {
          body['tool_choice'] = {
            'type': 'allowed_tools',
            'mode': toolChoice.mode == ToolChoiceMode.required
                ? 'required'
                : 'auto',
            'tools': toolChoice.allowedFunctionNames!
                .map((name) => {'type': 'function', 'name': name})
                .toList(),
          };
        }
      } else {
        switch (toolChoice.mode) {
          case ToolChoiceMode.none:
            body['tool_choice'] = 'none';
            break;
          case ToolChoiceMode.auto:
            body['tool_choice'] = 'auto';
            break;
          case ToolChoiceMode.required:
            body['tool_choice'] = 'required';
            break;
        }
      }
    }
  }

  // 3. Config
  if (modelConfig.temperature != null)
    body['temperature'] = modelConfig.temperature;
  if (modelConfig.maxTokens != null)
    body['max_output_tokens'] = modelConfig.maxTokens;
  if (modelConfig.topP != null) body['top_p'] = modelConfig.topP;

  // Extra parameters
  if (modelConfig.extra != null) {
    for (final entry in modelConfig.extra!.entries) {
      if (allowedKeys.contains(entry.key)) {
        body[entry.key] = entry.value;
      }
    }
  }

  return body;
}

ModelMessage _parseResponse(
  Map<String, dynamic> data,
  ModelConfig modelConfig,
) {
  // Responses API structure:
  // { id: 'resp_...', output: [ { type: 'message', content: [...] }, ... ], usage: ... }

  final responseId = data['id'] as String?;
  final output = data['output'] as List? ?? [];

  // Accumulate content
  String textOutput = '';
  String reasoningOutput = '';
  List<FunctionCall> functionCalls = [];
  List<ModelAudioPart> audioOutputs = [];

  for (final item in output) {
    if (item['type'] == 'message') {
      // content list
      final contentList = item['content'] as List? ?? [];
      for (final content in contentList) {
        if (content['type'] == 'output_text') {
          textOutput += content['text'] ?? '';
        } else if (content['type'] == 'audio') {
          // ...
        }
      }
    } else if (item['type'] == 'function_call') {
      // Format might differ.
      // In Responses API, tools often appear in 'output' items?
      // Wait, Python SDK types: `ResponseFunctionToolCall` is a `ResponseOutputItem`.
      // Structure: { type: 'function_call', id: '..', call_id: '..', function: { name: .., arguments: .. } }
      // Or { type: 'function', ... }?
      // SDK `ResponseFunctionToolCall`: `type: function_call`, `call_id`, `function`...

      functionCalls.add(
        FunctionCall(
          id: item['call_id'] ?? item['id'] ?? '',
          name: item['name'] ?? item['function']?['name'],
          arguments: item['arguments'] ?? item['function']?['arguments'],
        ),
      );
    } else if (item['type'] == 'reasoning') {
      final summary = item['summary'] as List? ?? [];
      for (final s in summary) {
        reasoningOutput += s['text'] ?? '';
      }
    }
  }

  // Usage
  ModelUsage? usage;
  if (data['usage'] != null) {
    // ... parse usage (similar structure usually)
    final u = data['usage'];
    usage = ModelUsage(
      promptTokens: u['input_tokens'] ?? 0,
      completionTokens: u['output_tokens'] ?? 0,
      totalTokens: u['total_tokens'] ?? 0,
      cachedToken: u['input_tokens_details']?['cached_tokens'] ?? 0,
      thoughtToken: u['output_tokens_details']?['reasoning_tokens'] ?? 0,
      model: modelConfig.model,
    );
  }

  // Stop reason?
  // Often in `status` or `incomplete_details` or individual items?
  // Responses API usually has top-level status 'completed'.
  final stopReason = data['status'];

  return ModelMessage(
    textOutput: textOutput,
    functionCalls: functionCalls,
    audioOutputs: audioOutputs,
    usage: usage,
    model: modelConfig.model,
    responseId: responseId,
    thought: reasoningOutput,
    metadata: data,
    stopReason: stopReason,
  );
}

// ----------------------------------------------------------------------
// Stream Transformer (SSE)
// ----------------------------------------------------------------------

// Reusing ResponsesChunkDecoder from openai_client.dart (need to make it public or duplicate)
// Creating a local one for now to avoid import issues if it's private.
class ResponsesChunkDecoder
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

class ResponsesAPIResponseTransformer
    extends StreamTransformerBase<Map<String, dynamic>, ModelMessage> {
  final ModelConfig modelConfig;

  ResponsesAPIResponseTransformer(this.modelConfig);

  @override
  Stream<ModelMessage> bind(Stream<Map<String, dynamic>> stream) async* {
    // We need to accumulate deltas similar to Chat API, but event types are different.
    // Responses API events:
    // - response.created -> has ID
    // - response.output_item.added -> new item (message, tool_call)
    // - response.content_part.added -> text, audio
    // - response.text.delta -> text chunk
    // - response.function_call_arguments.delta -> args chunk
    // - response.done

    // We need buffers for active items.
    // Map item_id -> buffer/state

    // Using a simplified approach: just yield chunks immediately for text.
    // Buffer tool calls.

    final Map<String, ButtonToolCallBuffer> toolBuffers = {};

    await for (final event in stream) {
      // Event structure: { type: "response.text.delta", ... }
      final type = event['type'] as String?;

      // 1. Response Lifecycle
      if (type == 'response.created') {
        final response = event['response'];
        if (response != null && response['id'] != null) {
          // Can emit ID via callback or metadata if needed.
          // For now, we wait for 'response.completed' or accumulate via ModelMessage.responseId
        }
      }

      if (type == 'response.in_progress') {
        // Model started processing
      }

      if (type == 'response.completed') {
        final response = event['response'];
        if (response != null && response['usage'] != null) {
          final u = response['usage'];
          final usage = ModelUsage(
            promptTokens: u['input_tokens'] ?? 0,
            completionTokens: u['output_tokens'] ?? 0,
            totalTokens: u['total_tokens'] ?? 0,
            cachedToken: u['input_tokens_details']?['cached_tokens'] ?? 0,
            thoughtToken: u['output_tokens_details']?['reasoning_tokens'] ?? 0,
            model: modelConfig.model,
          );
          yield ModelMessage(
            usage: usage,
            model: modelConfig.model,
            responseId: response['id'],
            stopReason: response['incomplete_details'] != null
                ? 'incomplete'
                : 'end_turn',
            metadata: {'status': 'completed'},
          );
        }
      }

      if (type == 'response.failed') {
        final error = event['error'];
        throw Exception(
          'Response generation failed: [${error?['code']}] ${error?['message']}',
        );
      }

      if (type == 'response.incomplete') {
        // Output might be cut off
        yield ModelMessage(
          stopReason: 'incomplete', // or max_tokens
          model: modelConfig.model,
          metadata: {'status': 'incomplete'},
        );
      }

      // 2. Output Items & Content Parts
      if (type == 'response.output_item.added') {
        final item = event['item'];
        final itemId = item['id'];
        final itemType = item['type'];

        if (itemType == 'function_call') {
          toolBuffers[itemId] = ButtonToolCallBuffer(
            id: item['call_id'] ?? item['id'] ?? '', // call_id usually
            name: item['name'] ?? item['function']?['name'] ?? '',
            arguments: '',
          );
        }
      }

      if (type == 'response.output_item.done') {
        final item = event['item'];
        final itemId = item['id'];

        // Finalize function call
        if (toolBuffers.containsKey(itemId)) {
          final buffer = toolBuffers[itemId]!;
          // Remove from buffer
          toolBuffers.remove(itemId);

          yield ModelMessage(
            functionCalls: [
              FunctionCall(
                id: buffer.id,
                name: buffer.name,
                arguments: buffer.arguments.isEmpty
                    ? (item['arguments'] ??
                          item['function']?['arguments'] ??
                          '')
                    : buffer.arguments,
              ),
            ],
            model: modelConfig.model,
          );
        }
      }

      // 'response.content_part.added' / 'done' - usually just structural, we track deltas.

      // 3. Text Generation
      if (type == 'response.output_text.delta') {
        final delta = event['delta'] as String?;
        if (delta != null) {
          yield ModelMessage(textOutput: delta, model: modelConfig.model);
        }
      }

      if (type == 'response.output_text.done') {
        // Could yield final text chunk verification if needed, but delta is usually sufficient.
      }

      // 4. Reasoning
      if (type == 'response.reasoning_summary_text.delta') {
        // Not mapping to `thought` yet as it's a summary?
        // Or mapping to `thought`. Let's assume `thought` field is appropriate.
        final delta = event['delta'] as String?;
        if (delta != null) {
          yield ModelMessage(thought: delta, model: modelConfig.model);
        }
      }

      if (type == 'response.reasoning_summary_text.done') {
        // Not mapping to `thought` yet as it's a summary?
        // Or mapping to `thought`. Let's assume `thought` field is appropriate.
        // final text = event['text'] as String?;
        // if (text != null) {
        //   yield ModelMessage(thought: text, model: modelConfig.model);
        // }
      }

      // 5. Tool & Function Calling
      if (type == 'response.function_call_arguments.delta') {
        final itemId = event['item_id'] as String;
        final delta = event['delta'] as String?;

        if (toolBuffers.containsKey(itemId)) {
          toolBuffers[itemId]!.arguments += (delta ?? '');
        }
      }

      if (type == 'response.function_call_arguments.done') {
        // Arguments fully generated.
        // We arguably wait for output_item.done to yield the full call.
      }

      // 6. Safety & Errors
      if (type == 'response.refusal.delta') {
        final delta = event['delta'] as String?;
        if (delta != null) {
          // Refusal is a form of text output generally
          yield ModelMessage(
            textOutput: delta,
            model: modelConfig.model,
            metadata: {'isRefusal': true},
          );
        }
      }

      if (type == 'error') {
        final code = event['code'];
        final message = event['message'];
        throw Exception('OpenAI Responses Stream Error: [$code] $message');
      }

      // Audio
      if (type == 'response.audio.delta') {
        final delta = event['delta'] as String?;
        if (delta != null) {
          yield ModelMessage(
            audioOutputs: [
              ModelAudioPart(base64Data: delta, mimeType: 'audio/pcm'),
            ],
            model: modelConfig.model,
          );
        }
      }

      if (type == 'response.audio.transcript.delta') {
        final delta = event['delta'] as String?;
        if (delta != null) {
          yield ModelMessage(
            textOutput: delta,
            model: modelConfig.model,
            metadata: {'isTranscript': true},
          );
        }
      }
      // Handle other events as needed...
    }
  }
}

class ButtonToolCallBuffer {
  String id;
  String name;
  String arguments;
  ButtonToolCallBuffer({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

String _convertBase64ToUrl(String base64Data, String mimeType) {
  if (base64Data.startsWith("data")) {
    return base64Data;
  }
  return 'data:$mimeType;base64,$base64Data';
}
