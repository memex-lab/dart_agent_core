import 'dart:async';
import 'package:dart_agent_core/src/core/event_bus.dart';

/// A flexible controller based on EventBus.
/// It wraps an [EventBus] and provides helper methods to interact with it.
class AgentController {
  final EventBus eventBus;

  AgentController({EventBus? eventBus}) : eventBus = eventBus ?? EventBus();

  /// Publishes an event (notification).
  void publish(Event event) {
    eventBus.publish(event);
  }

  /// Listens to events of type [T].
  Stream<T> listen<T extends Event>() {
    return eventBus.on<T>();
  }

  /// Sends a request and waits for a response.
  /// If no handler is registered, [defaultValue] is returned immediately (non-blocking).
  Future<R> request<T extends Event, R>(T event, R defaultValue) {
    return eventBus.request<R>(event, orElse: () => defaultValue);
  }

  // --- Convenience Registration Helpers ---

  void on<T extends Event>(void Function(T) handler) {
    eventBus.on<T>().listen(handler);
  }

  void registerHandler<T extends Event, R>(Future<R> Function(T) handler) {
    eventBus.registerRequestHandler<T, R>(handler);
  }

  /// Closes the underlying event bus.
  void close() {
    eventBus.close();
  }
}
