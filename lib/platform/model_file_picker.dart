import 'dart:async';
import 'dart:io' show File, FileMode, FileSystemException;

import 'package:flutter/services.dart';
import 'package:llama_engine/llama_engine.dart' show LlamaImportSource;
import 'package:mozhi/offline/data/offline_model_file_picker.dart';
import 'package:mozhi/platform/android_device.dart';
import 'package:mozhi/platform/free_space.dart' show storageChannelName;
import 'package:whisper_speech/whisper_speech.dart' show WhisperImportSource;

/// A file the user picked to import a model from (on-device AI, voice):
/// read where it is ([copyTo]), so the model managers copy it straight
/// into their staging folder after checking its name, size and the free
/// space ([LlamaImportSource], [WhisperImportSource]).
final class PickedModelFile implements LlamaImportSource, WhisperImportSource {
  const new({
    required this.name,
    required this.length,
    required this._copy,
    this.path,
  });

  /// A picked file with a local [path] (the file picker's, off Android).
  factory local(String path) {
    final file = File(path);
    int? length;
    try {
      length = file.lengthSync();
    } on FileSystemException {
      length = null;
    }
    return PickedModelFile(
      name: file.uri.pathSegments.lastOrNull ?? path,
      length: length,
      path: path,
      copy: (destination, maxBytes) => _copyLocal(file, destination, maxBytes),
    );
  }

  @override
  final String name;

  @override
  final int? length;

  /// Its local path, when the platform gave one (null for an Android
  /// document, which is only read through [copyTo]).
  final String? path;

  final Future<int> Function(File destination, int maxBytes) _copy;

  @override
  Future<int> copyTo(File destination, {required int maxBytes}) =>
      _copy(destination, maxBytes);

  static Future<int> _copyLocal(File source, File destination, int max) async {
    final sink = destination.openWrite(mode: FileMode.writeOnly);
    var written = 0;
    try {
      await for (final chunk in source.openRead()) {
        final room = max + 1 - written;
        if (room <= 0) break;
        final part = chunk.length > room ? chunk.sublist(0, room) : chunk;
        sink.add(part);
        written += part.length;
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return written;
  }

  @override
  String toString() => 'PickedModelFile($name, $length)';
}

/// Lets the user pick model files to import (several, any type) without
/// copying them first.
///
/// On Android it asks `DeviceStoragePlugin.kt` ([storageChannelName]):
/// the system document picker, whose files are then read in place
/// ([PickedModelFile.copyTo]: `copyFile` streams the document straight
/// into the model's staging folder). The `file_picker` plugin would first
/// copy every picked file into the app's cache (a few GB for an on-device
/// AI model), before the app could check it or the free space.
///
/// Elsewhere, or when the platform side is missing, it falls back to
/// [fallback] (`file_picker`, local paths; [clearCopies] removes its
/// copies after the import).
class ModelFilePicker {
  new({
    MethodChannel? channel,
    bool? isAndroid,
    this.fallback = const OfflineModelFilePicker(),
  }) : _channel = channel ?? const MethodChannel(storageChannelName),
       _isAndroid = isAndroid ?? runsOnAndroid;

  final MethodChannel _channel;
  final bool _isAndroid;

  /// The file picker off Android.
  final OfflineModelFilePicker fallback;

  bool _usedFallback = false;

  /// The picked files (empty when cancelled). [onCopying] runs when the
  /// fallback picker starts copying files into the cache.
  Future<List<PickedModelFile>> pick({void Function()? onCopying}) async {
    if (_isAndroid) {
      try {
        final picked = await _channel.invokeListMethod<Object?>('pickFiles');
        return [
          for (final entry in picked ?? const <Object?>[]) ?_document(entry),
        ];
      } on MissingPluginException {
        // An engine without the plugin: the file picker below.
      }
    }
    _usedFallback = true;
    final paths = await fallback.pick(onCopying: onCopying);
    return [for (final path in paths) PickedModelFile.local(path)];
  }

  /// Removes the copies the fallback picker made (nothing to do for
  /// documents read in place).
  Future<void> clearCopies() async {
    if (!_usedFallback) return;
    _usedFallback = false;
    await fallback.clearCopies();
  }

  PickedModelFile? _document(Object? entry) {
    if (entry is! Map<Object?, Object?>) return null;
    final uri = entry['uri'];
    final name = entry['name'];
    final size = entry['size'];
    if (uri is! String || name is! String) return null;
    return PickedModelFile(
      name: name,
      length: size is int && size >= 0 ? size : null,
      copy: (destination, maxBytes) =>
          _copyDocument(uri, destination, maxBytes),
    );
  }

  Future<int> _copyDocument(String uri, File destination, int maxBytes) async {
    try {
      final written = await _channel.invokeMethod<int>('copyFile', {
        'uri': uri,
        'path': destination.path,
        'maxBytes': maxBytes,
      });
      if (written == null) {
        throw FileSystemException('The document was not copied', uri);
      }
      return written;
    } on PlatformException catch (error) {
      throw FileSystemException(error.message ?? error.code, uri);
    }
  }
}
