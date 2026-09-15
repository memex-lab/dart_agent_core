import 'package:dio/dio.dart';

/// Whether [error] is a Dio cancellation (user abort / CancelToken).
///
/// Cancelled requests must not be retried; Claude/Bedrock must rethrow the
/// original [DioException] so [StatefulAgent.isCancelled] can recognize it.
bool isLlmRequestCancelled(Object error) {
  return error is DioException && CancelToken.isCancel(error);
}
