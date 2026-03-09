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

  Tool({
    required this.name,
    required this.description,
    required this.parameters,
    this.executable,
    this.namedParameters = const [],
  });
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'description': description,
      'parameters': parameters,
      'namedParameters': namedParameters,
    };
  }
}
