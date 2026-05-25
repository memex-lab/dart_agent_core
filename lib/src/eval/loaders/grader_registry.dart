import '../graders/grader.dart';

/// Builds a [Grader] instance from a JSON config blob. Each demo /
/// application registers one factory per grader-name; the loader uses
/// the registry to materialize graders referenced from data files.
typedef GraderFactoryFunction = Grader Function(Map<String, dynamic> config);

/// Maps a grader name (as it appears in JSONL/JSON files) to a factory
/// that can construct an actual [Grader] from a config map.
///
/// Usage:
/// ```dart
/// final reg = GraderRegistry();
/// reg.register('answer_correctness',
///   (cfg) => AnswerCorrectnessGrader(expected: cfg['expected'] as num));
/// ```
class GraderRegistry {
  final Map<String, GraderFactoryFunction> _factories = {};

  /// Register a factory for [name]. Overwrites any prior registration
  /// of the same name.
  void register(String name, GraderFactoryFunction factory) {
    _factories[name] = factory;
  }

  /// Build a grader by [name] using [config]. Throws if [name] is not
  /// registered.
  Grader build(String name, Map<String, dynamic> config) {
    final f = _factories[name];
    if (f == null) {
      throw StateError(
        'Grader "$name" is not registered. '
        'Known graders: ${_factories.keys.toList()}',
      );
    }
    return f(config);
  }

  /// Returns true if [name] has a registered factory.
  bool contains(String name) => _factories.containsKey(name);

  /// Returns all registered names. Order is insertion order.
  Iterable<String> get registeredNames => _factories.keys;
}
