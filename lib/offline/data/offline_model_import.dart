import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

/// What an import did with one translation direction.
enum OfflineImportStatus {
  /// Installed from the files.
  installed,

  /// This model was on the device already.
  alreadyInstalled,

  /// Some of its files were not selected
  /// ([OfflineImportedModel.missingFiles]).
  incomplete,

  /// A file did not match its checksum (damaged, incomplete or from another
  /// model version).
  damaged,

  /// The files were fine but could not be installed (e.g. a full disk).
  failed,
}

/// One translation direction an import found files for.
@immutable
class OfflineImportedModel extends Equatable {
  const new({
    required this.source,
    required this.target,
    required this.status,
    this.missingFiles = const [],
    this.storageError = false,
  });

  /// Language codes of the direction (as the engine reports languages).
  final String source;
  final String target;
  final OfflineImportStatus status;

  /// Names (as published, see [OfflineModelFile.name]) of the files still
  /// needed: missing or damaged ones.
  final List<String> missingFiles;

  /// Whether a [OfflineImportStatus.failed] model could not be written
  /// (usually a full disk).
  final bool storageError;

  @override
  List<Object?> get props => [
    source,
    target,
    status,
    missingFiles,
    storageError,
  ];
}

/// The result of [OfflineModelImport.importFiles].
@immutable
class OfflineImportReport extends Equatable {
  const new({this.models = const [], this.unmatchedFiles = const []});

  /// One entry per direction the files belong to, in a stable order.
  final List<OfflineImportedModel> models;

  /// Names of the selected files that belong to no model.
  final List<String> unmatchedFiles;

  @override
  List<Object?> get props => [models, unmatchedFiles];
}

/// A model file to download by hand and import (see [OfflineModelImport]).
@immutable
class OfflineModelFile extends Equatable {
  const new({
    required this.source,
    required this.target,
    required this.name,
    required this.url,
    required this.size,
  });

  /// Language codes of the direction the file belongs to.
  final String source;
  final String target;

  /// The file name as published (e.g. `vocab.deen.spm.gz`).
  final String name;

  /// Where to download it.
  final String url;

  /// Bytes to download.
  final int size;

  @override
  List<Object?> get props => [source, target, name, url, size];
}

/// Installing models from files the user copied to the device, for engines
/// that support it (Mozilla's Bergamot engine): the way to get models
/// without the app contacting any server.
abstract interface class OfflineModelImport {
  /// Installs every model whose files are all among the files at [paths]
  /// (checked against the bundled checksums) and reports what it found.
  /// Never uses the network; the files are only read.
  Future<OfflineImportReport> importFiles(List<String> paths);

  /// The files to download by hand for [code] (both directions; empty for
  /// a language that needs none).
  List<OfflineModelFile> manualFiles(String code);
}
