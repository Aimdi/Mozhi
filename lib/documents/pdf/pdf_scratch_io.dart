import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mozhi/documents/pdf/pdf_scratch.dart';
import 'package:path_provider/path_provider.dart';

/// [PdfScratch] in `<cache>/pdf_pages/` (`getTemporaryDirectory()`: the
/// app's private cache, not backed up). Files left behind by an app that
/// ended mid-way are deleted the next time one is written.
PdfScratch defaultPdfScratch() => FolderPdfScratch(_cacheFolder);

Future<Directory> _cacheFolder() async {
  final cache = await getTemporaryDirectory();
  return Directory('${cache.path}${Platform.pathSeparator}pdf_pages');
}

/// [PdfScratch] in the folder its constructor's function gives.
class FolderPdfScratch implements PdfScratch {
  new(this._folder, {Random? random}) : _random = random ?? Random.secure();

  final Future<Directory> Function() _folder;
  final Random _random;

  /// Files older than this are leftovers.
  static const maxAge = Duration(hours: 1);

  @override
  Future<String> write(Uint8List bytes) async {
    final path = await newPath();
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  @override
  Future<String> newPath() async {
    final folder = await _folder();
    await folder.create(recursive: true);
    await _sweep(folder);
    final name = [
      for (var i = 0; i < 16; i++) _random.nextInt(256).toRadixString(16),
    ].join();
    return '${folder.path}${Platform.pathSeparator}$name.pdf';
  }

  @override
  Future<Uint8List> take(String path) async {
    final file = File(path);
    try {
      return await file.readAsBytes();
    } finally {
      await delete(path);
    }
  }

  @override
  Future<void> delete(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone (the platform deletes an opened copy itself).
    }
  }

  static Future<void> _sweep(Directory folder) async {
    final now = DateTime.now();
    try {
      await for (final entry in folder.list()) {
        if (entry is! File) continue;
        try {
          if (now.difference(entry.lastModifiedSync()) > maxAge) {
            await entry.delete();
          }
        } on FileSystemException {
          // Gone meanwhile.
        }
      }
    } on FileSystemException {
      // The folder cannot be listed: nothing to sweep.
    }
  }
}
