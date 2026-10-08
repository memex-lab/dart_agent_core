import 'package:dio/dio.dart';

/// Whether [error] is a Dio cancellation (user abort / CancelToken).
///
/// Cancelled requests must not be retried; Claude/Bedrock must rethrow the
/// original [DioException] so [StatefulAgent.isCancelled] can recognize it.
bool isLlmRequestCancelled(Object error) {
  return error is DioException && CancelToken.isCancel(error);
}

/// Download filename for OpenAI file inputs (Chat Completions `file` parts and
/// Responses API `input_file` items) derived from a MIME type.
String filenameForOpenAiFileInput(String mimeType) {
  final mime = mimeType.toLowerCase().split(';').first.trim();
  switch (mime) {
    case 'application/pdf':
      return 'document.pdf';
    case 'text/plain':
      return 'document.txt';
    case 'text/csv':
    case 'application/csv':
      return 'document.csv';
    case 'application/json':
      return 'document.json';
    case 'text/html':
      return 'document.html';
    case 'text/markdown':
      return 'document.md';
    case 'application/msword':
      return 'document.doc';
    case 'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
      return 'document.docx';
    case 'application/vnd.ms-excel':
      return 'document.xls';
    case 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
      return 'document.xlsx';
    default:
      final slash = mime.indexOf('/');
      final subtype = slash >= 0 ? mime.substring(slash + 1) : mime;
      final ext = subtype.contains('+') ? subtype.split('+').last : subtype;
      if (ext.isNotEmpty && RegExp(r'^[a-z0-9]{1,8}$').hasMatch(ext)) {
        return 'document.$ext';
      }
      return 'document.bin';
  }
}
