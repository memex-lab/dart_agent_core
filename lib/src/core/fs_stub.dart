/// Web stub for the filesystem helpers.
///
/// The browser has no filesystem, so lookups report "not found", reads throw
/// [UnsupportedError], and path helpers operate on plain strings. Features that
/// depend on the filesystem (directory-mode skills, JavaScript script
/// execution, file-based state storage) are therefore inert on the web rather
/// than failing to compile.
library;

/// The path separator used by the web stub (always `/`).
String get fsPathSeparator => '/';

/// Returns [path] unchanged; the web has no notion of an absolute path.
String fsAbsolutePath(String path) => path;

/// Always `false` on the web.
bool fsDirectoryExistsSync(String path) => false;

/// Always `false` on the web.
bool fsFileExistsSync(String path) => false;

/// Always resolves to `false` on the web.
Future<bool> fsFileExists(String path) async => false;

/// Always throws [UnsupportedError]; there is no filesystem on the web.
Future<String> fsReadAsString(String path) {
  throw UnsupportedError(
    'Reading files is not supported on the web platform (path: $path).',
  );
}

/// Always returns an empty list on the web.
Future<List<String>> fsFindFiles(
  String rootPath,
  String fileName, {
  int maxDepth = 6,
}) async => const [];
