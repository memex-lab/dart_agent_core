import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'langfuse_event.dart';

const _uuid = Uuid();

/// 32 lowercase hex chars, the OTLP trace id width.
String newOtelTraceId() => _uuid.v4().replaceAll('-', '');

/// 16 lowercase hex chars, the OTLP span id width.
String newOtelSpanId() => _uuid.v4().replaceAll('-', '').substring(0, 16);

/// Keeps hex and fits [length]. Legacy Langfuse ids are UUIDs with dashes.
String otelHex(String raw, int length) {
  final hex = raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
  if (hex.length >= length) return hex.substring(0, length);
  return hex.padRight(length, '0');
}

String unixTimeNano(DateTime time) {
  final micros = time.toUtc().microsecondsSinceEpoch;
  return (BigInt.from(micros) * BigInt.from(1000)).toString();
}

Map<String, dynamic> otlpExport(List<Map<String, dynamic>> spans) => {
  'resourceSpans': [
    {
      'resource': {
        'attributes': [_stringAttr('service.name', 'dart_agent_core')],
      },
      'scopeSpans': [
        {
          'scope': {'name': 'dart_agent_core'},
          'spans': spans,
        },
      ],
    },
  ],
};

/// One finished span. [traceName], user, session, tags, and metadata are
/// copied onto the span so Langfuse v4 can filter child observations.
Map<String, dynamic> langfuseSpan({
  required String traceId,
  required String spanId,
  String? parentSpanId,
  required String name,
  required String type,
  required DateTime start,
  required DateTime end,
  required String traceName,
  required String userId,
  required String sessionId,
  required List<String> tags,
  required String environment,
  String? release,
  String? version,
  Object? input,
  Object? output,
  Map<String, dynamic> traceMetadata = const {},
  Map<String, dynamic> observationMetadata = const {},
  String? model,
  Map<String, dynamic>? modelParameters,
  Map<String, Object?>? usage,
  String? level,
  String? statusMessage,
}) {
  final attributes = <Map<String, dynamic>>[
    _stringAttr('langfuse.trace.name', traceName),
    _stringAttr('langfuse.user.id', userId),
    _stringAttr('user.id', userId),
    _stringAttr('langfuse.session.id', sessionId),
    _stringAttr('session.id', sessionId),
    _stringAttr('langfuse.environment', environment),
    _stringAttr('langfuse.observation.type', type),
    if (tags.isNotEmpty) _stringListAttr('langfuse.trace.tags', tags),
    if (release != null) _stringAttr('langfuse.release', release),
    if (version != null) _stringAttr('langfuse.version', version),
    if (input != null)
      _stringAttr('langfuse.observation.input', jsonEncode(input)),
    if (output != null)
      _stringAttr('langfuse.observation.output', jsonEncode(output)),
    if (model != null) _stringAttr('langfuse.observation.model.name', model),
    if (modelParameters != null && modelParameters.isNotEmpty)
      _stringAttr(
        'langfuse.observation.model.parameters',
        jsonEncode(modelParameters),
      ),
    if (usage != null)
      _stringAttr('langfuse.observation.usage_details', jsonEncode(usage)),
    if (level != null) _stringAttr('langfuse.observation.level', level),
    if (statusMessage != null)
      _stringAttr('langfuse.observation.status_message', statusMessage),
  ];
  _addMetadata(attributes, 'langfuse.trace.metadata', traceMetadata);
  _addMetadata(
    attributes,
    'langfuse.observation.metadata',
    observationMetadata,
  );

  final failed = level == 'ERROR';
  return {
    'traceId': traceId,
    'spanId': spanId,
    'parentSpanId': ?parentSpanId,
    'name': name,
    'kind': 1,
    'startTimeUnixNano': unixTimeNano(start),
    'endTimeUnixNano': unixTimeNano(end),
    'attributes': attributes,
    'status': {
      'code': failed ? 2 : 1,
      if (failed && statusMessage != null) 'message': statusMessage,
    },
  };
}

Map<String, dynamic>? scoreFromLegacy(LangfuseEvent event) {
  if (event.type != 'score-create') return null;
  final body = event.body;
  final name = body['name'];
  if (name is! String) return null;
  final traceRaw = body['traceId'];
  return {
    if (body['id'] != null) 'id': body['id'],
    if (traceRaw is String) 'traceId': otelHex(traceRaw, 32),
    if (body['observationId'] is String)
      'observationId': otelHex(body['observationId'] as String, 16),
    'name': name,
    'value': body['value'],
    if (body['dataType'] != null) 'dataType': body['dataType'],
    if (body['comment'] != null) 'comment': body['comment'],
    if (body['environment'] != null) 'environment': body['environment'],
    if (body['metadata'] != null) 'metadata': body['metadata'],
    'timestamp': event.timestamp.toUtc().toIso8601String(),
  };
}

Map<String, dynamic> spanFromLegacy(LangfuseEvent event) {
  final body = event.body;
  final traceRaw = body['traceId'] ?? body['id'];
  final spanRaw = body['id'] ?? event.id;
  final start = _time(body['startTime']) ?? event.timestamp;
  final end = _time(body['endTime']) ?? start;
  final usage = body['usage'];
  return langfuseSpan(
    traceId: traceRaw is String ? otelHex(traceRaw, 32) : otelHex(event.id, 32),
    spanId: spanRaw is String ? otelHex(spanRaw, 16) : otelHex(event.id, 16),
    name: body['name'] as String? ?? event.type,
    type: _legacyType(event.type),
    start: start,
    end: end,
    traceName: body['name'] as String? ?? event.type,
    userId: body['userId'] as String? ?? '',
    sessionId: body['sessionId'] as String? ?? '',
    tags:
        (body['tags'] as List?)?.map((t) => t.toString()).toList() ?? const [],
    environment: body['environment'] as String? ?? 'default',
    release: body['release'] as String?,
    version: body['version'] as String?,
    input: body['input'],
    output: body['output'],
    traceMetadata: body['metadata'] is Map
        ? Map<String, dynamic>.from(body['metadata'] as Map)
        : const {},
    model: body['model'] as String?,
    modelParameters: body['modelParameters'] is Map
        ? Map<String, dynamic>.from(body['modelParameters'] as Map)
        : null,
    usage: usage is Map ? Map<String, Object?>.from(usage) : null,
    level: body['level'] as String?,
    statusMessage: body['statusMessage'] as String?,
  );
}

String _legacyType(String type) {
  if (type.startsWith('generation')) return 'generation';
  if (type.startsWith('span')) return 'span';
  return 'span';
}

DateTime? _time(Object? raw) {
  if (raw is String) return DateTime.tryParse(raw);
  return null;
}

Map<String, dynamic> _stringAttr(String key, String value) => {
  'key': key,
  'value': {'stringValue': value},
};

Map<String, dynamic> _stringListAttr(String key, List<String> values) => {
  'key': key,
  'value': {
    'arrayValue': {
      'values': [
        for (final value in values) {'stringValue': value},
      ],
    },
  },
};

void _addMetadata(
  List<Map<String, dynamic>> attributes,
  String prefix,
  Map<String, dynamic> metadata,
) {
  for (final entry in metadata.entries) {
    final value = entry.value;
    attributes.add(
      _stringAttr(
        '$prefix.${entry.key}',
        value is String ? value : jsonEncode(value),
      ),
    );
  }
}
