import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

/// Disk usage and pending updates of the downloaded offline models.
@immutable
class OfflineStorage extends Equatable {
  const new({
    this.installedBytes = const {},
    this.totalBytes = 0,
    this.outdated = const {},
  });

  /// Bytes on disk per language with models on the device (both
  /// directions; a model that two languages share counts for both).
  final Map<String, int> installedBytes;

  /// Bytes used by every installed model, each counted once.
  final int totalBytes;

  /// Languages with an installed model older than the catalog's.
  final Set<String> outdated;

  @override
  List<Object?> get props => [installedBytes, totalBytes, outdated];
}

/// What the Offline languages screen shows beyond `OfflineTranslator`:
/// download sizes, disk usage, updates and download progress. Engines
/// without this information have none (the screen then only lists the
/// languages).
abstract interface class OfflineModelDetails {
  /// Bytes to download for [code] (both directions). 0 for a language that
  /// needs no download (English, which every model translates to or from).
  int downloadSize(String code);

  /// The current [OfflineStorage] of the languages [codes].
  Future<OfflineStorage> storage(Iterable<String> codes);

  /// Downloads [code]'s missing or outdated models like
  /// `OfflineTranslator.downloadLanguage` (same [wifiOnly] meaning and
  /// errors), calling [onProgress] with the fraction (0 to 1) of those
  /// bytes received so far.
  Future<void> download(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  });
}

/// Which way the offline engine translates a language.
enum OfflineLanguageDirection {
  /// To and from it (most languages).
  both,

  /// Only into it, from English (e.g. Azerbaijani with Mozilla's models).
  intoOnly,

  /// Only from it, into English.
  fromOnly,
}

/// [OfflineModelDetails] of an engine whose languages may go one way only:
/// those are not in `OfflineTranslator.supportedLanguages` (which lists
/// the languages that go both ways), yet their models can be downloaded
/// and deleted like the others'.
abstract interface class OfflineLanguageDirections {
  /// The languages that translate one way only, with that way.
  Map<String, OfflineLanguageDirection> get oneWayLanguages;
}

/// A download of a language's models that is running now (see
/// [OfflineRunningDownloads]), possibly started on another screen.
@immutable
class OfflineRunningDownload {
  const new({
    required this.result,
    this.progress = 0,
    this.progressChanges = const Stream.empty(),
  });

  /// The fraction (0 to 1) of the bytes received so far.
  final double progress;

  /// [progress] each time it changes, until the download ends.
  final Stream<double> progressChanges;

  /// Completes when the download ends: normally once the models are
  /// installed, else with the error it failed with (also
  /// `OfflineDownloadCancelledException` after a cancel).
  final Future<void> result;
}

/// [OfflineModelDetails] of an engine that tells which downloads are
/// running, so that a screen opened during one shows its progress and its
/// outcome, whichever screen started it.
abstract interface class OfflineRunningDownloads {
  /// The running downloads by language code.
  Map<String, OfflineRunningDownload> get runningDownloads;
}
