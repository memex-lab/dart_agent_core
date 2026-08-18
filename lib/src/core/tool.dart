/// Tool parameter mode.
enum ToolParameterMode {
  /// Object parameter mode.
  /// Passes the decoded arguments Map directly to the executable.
  object,

  /// Function parameter mode.
  /// Uses Function.apply to dispatch positional and named parameters.
  function,
}

/// Defines a tool that can be executed by an agent.
///
/// A tool consists of a name, description, and a JSON Schema for its parameters.
/// It also contains an [executable] function that is called when the agent
/// decides to use this tool.
class Tool {
  final String name;
  final String description;
  final Map<String, dynamic> parameters; // JSON Schema
  final Function? executable;
  final List<String> namedParameters;
  final ToolParameterMode parameterMode;

  /// Optionally classifies a successfully returned value as a tool error.
  ///
  /// This is useful for tools that preserve a legacy return type while using
  /// sentinel values to report failures. Exceptions are always treated as
  /// errors independently of this callback.
  final bool Function(dynamic result)? resultIsError;

  Tool({
    required this.name,
    required this.description,
    required this.parameters,
    this.executable,
    this.namedParameters = const [],
    this.parameterMode = ToolParameterMode.function,
    this.resultIsError,
  });
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'description': description,
      'parameters': parameters,
      'namedParameters': namedParameters,
      'parameterMode': parameterMode.name,
    };
  }
}
