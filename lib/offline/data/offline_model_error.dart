import 'dart:io' show FileSystemException;

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:translation_repository/translation_repository.dart';

/// Why downloading, updating or deleting offline models failed.
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

  /// The models could not be written (usually a full disk).
  storage,

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
  const new(this.kind, {this.statusCode, this.networkPolicy});

  /// Classifies [error] (thrown by `OfflineTranslator.downloadLanguage`,
  /// `deleteLanguage` or `OfflineModelDetails.download`).
  factory of(Object error) => switch (error) {
    MeteredConnectionException() => const OfflineModelError(
      OfflineModelErrorKind.metered,
    ),
    ModelChecksumException() => const OfflineModelError(
      OfflineModelErrorKind.checksum,
    ),
    ModelDownloadException(:final int statusCode) => OfflineModelError(
      OfflineModelErrorKind.server,
      statusCode: statusCode,
    ),
    ModelDownloadException(:final message) => OfflineModelError(
      OfflineModelErrorKind.network,
      networkPolicy: NetworkPolicyError.of(message),
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

  final OfflineModelErrorKind kind;

  /// The HTTP status of a [OfflineModelErrorKind.server] error.
  final int? statusCode;

  /// The app's network rule that refused a [OfflineModelErrorKind.network]
  /// download (e.g. an invalid proxy setting), if any.
  final NetworkPolicyError? networkPolicy;

  @override
  List<Object?> get props => [kind, statusCode, networkPolicy];
}
