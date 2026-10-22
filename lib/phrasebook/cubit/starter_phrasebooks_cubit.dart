import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:mozhi/phrasebook/data/starter_phrasebooks.dart';
import 'package:mozhi/phrasebook/models/starter_phrasebook.dart';

/// Why a starter phrasebook could not be installed.
enum StarterPhrasebookError {
  /// The server answered with an error or could not be reached.
  download,

  /// The file did not match its checksum, or was not a phrasebook.
  checksum,

  /// Anything else (storage).
  other,
}

/// A starter phrasebook of the catalogue and where it stands.
class StarterPhrasebookItem extends Equatable {
  const new({required this.info, this.installed, this.progress, this.error});

  final StarterPhrasebookInfo info;

  /// The installed version, if any.
  final InstalledStarterPhrasebook? installed;

  /// The download's progress (0 to 1) while it runs.
  final double? progress;

  /// Why the last install failed.
  final StarterPhrasebookError? error;

  bool get isInstalled => installed != null;

  bool get isDownloading => progress != null;

  /// Whether the catalogue has another version than the installed one.
  bool get hasUpdate => installed != null && installed!.sha256 != info.sha256;

  StarterPhrasebookItem copyWith({
    InstalledStarterPhrasebook? Function()? installed,
    double? Function()? progress,
    StarterPhrasebookError? Function()? error,
  }) => StarterPhrasebookItem(
    info: info,
    installed: installed != null ? installed() : this.installed,
    progress: progress != null ? progress() : this.progress,
    error: error != null ? error() : this.error,
  );

  @override
  List<Object?> get props => [info, installed, progress, error];
}

class StarterPhrasebooksState extends Equatable {
  const new({this.loading = true, this.items = const []});

  final bool loading;

  /// The catalogue's phrasebooks, by name.
  final List<StarterPhrasebookItem> items;

  @override
  List<Object?> get props => [loading, items];
}

/// The "Starter phrasebooks" sheet: the catalogue's phrasebooks with what
/// is installed, and their downloads (once, on request, checked against
/// the catalogue's SHA-256).
class StarterPhrasebooksCubit extends Cubit<StarterPhrasebooksState> {
  new(this._packs) : super(const StarterPhrasebooksState());

  final StarterPhrasebooks _packs;

  Future<void> load() async {
    List<InstalledStarterPhrasebook> installed;
    try {
      installed = await _packs.installed();
    } on Object {
      installed = const [];
    }
    if (isClosed) return;
    final byId = {for (final pack in installed) pack.id: pack};
    final previous = {for (final item in state.items) item.info.id: item};
    emit(
      StarterPhrasebooksState(
        loading: false,
        items: [
          for (final info in _packs.catalog.packs)
            StarterPhrasebookItem(
              info: info,
              installed: byId[info.id],
              progress: previous[info.id]?.progress,
              error: previous[info.id]?.error,
            ),
        ],
      ),
    );
  }

  /// Downloads and installs [info].
  Future<void> install(StarterPhrasebookInfo info) async {
    _update(
      info.id,
      (item) => item.copyWith(progress: () => 0, error: () => null),
    );
    final error = await _attempt(
      () => _packs.install(
        info,
        onProgress: (fraction) => _update(
          info.id,
          (item) => item.copyWith(progress: () => fraction.clamp(0, 1)),
        ),
      ),
    );
    _update(
      info.id,
      (item) => item.copyWith(progress: () => null, error: () => error),
    );
    await load();
  }

  /// Deletes the installed phrasebook [id].
  Future<void> delete(String id) async {
    await _attempt(() => _packs.delete(id));
    await load();
  }

  /// Runs [action]; returns why it failed, or null.
  static Future<StarterPhrasebookError?> _attempt(
    Future<void> Function() action,
  ) async {
    try {
      await action();
      return null;
    } on StarterPhrasebookChecksumException {
      return StarterPhrasebookError.checksum;
    } on StarterPhrasebookDownloadException {
      return StarterPhrasebookError.download;
    } on Object {
      return StarterPhrasebookError.other;
    }
  }

  void _update(
    String id,
    StarterPhrasebookItem Function(StarterPhrasebookItem item) change,
  ) {
    if (isClosed) return;
    emit(
      StarterPhrasebooksState(
        loading: state.loading,
        items: [
          for (final item in state.items)
            if (item.info.id == id) change(item) else item,
        ],
      ),
    );
  }
}
