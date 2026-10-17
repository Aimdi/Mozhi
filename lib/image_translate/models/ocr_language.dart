import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

/// A language whose text recognition data can be downloaded (Tesseract's
/// `<code>.traineddata`).
@immutable
class OcrLanguage extends Equatable {
  const new({
    required this.code,
    required this.appCode,
    required this.downloadSize,
    this.url,
  });

  /// The recognition engine's code, e.g. `deu`, `chi_sim`.
  final String code;

  /// The app language it reads best (the app's catalogue code), e.g. `de`,
  /// `zh-CN`; used for its name.
  final String appCode;

  /// Bytes to download (and on the device once installed).
  final int downloadSize;

  /// Where the file is downloaded from (to download it by hand), if known.
  final Uri? url;

  /// The file to import when downloaded by hand.
  String get fileName => '$code.traineddata';

  @override
  List<Object?> get props => [code, appCode, downloadSize, url];
}

/// On-device text recognition needs the data of [language], which is not
/// on the device; nothing was recognised. The image screen offers to
/// download (or import) it.
@immutable
class OcrDataMissingException extends Equatable implements Exception {
  const new(this.language, {this.guessed = false});

  final OcrLanguage language;

  /// The source was "Detect language" and no recognition data is on the
  /// device at all: [language] is a guess (the app's language, a recent
  /// source language or English), so the user may rather pick the
  /// language of the text.
  final bool guessed;

  @override
  List<Object?> get props => [language, guessed];

  @override
  String toString() =>
      'OcrDataMissingException(${language.code}${guessed ? ', guessed' : ''})';
}

/// What an import of recognition data from files did.
@immutable
class OcrImportReport extends Equatable {
  const new({
    this.installed = const [],
    this.alreadyInstalled = const [],
    this.damaged = const [],
    this.failed = const [],
    this.unmatchedFiles = const [],
    this.error,
  });

  /// Codes of the languages the import installed.
  final List<String> installed;

  /// Codes of the languages whose data was already installed.
  final List<String> alreadyInstalled;

  /// Codes of the languages whose files did not match their checksum.
  final List<String> damaged;

  /// Codes of the languages that could not be installed (e.g. a full disk).
  final List<String> failed;

  /// Names of the picked files that are no recognition data.
  final List<String> unmatchedFiles;

  /// Why the import as a whole failed (picking or reading the files), if
  /// it did.
  final Object? error;

  @override
  List<Object?> get props => [
    installed,
    alreadyInstalled,
    damaged,
    failed,
    unmatchedFiles,
    error,
  ];
}
