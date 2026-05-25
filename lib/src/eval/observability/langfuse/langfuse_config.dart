import 'dart:io';

/// Langfuse 客户端配置。
///
/// 字段语义对齐 Langfuse 官方 SDK：
///   - [host] 默认 `https://cloud.langfuse.com`，自托管时改成你的地址
///   - [publicKey] / [secretKey] 用于 HTTP Basic auth
///   - [environment] 透传到每个 trace/observation/score 的 `environment`
///     字段（默认 `default`），用来在 dashboard 上区分 dev / staging / prod
///   - [release] / [version] 可选标识，方便在 langfuse 上做 A/B 对比
///
/// 工厂方法 [LangfuseConfig.fromEnv] 从环境变量读取，方便 CI 接入。
class LangfuseConfig {
  /// 形如 `https://cloud.langfuse.com` 或 `https://langfuse.your-domain.com`。
  /// 末尾不需要带 `/api/public/ingestion`。
  final String host;
  final String publicKey;
  final String secretKey;

  /// 默认 `default`。Langfuse 服务端会校验匹配 `^[a-z0-9-_]{1,40}$`。
  final String environment;

  final String? release;
  final String? version;

  /// 批量发送阈值：达到这么多 event 就立刻 flush。默认 50，对齐
  /// 官方 SDK 的 `flushAt`。
  final int flushAt;

  /// 时间阈值：哪怕没攒够也最长等这么久就 flush。默认 1 秒，对齐
  /// 官方 SDK 的 `flushInterval`。
  final Duration flushInterval;

  /// 单次 HTTP 失败的最大重试次数（指数退避）。默认 3。
  final int maxRetries;

  /// 单次请求超时。默认 10 秒。
  final Duration requestTimeout;

  const LangfuseConfig({
    this.host = 'https://cloud.langfuse.com',
    required this.publicKey,
    required this.secretKey,
    this.environment = 'default',
    this.release,
    this.version,
    this.flushAt = 50,
    this.flushInterval = const Duration(seconds: 1),
    this.maxRetries = 3,
    this.requestTimeout = const Duration(seconds: 10),
  });

  /// 从环境变量读取：
  ///   - `LANGFUSE_HOST` (可选，默认 cloud)
  ///   - `LANGFUSE_PUBLIC_KEY` (必需)
  ///   - `LANGFUSE_SECRET_KEY` (必需)
  ///   - `LANGFUSE_ENVIRONMENT` (可选，默认 `default`)
  ///   - `LANGFUSE_RELEASE` / `LANGFUSE_VERSION` (可选)
  factory LangfuseConfig.fromEnv([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final pub = e['LANGFUSE_PUBLIC_KEY'];
    final sec = e['LANGFUSE_SECRET_KEY'];
    if (pub == null || pub.isEmpty || sec == null || sec.isEmpty) {
      throw StateError(
        'LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY are required in environment',
      );
    }
    return LangfuseConfig(
      host: e['LANGFUSE_HOST'] ?? 'https://cloud.langfuse.com',
      publicKey: pub,
      secretKey: sec,
      environment: e['LANGFUSE_ENVIRONMENT'] ?? 'default',
      release: e['LANGFUSE_RELEASE'],
      version: e['LANGFUSE_VERSION'],
    );
  }

  String get ingestionUrl =>
      '${host.replaceAll(RegExp(r'/$'), '')}/api/public/ingestion';
}
