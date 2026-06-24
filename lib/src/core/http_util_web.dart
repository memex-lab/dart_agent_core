import 'package:dio/dio.dart';

/// Web stub for proxy configuration.
///
/// Browsers do not allow applications to configure an HTTP proxy at the
/// request level (the user agent / OS controls proxying), so this is a no-op.
/// It exists to keep the [configureProxy] API available on the web platform.
void configureProxy(Dio client, String? proxyUrl) {
  // Intentionally empty: proxy configuration is not supported on the web.
}
