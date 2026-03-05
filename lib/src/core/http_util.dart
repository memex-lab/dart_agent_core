import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

void configureProxy(Dio client, String? proxyUrl) {
  if (proxyUrl != null) {
    (client.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final httpClient = HttpClient();
      final uri = Uri.parse(proxyUrl);

      // Configure proxy connection
      httpClient.findProxy = (url) {
        return "PROXY ${uri.host}:${uri.port}";
      };

      // Handle authentication if provided
      if (uri.userInfo.isNotEmpty) {
        final parts = uri.userInfo.split(':');
        if (parts.length == 2) {
          final user = parts[0];
          final pass = parts[1];
          // Add credentials for any realm
          httpClient.addProxyCredentials(
            uri.host,
            uri.port,
            '', // empty realm means any/default
            HttpClientBasicCredentials(user, pass),
          );
          // Also enable authenticateProxy callback to allow the retry
          httpClient.authenticateProxy = (host, port, scheme, realm) async =>
              true;
        }
      }
      return httpClient;
    };
  }
}
