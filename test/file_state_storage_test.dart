import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/src/agent/file_state_storage_web.dart'
    as web_fs;
import 'package:test/test.dart';

void main() {
  group('FileStateStorage io', () {
    late Directory tempDir;
    late FileStateStorage storage;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dac-state-');
      storage = FileStateStorage(tempDir.path);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('save, exist, loadOrCreate, and delete round-trip', () async {
      final state = AgentState(sessionId: 'sess-1', metadata: {'k': 'v'});
      await storage.save(state);

      expect(await storage.exist('sess-1'), isTrue);
      expect(File('${tempDir.path}/sess-1.json').existsSync(), isTrue);

      final loaded = await storage.loadOrCreate('sess-1', {'extra': '1'});
      expect(loaded.sessionId, 'sess-1');
      expect(loaded.metadata['k'], 'v');
      expect(loaded.metadata['extra'], '1');

      final kept = await storage.loadOrCreate('sess-1', {
        'ignored': 'x',
      }, overwrite: false);
      expect(kept.metadata.containsKey('ignored'), isFalse);

      await storage.delete('sess-1');
      expect(await storage.exist('sess-1'), isFalse);
    });

    test(
      'corrupt JSON is treated as missing and creates a new state',
      () async {
        File('${tempDir.path}/bad.json')
          ..createSync(recursive: true)
          ..writeAsStringSync('{not-json');

        final created = await storage.loadOrCreate('bad', {'fresh': true});
        expect(created.sessionId, 'bad');
        expect(created.metadata['fresh'], true);
      },
    );

    test(
      'loadOrCreate creates a new session when the file is absent',
      () async {
        final created = await storage.loadOrCreate('new', {'a': 1});
        expect(created.sessionId, 'new');
        expect(created.metadata['a'], 1);
        expect(await storage.exist('new'), isFalse);
      },
    );
  });

  group('FileStateStorage web in-memory map', () {
    test('namespaces sessions by directoryPath', () async {
      final a = web_fs.FileStateStorage('ns-a');
      final b = web_fs.FileStateStorage('ns-b');
      await a.save(AgentState(sessionId: 'same', metadata: {'from': 'a'}));
      await b.save(AgentState(sessionId: 'same', metadata: {'from': 'b'}));

      final loadedA = await a.loadOrCreate('same', null, overwrite: false);
      final loadedB = await b.loadOrCreate('same', null, overwrite: false);
      expect(loadedA.metadata['from'], 'a');
      expect(loadedB.metadata['from'], 'b');

      await a.delete('same');
      expect(await a.exist('same'), isFalse);
      expect(await b.exist('same'), isTrue);
      await b.delete('same');
    });
  });
}
