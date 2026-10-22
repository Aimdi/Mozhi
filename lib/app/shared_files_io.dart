import 'dart:io';

import 'package:mozhi/app/shared_files.dart';
import 'package:path_provider/path_provider.dart';

/// See [SharedFiles.take].
Future<SharedFile?> takeSharedFile(
  String token, {
  required bool keep,
  required DateTime now,
  Future<String> Function()? cacheDirectory,
}) async {
  final cache = cacheDirectory == null
      ? (await getTemporaryDirectory()).path
      : await cacheDirectory();
  final root = Directory(
    '$cache${Platform.pathSeparator}${SharedFiles.folder}',
  );
  if (!root.existsSync()) return null;
  _deleteExpired(root, keep: token, now: now);
  final folder = Directory('${root.path}${Platform.pathSeparator}$token');
  if (!folder.existsSync()) return null;
  final files = folder.listSync().whereType<File>().toList();
  if (files.isEmpty || files.first.lengthSync() > SharedFiles.maxBytes) {
    _delete(folder);
    return null;
  }
  final file = files.first;
  final bytes = await file.readAsBytes();
  final name = file.uri.pathSegments.last;
  if (!keep) {
    _delete(folder);
    return SharedFile(name: name, bytes: bytes);
  }
  return SharedFile(name: name, bytes: bytes, path: file.path);
}

/// Deletes the shared files older than [SharedFiles.maxAge] but [keep].
void _deleteExpired(
  Directory root, {
  required String keep,
  required DateTime now,
}) {
  for (final entry in root.listSync().whereType<Directory>()) {
    if (entry.uri.pathSegments.where((s) => s.isNotEmpty).last == keep) {
      continue;
    }
    final modified = entry.statSync().modified;
    if (now.difference(modified) > SharedFiles.maxAge) _delete(entry);
  }
}

void _delete(Directory folder) {
  try {
    folder.deleteSync(recursive: true);
  } on FileSystemException {
    // Left for the next clean-up (or the system's cache clean-up).
  }
}
