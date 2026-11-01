import 'dart:async';

import 'package:mozhi/offline/cubit/offline_models_state.dart';

/// Tells the app about offline-language downloads that failed after every
/// screen showing them had closed ([failures]), so that the user does not
/// take the language for downloaded. An `OfflineModelsCubit` joins
/// ([join]) each download it runs or shows; while one of them is open, or
/// once one has shown the outcome, nothing is told here.
///
/// The app shows [failures] in a snack bar
/// (`OfflineDownloadFailureListener`).
class OfflineDownloadNotices {
  new();

  /// The app's notices (every `OfflineModelsCubit` uses them by default).
  static final instance = OfflineDownloadNotices();

  final _failures = StreamController<OfflineModelOutcome>.broadcast();
  final _downloads = <String, _Download>{};

  /// Downloads and updates that failed while no screen showed them.
  Stream<OfflineModelOutcome> get failures => _failures.stream;

  /// A screen follows the running download of [code] (the download it
  /// starts, or one started elsewhere): every screen following the same
  /// download shares it until each one has [OfflineDownloadWatcher.end]ed.
  OfflineDownloadWatcher join(String code) {
    final download = _downloads[code] ??= _Download(this, code);
    download.members++;
    download.open++;
    return OfflineDownloadWatcher._(download);
  }

  /// Closes [failures] (tests).
  Future<void> close() => _failures.close();
}

/// One screen following a download (see [OfflineDownloadNotices.join]).
final class OfflineDownloadWatcher {
  new _(this._download);

  final _Download _download;
  var _open = true;
  var _ended = false;

  /// The screen has closed; the download goes on.
  void leave() {
    if (!_open) return;
    _open = false;
    _download.open--;
  }

  /// The screen has shown the download's outcome.
  void shown() => _download.told = true;

  /// The download failed after this screen closed: told app-wide unless
  /// another screen shows it (still open) or has shown it.
  void failedUnseen(OfflineModelOutcome outcome) {
    leave();
    final download = _download;
    if (download.told || download.open > 0) return;
    download.told = true;
    download.notices._failures.add(outcome);
  }

  /// This screen is done with the download.
  void end() {
    if (_ended) return;
    _ended = true;
    leave();
    final download = _download;
    if (--download.members > 0) return;
    if (identical(download.notices._downloads[download.code], download)) {
      download.notices._downloads.remove(download.code);
    }
  }
}

/// The screens following one download of [code].
final class _Download {
  new(this.notices, this.code);

  final OfflineDownloadNotices notices;
  final String code;

  /// Screens following it, and how many of them are open.
  int members = 0;
  int open = 0;

  /// Whether a screen showed the outcome (or it was told app-wide).
  bool told = false;
}
