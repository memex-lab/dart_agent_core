import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';
import 'package:test/test.dart';

import '_helpers.dart';

ModelConfig _cfg([String model = 'fake-model']) =>
    ModelConfig(model: model, temperature: 0.7);

// UserMessage.text(...) bakes a fresh DateTime.now() timestamp on each
// call, which gets included in toJson() and therefore in the request
// hash. Tests that need stable hashes use [_msg] which fixes the
// timestamp.
UserMessage _msg(String text, {int timestamp = 1}) =>
    UserMessage([TextPart(text)], timestamp: timestamp);

void main() {
  group('Sha256LLMRequestHash', () {
    test('same inputs → same hash', () {
      const h = Sha256LLMRequestHash();
      final a = h.compute(
        messages: [_msg('hi')],
        tools: null,
        modelConfig: _cfg(),
      );
      final b = h.compute(
        messages: [_msg('hi')],
        tools: null,
        modelConfig: _cfg(),
      );
      expect(a, b);
    });

    test('different model → different hash', () {
      const h = Sha256LLMRequestHash();
      final a = h.compute(
        messages: [_msg('hi')],
        tools: null,
        modelConfig: _cfg('A'),
      );
      final b = h.compute(
        messages: [_msg('hi')],
        tools: null,
        modelConfig: _cfg('B'),
      );
      expect(a, isNot(b));
    });

    test('different message → different hash', () {
      const h = Sha256LLMRequestHash();
      final a = h.compute(
        messages: [_msg('one')],
        tools: null,
        modelConfig: _cfg(),
      );
      final b = h.compute(
        messages: [_msg('two')],
        tools: null,
        modelConfig: _cfg(),
      );
      expect(a, isNot(b));
    });

    test('jsonOutput flag flips hash', () {
      const h = Sha256LLMRequestHash();
      final a = h.compute(
        messages: [_msg('hi')],
        tools: null,
        modelConfig: _cfg(),
        jsonOutput: false,
      );
      final b = h.compute(
        messages: [_msg('hi')],
        tools: null,
        modelConfig: _cfg(),
        jsonOutput: true,
      );
      expect(a, isNot(b));
    });

    test('timestamp is stripped by default — UserMessages with different '
        'timestamps still hash equal', () {
      const h = Sha256LLMRequestHash();
      final um1 = UserMessage([TextPart('hi')], timestamp: 1);
      final um2 = UserMessage([TextPart('hi')], timestamp: 999);
      final h1 = h.compute(messages: [um1], tools: null, modelConfig: _cfg());
      final h2 = h.compute(messages: [um2], tools: null, modelConfig: _cfg());
      expect(h1, h2);
    });

    test('stripMessageKeys adds extra strip keys on top of defaults', () {
      // App embeds a 'trace_id' that should also be stripped.
      const stripped = Sha256LLMRequestHash(stripMessageKeys: {'metadata'});
      const baseline = Sha256LLMRequestHash();
      final um1 = UserMessage(
        [TextPart('hi')],
        timestamp: 1,
        metadata: const {'trace_id': 'abc'},
      );
      final um2 = UserMessage(
        [TextPart('hi')],
        timestamp: 1,
        metadata: const {'trace_id': 'xyz'},
      );
      // Default hashing keeps metadata → different trace_ids → different hash.
      expect(
        baseline.compute(messages: [um1], tools: null, modelConfig: _cfg()),
        isNot(
          baseline.compute(messages: [um2], tools: null, modelConfig: _cfg()),
        ),
      );
      // With metadata stripped → equal hash.
      expect(
        stripped.compute(messages: [um1], tools: null, modelConfig: _cfg()),
        stripped.compute(messages: [um2], tools: null, modelConfig: _cfg()),
      );
    });

    test('different trialSalt → different hash (per-trial cache axis)', () {
      const h = Sha256LLMRequestHash();
      final args = {
        'messages': [_msg('hi')],
        'tools': null,
        'modelConfig': _cfg(),
      };
      final a = h.compute(
        messages: args['messages'] as List<LLMMessage>,
        tools: args['tools'] as List<Tool>?,
        modelConfig: args['modelConfig'] as ModelConfig,
        trialSalt: 'run_x/task#0',
      );
      final b = h.compute(
        messages: args['messages'] as List<LLMMessage>,
        tools: args['tools'] as List<Tool>?,
        modelConfig: args['modelConfig'] as ModelConfig,
        trialSalt: 'run_x/task#1',
      );
      final none = h.compute(
        messages: args['messages'] as List<LLMMessage>,
        tools: args['tools'] as List<Tool>?,
        modelConfig: args['modelConfig'] as ModelConfig,
      );
      expect(a, isNot(b));
      expect(a, isNot(none));
      expect(b, isNot(none));
    });

    test('same trialSalt → same hash', () {
      const h = Sha256LLMRequestHash();
      final a = h.compute(
        messages: [_msg('hi')],
        tools: null,
        modelConfig: _cfg(),
        trialSalt: 'run_x/task#0',
      );
      final b = h.compute(
        messages: [_msg('hi')],
        tools: null,
        modelConfig: _cfg(),
        trialSalt: 'run_x/task#0',
      );
      expect(a, b);
    });
  });

  group('InMemoryRecordingStore', () {
    test('put/get round-trips a recording', () async {
      final store = InMemoryRecordingStore();
      await store.put('h1', textReply('hello'));
      final got = await store.get('h1');
      expect(got, isNotNull);
      expect(got!.textOutput, 'hello');
    });

    test('miss returns null', () async {
      final store = InMemoryRecordingStore();
      expect(await store.get('nope'), isNull);
    });
  });

  group('FileRecordingStore', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rec_store_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('put then flush then get reads back the same response', () async {
      final store = FileRecordingStore(tmp);
      await store.put('abcd1234ef', textReply('hello-disk'));
      await store.flush();
      // Re-open to ensure no in-memory caching is helping.
      final reopened = FileRecordingStore(tmp);
      final got = await reopened.get('abcd1234ef');
      expect(got, isNotNull);
      expect(got!.textOutput, 'hello-disk');
    });

    test('uses two-level prefix layout under rootDir', () async {
      final store = FileRecordingStore(tmp);
      await store.put('abcdef00112233', textReply('layout'));
      await store.flush();
      final f = File('${tmp.path}/ab/cd/abcdef00112233.json');
      expect(await f.exists(), isTrue);
    });
  });

  group('RecordingLLMClient', () {
    test('forwards generate() to inner and persists the response', () async {
      final inner = FakeLLMClient([textReply('rec1')]);
      final store = InMemoryRecordingStore();
      final client = RecordingLLMClient(inner: inner, store: store);
      final m = _msg('hi');
      final reply = await client.generate([m], modelConfig: _cfg());
      expect(reply.textOutput, 'rec1');
      expect(inner.generateCalls, 1);

      final hash = const Sha256LLMRequestHash().compute(
        messages: [m],
        tools: null,
        modelConfig: _cfg(),
      );
      final cached = await store.get(hash);
      expect(cached, isNotNull);
      expect(cached!.textOutput, 'rec1');
    });

    test('rate gate.acquire() is awaited before each generate()', () async {
      final inner = FakeLLMClient([textReply('a'), textReply('b')]);
      final gate = _CountingRateLimitGate();
      final client = RecordingLLMClient(
        inner: inner,
        store: InMemoryRecordingStore(),
        rateLimitGate: gate,
      );
      await client.generate([_msg('one', timestamp: 1)], modelConfig: _cfg());
      await client.generate([_msg('two', timestamp: 2)], modelConfig: _cfg());
      expect(gate.acquireCalls, 2);
    });
  });

  group('ReplayLLMClient', () {
    test('strict replay hit returns cached without calling fallback', () async {
      final inner = FakeLLMClient([textReply('SHOULD-NOT-CALL')]);
      final store = InMemoryRecordingStore();
      final m = _msg('hi');
      final hash = const Sha256LLMRequestHash().compute(
        messages: [m],
        tools: null,
        modelConfig: _cfg(),
      );
      await store.put(hash, textReply('cached-reply'));

      final client = ReplayLLMClient(
        store: store,
        fallback: inner,
        strictReplay: true,
      );
      final reply = await client.generate([m], modelConfig: _cfg());
      expect(reply.textOutput, 'cached-reply');
      expect(inner.generateCalls, 0);
    });

    test('strict replay miss throws RecordingNotFoundException', () async {
      final client = ReplayLLMClient(store: InMemoryRecordingStore());
      await expectLater(
        client.generate([_msg('miss')], modelConfig: _cfg()),
        throwsA(isA<RecordingNotFoundException>()),
      );
    });

    test('non-strict miss falls back to inner client', () async {
      final inner = FakeLLMClient([textReply('live-reply')]);
      final client = ReplayLLMClient(
        store: InMemoryRecordingStore(),
        fallback: inner,
        strictReplay: false,
      );
      final reply = await client.generate([_msg('miss')], modelConfig: _cfg());
      expect(reply.textOutput, 'live-reply');
      expect(inner.generateCalls, 1);
    });

    test('rate gate.acquire() called only on fallback path', () async {
      final inner = FakeLLMClient([textReply('live')]);
      final gate = _CountingRateLimitGate();
      final store = InMemoryRecordingStore();
      final mA = _msg('A', timestamp: 1);
      final hashA = const Sha256LLMRequestHash().compute(
        messages: [mA],
        tools: null,
        modelConfig: _cfg(),
      );
      await store.put(hashA, textReply('cached-A'));

      final client = ReplayLLMClient(
        store: store,
        fallback: inner,
        strictReplay: false,
        rateLimitGate: gate,
      );
      // Hit: gate NOT called.
      await client.generate([mA], modelConfig: _cfg());
      expect(gate.acquireCalls, 0);
      // Miss: gate IS called.
      await client.generate([_msg('B', timestamp: 2)], modelConfig: _cfg());
      expect(gate.acquireCalls, 1);
    });

    test(
      'stream() synthesizes a one-chunk stream from the recording',
      () async {
        final store = InMemoryRecordingStore();
        final m = _msg('hi');
        final hash = const Sha256LLMRequestHash().compute(
          messages: [m],
          tools: null,
          modelConfig: _cfg(),
        );
        await store.put(hash, textReply('streamed'));
        final client = ReplayLLMClient(store: store);
        final s = await client.stream([m], modelConfig: _cfg());
        final chunks = await s.toList();
        expect(chunks, hasLength(1));
        expect(chunks.first.modelMessage?.textOutput, 'streamed');
      },
    );
  });

  group('Per-trial salt preserves non-determinism', () {
    test('RecordingLLMClient: each trial-salted client writes its own '
        'cache entry for the same logical request', () async {
      // Inner returns a different reply each call so we can prove that
      // distinct trials capture distinct responses.
      final inner = FakeLLMClient([
        textReply('trial-0'),
        textReply('trial-1'),
        textReply('trial-2'),
      ]);
      final store = InMemoryRecordingStore();
      final base = RecordingLLMClient(inner: inner, store: store);

      final m = _msg('same prompt across trials');
      for (var i = 0; i < 3; i++) {
        final perTrial = base.withTrialSalt('run_x/task#$i');
        final r = await perTrial.generate([m], modelConfig: _cfg());
        expect(r.textOutput, 'trial-$i');
      }

      // Three distinct hashes ⇒ three distinct cache entries.
      final hasher = const Sha256LLMRequestHash();
      final responses = <String?>[];
      for (var i = 0; i < 3; i++) {
        final hash = hasher.compute(
          messages: [m],
          tools: null,
          modelConfig: _cfg(),
          trialSalt: 'run_x/task#$i',
        );
        final cached = await store.get(hash);
        responses.add(cached?.textOutput);
      }
      expect(responses, ['trial-0', 'trial-1', 'trial-2']);
    });

    test('ReplayLLMClient: salted clients hit their own cache slot, not '
        'a peer trial\'s slot', () async {
      final hasher = const Sha256LLMRequestHash();
      final store = InMemoryRecordingStore();
      final m = _msg('same prompt across trials');

      // Pre-record three distinct responses keyed by trial salt.
      for (var i = 0; i < 3; i++) {
        final hash = hasher.compute(
          messages: [m],
          tools: null,
          modelConfig: _cfg(),
          trialSalt: 'run_x/task#$i',
        );
        await store.put(hash, textReply('trial-$i-cached'));
      }

      // Replay: each trial gets its own response.
      final base = ReplayLLMClient(store: store, strictReplay: true);
      for (var i = 0; i < 3; i++) {
        final perTrial = base.withTrialSalt('run_x/task#$i');
        final r = await perTrial.generate([m], modelConfig: _cfg());
        expect(r.textOutput, 'trial-$i-cached');
      }
    });

    test('recordings made in run A can be replayed by run B (cacheSalt is '
        'run-name independent)', () async {
      final inner = FakeLLMClient([textReply('rec-trial-0')]);
      final store = InMemoryRecordingStore();
      // The salt the env should use: derived from trial.cacheSalt,
      // NOT trial.id.toString(). Same task+trialIndex gives the same
      // salt regardless of which run wraps around them.
      const salt = 'task_a#0';
      final recorder = RecordingLLMClient(
        inner: inner,
        store: store,
        trialSalt: salt,
      );
      await recorder.generate([_msg('p')], modelConfig: _cfg());

      // Different "run", same task+trialIndex → same salt → cache hit.
      final replayer = ReplayLLMClient(
        store: store,
        strictReplay: true,
        trialSalt: salt,
      );
      final replayed = await replayer.generate([
        _msg('p'),
      ], modelConfig: _cfg());
      expect(replayed.textOutput, 'rec-trial-0');
    });

    test(
      'without per-trial salt the cache collapses (regression guard)',
      () async {
        // This documents the alternate behavior: when the env does NOT
        // pass a trial salt, every trial maps to the same hash, so the
        // store sees N puts for the same key — by design, cache is
        // shared (judges, ad-hoc analysis, etc.).
        final inner = FakeLLMClient([textReply('first'), textReply('second')]);
        final store = InMemoryRecordingStore();
        final client = RecordingLLMClient(inner: inner, store: store);
        final m = _msg('shared prompt');
        await client.generate([m], modelConfig: _cfg());
        await client.generate([m], modelConfig: _cfg());
        final hash = const Sha256LLMRequestHash().compute(
          messages: [m],
          tools: null,
          modelConfig: _cfg(),
        );
        // Last write wins: second response overwrote the first.
        final cached = await store.get(hash);
        expect(cached?.textOutput, 'second');
      },
    );
  });

  group('RpmRateLimitGate', () {
    test('allows up to N immediate acquires from the initial bucket', () async {
      final gate = RpmRateLimitGate(requestsPerMinute: 60);
      final start = DateTime.now();
      for (var i = 0; i < 5; i++) {
        await gate.acquire();
      }
      expect(
        DateTime.now().difference(start),
        lessThan(const Duration(milliseconds: 200)),
      );
    });

    test('throttles when bucket is empty', () async {
      final gate = RpmRateLimitGate(requestsPerMinute: 6);
      // Drain initial bucket of 6.
      for (var i = 0; i < 6; i++) {
        await gate.acquire();
      }
      // 7th acquire shouldn't return within 200ms (refill rate is 6/min).
      final completed = <bool>[];
      final pending = gate.acquire().then((_) => completed.add(true));
      await Future.delayed(const Duration(milliseconds: 200));
      expect(completed, isEmpty);
      // Don't await `pending`; let it leak (the test process exits).
      pending.ignore();
    });
  });

  group('TpmRateLimitGate', () {
    test('allows multiple small acquires until budget is spent', () async {
      // 60_000 tokens/min = 1000 tokens/sec.
      final gate = TpmRateLimitGate(tokensPerMinute: 60000);
      final start = DateTime.now();
      for (var i = 0; i < 5; i++) {
        await gate.acquire(estimatedTokens: 100);
      }
      expect(
        DateTime.now().difference(start),
        lessThan(const Duration(milliseconds: 200)),
      );
    });

    test('queues request that exceeds remaining budget', () async {
      final gate = TpmRateLimitGate(tokensPerMinute: 6);
      await gate.acquire(estimatedTokens: 6);
      final completed = <bool>[];
      final pending = gate
          .acquire(estimatedTokens: 1)
          .then((_) => completed.add(true));
      await Future.delayed(const Duration(milliseconds: 200));
      expect(completed, isEmpty);
      pending.ignore();
    });
  });

  group('NoopRateLimitGate', () {
    test('returns immediately', () async {
      const gate = NoopRateLimitGate();
      final start = DateTime.now();
      for (var i = 0; i < 100; i++) {
        await gate.acquire(estimatedTokens: 1000);
      }
      expect(
        DateTime.now().difference(start),
        lessThan(const Duration(milliseconds: 50)),
      );
    });
  });
}

class _CountingRateLimitGate implements RateLimitGate {
  int acquireCalls = 0;
  @override
  Future<void> acquire({int estimatedTokens = 0}) async {
    acquireCalls++;
  }
}
