import 'dart:io' show FileSystemException;

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart'
    show
        TessdataChecksumException,
        TessdataDownloadException,
        TessdataInsufficientSpaceException,
        TessdataMissingException;
import 'package:translation_repository/translation_repository.dart';

/// Why downloading, updating or deleting offline models (or text
/// recognition data) failed.
enum OfflineModelErrorKind {
  /// A Wi-Fi-only download on a metered network: nothing was downloaded
  /// (the screen offers to download anyway).
  metered,

  /// A file did not match the catalog's size or SHA-256 and was discarded.
  checksum,

  /// The model server answered with an HTTP error.
  server,

  /// The connection failed (offline, timeout, proxy).
  network,

  /// In the web app, a download from an original publisher that does not
  /// let web pages download its files (no CORS headers): the browser
  /// refused it, whatever the connection.
  browserRefused,

  /// The models could not be written (usually a full disk).
  storage,

  /// The free space was checked first and is too little for the download
  /// or import ([OfflineModelError.space] says how much it needs): nothing
  /// was written.
  space,

  /// The native engine failed.
  engine,

  /// The engine has no model for the language, or no engine runs here.
  unsupported,

  /// Anything else.
  unknown,
}

/// A failure of an offline model operation, classified for the user.
@immutable
class OfflineModelError extends Equatable {
  const new(
    this.kind, {
    this.statusCode,
    this.networkPolicy,
    this.mirror,
    this.space,
  });

  /// Classifies [error] (thrown by `OfflineTranslator.downloadLanguage`,
  /// `deleteLanguage`, `OfflineModelDetails.download` or the text
  /// recognition data's `downloadOcrLanguage`). In a browser ([isWeb]) a
  /// translation model that could not be fetched from Mozilla (no mirror)
  /// is [OfflineModelErrorKind.browserRefused]
  /// ([OfflineModelError.browserRefusedOrNetwork]).
  factory of(Object error, {bool isWeb = kIsWeb}) => switch (error) {
    MeteredConnectionException() => const OfflineModelError(
      OfflineModelErrorKind.metered,
    ),
    ModelInsufficientSpaceException() ||
    TessdataInsufficientSpaceException() ||
    NotEnoughSpaceException() => OfflineModelError(
      OfflineModelErrorKind.space,
      space: SpaceShortfall.of(error),
    ),
    ModelChecksumException(:final mirror) ||
    TessdataChecksumException(:final mirror) => OfflineModelError(
      OfflineModelErrorKind.checksum,
      mirror: mirrorName(mirror),
    ),
    TessdataDownloadException(:final int statusCode, :final mirror) =>
      OfflineModelError(
        OfflineModelErrorKind.server,
        statusCode: statusCode,
        mirror: mirrorName(mirror),
      ),
    TessdataDownloadException(:final message, :final mirror) =>
      OfflineModelError(
        OfflineModelErrorKind.network,
        networkPolicy: NetworkPolicyError.of(message),
        mirror: mirrorName(mirror),
      ),
    TessdataMissingException() => const OfflineModelError(
      OfflineModelErrorKind.unsupported,
    ),
    ModelDownloadException(:final int statusCode, :final mirror) =>
      OfflineModelError(
        OfflineModelErrorKind.server,
        statusCode: statusCode,
        mirror: mirrorName(mirror),
      ),
    ModelDownloadException(:final message, :final mirror) =>
      OfflineModelError.browserRefusedOrNetwork(
        message,
        mirror: mirror,
        isWeb: isWeb,
      ),
    FileSystemException() => const OfflineModelError(
      OfflineModelErrorKind.storage,
    ),
    BergamotEngineException() => const OfflineModelError(
      OfflineModelErrorKind.engine,
    ),
    OfflineLanguageUnsupportedException() || UnsupportedError() =>
      const OfflineModelError(OfflineModelErrorKind.unsupported),
    _ => const OfflineModelError(OfflineModelErrorKind.unknown),
  };

  /// A failed connection to [mirror] (null: the original publisher) with
  /// [message]: in a browser ([isWeb]) without a mirror or a network rule
  /// that refused it, [OfflineModelErrorKind.browserRefused] (the original
  /// publishers of the offline languages and dictionaries send no CORS
  /// headers); otherwise [OfflineModelErrorKind.network].
  factory browserRefusedOrNetwork(
    String message, {
    Uri? mirror,
    bool isWeb = kIsWeb,
  }) {
    final policy = NetworkPolicyError.of(message);
    if (isWeb && mirror == null && policy == null) {
      return const OfflineModelError(OfflineModelErrorKind.browserRefused);
    }
    return OfflineModelError(
      OfflineModelErrorKind.network,
      networkPolicy: policy,
      mirror: mirrorName(mirror),
    );
  }

  final OfflineModelErrorKind kind;

  /// The HTTP status of a [OfflineModelErrorKind.server] error.
  final int? statusCode;

  /// The app's network rule that refused a [OfflineModelErrorKind.network]
  /// download (e.g. an invalid proxy setting), if any.
  final NetworkPolicyError? networkPolicy;

  /// The mirror (host and port, see `AppSettings.modelSource`) a failed
  /// download came from; null for the original publishers.
  final String? mirror;

  /// What a [OfflineModelErrorKind.space] failure needs and has.
  final SpaceShortfall? space;

  /// [mirror] as shown to the user: its host, and its port when it has
  /// one; null for none.
  static String? mirrorName(Uri? mirror) => switch (mirror) {
    null => null,
    final mirror when mirror.hasPort => '${mirror.host}:${mirror.port}',
    final mirror => mirror.host,
  };

  @override
  List<Object?> get props => [kind, statusCode, networkPolicy, mirror, space];
}
