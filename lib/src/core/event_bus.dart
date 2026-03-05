import 'dart:async';
import 'package:uuid/uuid.dart';

/// Base class for all events in the system.
abstract class Event {
  final String id = Uuid().v4();
}

/// A simple EventBus that supports both Publish/Subscribe and Request/Response patterns.
class EventBus {
  final StreamController<Event> _streamController = StreamController.broadcast(
    sync: true,
  );
  final Map<Type, Future<dynamic> Function(Event)> _requestHandlers = {};

  /// Publishes an event to all subscribers.
  /// [sync] determines whether the event is fired synchronously or asynchronously.
  /// - If [sync] is true, listeners are notified immediately.
  /// - If [sync] is false (default), notification is scheduled as a microtask.
  void publish(Event event, {bool sync = false}) {
    if (sync) {
      _streamController.add(event);
    } else {
      Future.microtask(() => _streamController.add(event));
    }
  }

  /// Listens for events of type [T].
  Stream<T> on<T extends Event>() {
    if (T == Event) {
      return _streamController.stream.cast<T>();
    }
    return _streamController.stream.where((event) => event is T).cast<T>();
  }

  /// Registers a handler for a specific event type [T] that returns a result of type [R].
  /// Only one handler can be registered per event type.
  void registerRequestHandler<T extends Event, R>(
    Future<R> Function(T) handler,
  ) {
    if (_requestHandlers.containsKey(T)) {
      throw Exception(
        'Request handler for event type $T is already registered.',
      );
    }
    _requestHandlers[T] = (event) async {
      return await handler(event as T);
    };
  }

  /// Sends a request event of type [Event] and awaits a result of type [R].
  /// The event type must have a registered handler.
  /// If [orElse] is provided, it will be called if no handler is registered immediately (non-blocking).
  /// If [orElse] is NOT provided and no handler is registered, it will throw an exception immediately.
  Future<R> request<R>(Event event, {R Function()? orElse}) async {
    var handler = _requestHandlers[event.runtimeType];

    if (handler != null) {
      final result = await handler(event);
      return result as R;
    }

    if (orElse != null) {
      return orElse();
    }

    throw Exception(
      'No request handler registered for event type: ${event.runtimeType}',
    );
  }

  /// Closes the event bus.
  void close() {
    _streamController.close();
    _requestHandlers.clear();
  }
}
