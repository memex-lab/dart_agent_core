import 'dart:io';

/// Native (`dart:io`) implementation of the filesystem helpers.

/// The platform-specific path separator (`/` on POSIX, `\` on Windows).
String get fsPathSeparator => Platform.pathSeparator;

/// Returns the absolute path for [path].
String fsAbsolutePath(String path) => File(path).absolute.path;

/// Whether a directory exists at [path].
bool fsDirectoryExistsSync(String path) => Directory(path).existsSync();

/// Whether a file exists at [path] (synchronous).
bool fsFileExistsSync(String path) => File(path).existsSync();

/// Whether a file exists at [path].
Future<bool> fsFileExists(String path) => File(path).exists();

/// Reads the entire file at [path] as a UTF-8 string.
Future<String> fsReadAsString(String path) => File(path).readAsString();

/// Recursively finds every file named [fileName] under [rootPath], returning
/// their absolute paths. Entries deeper than [maxDepth] (relative to the root)
/// are skipped.
Future<List<String>> fsFindFiles(
  String rootPath,
  String fileName, {
  int maxDepth = 6,
}) async {
  final root = Directory(rootPath);
  if (!root.existsSync()) return const [];
  final rootAbsolute = root.absolute.path;
  final results = <String>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    if (_basename(entity.path) != fileName) continue;
    if (_relativeDepth(rootAbsolute, entity.absolute.path) > maxDepth) continue;
    results.add(entity.absolute.path);
  }
  return results;
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/');
  return parts.isEmpty ? normalized : parts.last;
}

int _relativeDepth(String root, String path) {
  final normalizedRoot = root.replaceAll('\\', '/');
  final normalizedPath = path.replaceAll('\\', '/');
  if (!normalizedPath.startsWith(normalizedRoot)) return 0;
  final rootSegments = normalizedRoot
      .split('/')
      .where((e) => e.isNotEmpty)
      .length;
  final pathSegments = normalizedPath
      .split('/')
      .where((e) => e.isNotEmpty)
      .length;
  return pathSegments - rootSegments;
}
