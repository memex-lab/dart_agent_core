import 'dart:io';

import 'package:dart_agent_core/eval.dart';

Future<void> main(List<String> args) async {
  final code = await runTranscriptViewer(args);
  if (code != 0) exit(code);
}
