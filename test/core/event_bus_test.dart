import 'dart:async';

import 'package:dart_agent_core/src/core/event_bus.dart';
import 'package:test/test.dart';

class _TestEvent extends Event {}

void main() {
  test('drops async events scheduled before close', () async {
    final bus = EventBus();
    final events = <_TestEvent>[];
    final sub = bus.on<_TestEvent>().listen(events.add);

    bus.publish(_TestEvent());
    bus.close();

    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
    await sub.cancel();
  });

  test('close is idempotent and publish after close is ignored', () {
    final bus = EventBus();

    bus.close();

    expect(bus.close, returnsNormally);
    expect(() => bus.publish(_TestEvent()), returnsNormally);
    expect(() => bus.publish(_TestEvent(), sync: true), returnsNormally);
  });
}
