enum AgentExceptionCode {
  unknown,
  loopDetection,
  resumeFailed,
  stopByController,
  cancelled,
}

class AgentException implements Exception {
  final AgentExceptionCode code;
  final String message;
  final dynamic error;
  AgentException(this.code, this.message, {this.error});

  @override
  String toString() {
    return 'AgentException(code: $code, message: $message, error: $error)';
  }
}
