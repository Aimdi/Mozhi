import 'dart:math' as math;

import 'package:bergamot_translator/bergamot_translator.dart'
    show ModelInsufficientSpaceException;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:llama_engine/llama_engine.dart'
    show LlamaInsufficientSpaceException;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/android_device.dart';
import 'package:mozhi/platform/free_space_browser.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart'
    show TessdataInsufficientSpaceException;
import 'package:whisper_speech/whisper_speech.dart'
    show WhisperInsufficientSpaceException;

/// Name of the Android method channel of `DeviceStoragePlugin.kt`
/// (`freeBytes`, and the model file picker's `pickFiles` / `copyFile`).
const storageChannelName = 'io.github.aimdi.mozhi/storage';

/// The free storage the app may write its downloads to: on Android the
/// file system of a path (`StatFs`, default the app's files directory)
/// over the [storageChannelName] channel; in the web app what the
/// browser's storage quota leaves (`navigator.storage.estimate()`, when
/// the browser has it). Unknown (null) elsewhere (desktop tests) and when
/// the system cannot tell. Never throws.
///
/// Every model download checks it first (offline languages, text
/// recognition data, voice models, on-device AI models, dictionary packs,
/// phrasebooks; see [requiredFreeSpace]): the model managers take
/// [call] as their `freeSpace`.
class FreeSpace {
  new({
    MethodChannel? channel,
    bool? isAndroid,
    this._isWeb = kIsWeb,
    Future<int?> Function()? browser,
  }) : _channel = channel ?? const MethodChannel(storageChannelName),
       _isAndroid = isAndroid ?? runsOnAndroid,
       _browser = browser ?? browserStorageLeft;

  /// The app's (the platform files and the downloads use it).
  static FreeSpace instance = FreeSpace();

  final MethodChannel _channel;
  final bool _isAndroid;
  final bool _isWeb;
  final Future<int?> Function() _browser;

  /// Free bytes where [path] lives (Android; the files directory when
  /// null), or left in the browser's quota; null when unknown.
  Future<int?> availableBytes([String? path]) async {
    try {
      if (_isWeb) return await _browser();
      if (!_isAndroid) return null;
      final bytes = await _channel.invokeMethod<int>('freeBytes', {
        'path': ?path,
      });
      return bytes == null || bytes < 0 ? null : bytes;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on Object {
      return null;
    }
  }

  /// [availableBytes] of [path], the form the model managers take
  /// (`freeSpace: FreeSpace.instance.call`).
  Future<int?> call(String path) => availableBytes(path);
}

/// The smallest margin of free space a download keeps on top of its
/// bytes: 50 MiB, so the phone is never filled to the last byte.
const int freeSpaceMarginBytes = 50 << 20;

/// The free space writing [bytes] needs: the bytes plus a margin of 5 %,
/// at least [freeSpaceMarginBytes] (the model managers use the same rule).
int requiredFreeSpace(int bytes) =>
    bytes + math.max(freeSpaceMarginBytes, bytes ~/ 20);

/// Not enough free space for a download the app writes itself (dictionary
/// packs, starter phrasebooks): nothing was downloaded.
final class NotEnoughSpaceException implements Exception {
  const new({required this.requiredBytes, required this.availableBytes});

  /// Free bytes the download needs ([requiredFreeSpace]).
  final int requiredBytes;

  /// Free bytes there are.
  final int availableBytes;

  @override
  String toString() =>
      'NotEnoughSpaceException(needs $requiredBytes, $availableBytes free)';
}

/// Throws a [NotEnoughSpaceException] when [freeSpace] (default
/// [FreeSpace.instance]) has less room at [path] than writing [bytes]
/// needs ([requiredFreeSpace]). Unknown free space passes (the write
/// itself then fails on a full disk).
Future<void> ensureFreeSpace(
  int bytes, {
  FreeSpace? freeSpace,
  String? path,
}) async {
  if (bytes <= 0) return;
  final available = await (freeSpace ?? FreeSpace.instance).availableBytes(
    path,
  );
  final needed = requiredFreeSpace(bytes);
  if (available == null || available >= needed) return;
  throw NotEnoughSpaceException(
    requiredBytes: needed,
    availableBytes: available,
  );
}

/// How much free space a download or import that failed for lack of it
/// needed and had ([of] reads it from any model manager's exception).
@immutable
class SpaceShortfall {
  const new({required this.requiredBytes, required this.availableBytes});

  /// The shortfall [error] reports: a [NotEnoughSpaceException] or the
  /// "insufficient space" exception of a model manager (on-device AI,
  /// voice, text recognition, offline languages); null for anything else.
  static SpaceShortfall? of(Object? error) => switch (error) {
    NotEnoughSpaceException(:final requiredBytes, :final availableBytes) ||
    LlamaInsufficientSpaceException(
      :final requiredBytes,
      :final availableBytes,
    ) ||
    WhisperInsufficientSpaceException(
      :final requiredBytes,
      :final availableBytes,
    ) ||
    TessdataInsufficientSpaceException(
      :final requiredBytes,
      :final availableBytes,
    ) ||
    ModelInsufficientSpaceException(
      :final requiredBytes,
      :final availableBytes,
    ) => SpaceShortfall(
      requiredBytes: requiredBytes,
      availableBytes: availableBytes,
    ),
    _ => null,
  };

  final int requiredBytes;
  final int availableBytes;

  /// "Not enough free space: needs 1.2 GB, 300 MB free".
  String message(AppLocalizations l10n) => l10n.commonNotEnoughSpace(
    formatStorageSize(l10n, requiredBytes),
    formatStorageSize(l10n, availableBytes),
  );

  @override
  bool operator ==(Object other) =>
      other is SpaceShortfall &&
      other.requiredBytes == requiredBytes &&
      other.availableBytes == availableBytes;

  @override
  int get hashCode => Object.hash(requiredBytes, availableBytes);

  @override
  String toString() => 'SpaceShortfall($requiredBytes, $availableBytes)';
}

/// "1.2 GB" from 1 GiB on, "300 MB" from 10 MiB on, else "4.5 MB" (or
/// "0.3 MB"), in the locale of [l10n]: storage sizes in messages.
String formatStorageSize(AppLocalizations l10n, int bytes) {
  const mebibyte = 1024 * 1024;
  const gibibyte = 1024 * mebibyte;
  if (bytes >= gibibyte) {
    return l10n.commonSizeGigabytes(
      NumberFormat('0.0', l10n.localeName).format(bytes / gibibyte),
    );
  }
  final pattern = bytes >= 10 * mebibyte ? '0' : '0.0';
  return l10n.commonSizeMegabytes(
    NumberFormat(pattern, l10n.localeName).format(bytes / mebibyte),
  );
}
