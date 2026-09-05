import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync(
      'file_state_storage_session_id_',
    );
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  test('save and load keep the file under the storage directory', () async {
    final storage = FileStateStorage(directory.path);
    await storage.save(AgentState(sessionId: 'session_123'));

    expect(File('${directory.path}/session_123.json').existsSync(), isTrue);

    final loaded = await storage.loadOrCreate('session_123', null);
    expect(loaded.sessionId, 'session_123');
  });

  test('rejects a sessionId that would escape the storage directory', () async {
    final storage = FileStateStorage(directory.path);

    expect(
      () => storage.save(AgentState(sessionId: '../../escaped')),
      throwsA(isA<ArgumentError>()),
    );
    expect(File('${directory.parent.path}/escaped.json').existsSync(), isFalse);
  });
}
