/// 工具参数模式枚举
enum ToolParameterMode {
  /// 对象参数模式
  /// 直接传递 decodedArgs Map 给 executable
  object,

  /// 函数参数模式
  /// 使用 Function.apply 分解位置参数和命名参数
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

  Tool({
    required this.name,
    required this.description,
    required this.parameters,
    this.executable,
    this.namedParameters = const [],
    this.parameterMode = ToolParameterMode.function,
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
