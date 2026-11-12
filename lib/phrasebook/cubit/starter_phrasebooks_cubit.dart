import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:mozhi/core/runs_in_browser.dart';
import 'package:mozhi/phrasebook/data/starter_phrasebooks.dart';
import 'package:mozhi/phrasebook/models/starter_phrasebook.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:mozhi/settings/models/model_source.dart';

/// Why a starter phrasebook could not be installed.
enum StarterPhrasebookError {
  /// The server could not be reached.
  download,

  /// The server answered with an HTTP error
  /// ([StarterPhrasebookItem.statusCode]), e.g. 404 from a mirror that
  /// does not host the phrasebooks.
  server,

  /// In the web app, the original publisher (a GitHub release) could not
  /// be reached: it does not let web pages download the files.
  browserRefused,

  /// The file did not match its checksum, or was not a phrasebook.
  checksum,

  /// The phone has too little free space
  /// ([StarterPhrasebookItem.space] says how much it needs).
  space,

  /// Anything else (storage).
  other,
}

/// A starter phrasebook of the catalogue and where it stands.
class StarterPhrasebookItem extends Equatable {
  const new({
    required this.info,
    this.installed,
    this.progress,
    this.error,
    this.space,
    this.statusCode,
  });

  final StarterPhrasebookInfo info;

  /// The installed version, if any.
  final InstalledStarterPhrasebook? installed;

  /// The download's progress (0 to 1) while it runs.
  final double? progress;

  /// Why the last install failed.
  final StarterPhrasebookError? error;

  /// What a [StarterPhrasebookError.space] failure needs and has.
  final SpaceShortfall? space;

  /// The HTTP status of a [StarterPhrasebookError.server] failure.
  final int? statusCode;

  bool get isInstalled => installed != null;

  bool get isDownloading => progress != null;

  /// Whether the catalogue has another version than the installed one.
  bool get hasUpdate => installed != null && installed!.sha256 != info.sha256;

  StarterPhrasebookItem copyWith({
    InstalledStarterPhrasebook? Function()? installed,
    double? Function()? progress,
    StarterPhrasebookError? Function()? error,
    SpaceShortfall? Function()? space,
    int? Function()? statusCode,
  }) => StarterPhrasebookItem(
    info: info,
    installed: installed != null ? installed() : this.installed,
    progress: progress != null ? progress() : this.progress,
    error: error != null ? error() : this.error,
    space: space != null ? space() : this.space,
    statusCode: statusCode != null ? statusCode() : this.statusCode,
  );

  @override
  List<Object?> get props => [
    info,
    installed,
    progress,
    error,
    space,
    statusCode,
  ];
}

class StarterPhrasebooksState extends Equatable {
  const new({this.loading = true, this.items = const []});

  final bool loading;

  /// The catalogue's phrasebooks, by name.
  final List<StarterPhrasebookItem> items;

  /// The [items] to offer in an app whose language is [appLanguage] (a
  /// tag such as `de` or `pt_BR`): without the phrasebooks of that
  /// language (a German speaker needs no German phrasebook for English
  /// speakers) unless they are installed (so they can still be deleted).
  List<StarterPhrasebookItem> itemsFor(String appLanguage) {
    final own = _primary(appLanguage);
    return [
      for (final item in items)
        if (item.isInstalled ||
            _primary(item.info.language) != own ||
            _primary(item.info.baseLanguage) == own)
          item,
    ];
  }

  static String _primary(String tag) =>
      tag.trim().split(RegExp('[-_]')).first.toLowerCase();

  @override
  List<Object?> get props => [loading, items];
}

/// The "Starter phrasebooks" sheet: the catalogue's phrasebooks with what
/// is installed, and their downloads (once, on request, checked against
/// the catalogue's SHA-256).
///
/// In the web app (`isWeb`), a failed connection while the model source
/// reaches the original publishers (`source`, default
/// [ModelSource.current]: the original publishers, or a mirror that falls
/// back to them) is [StarterPhrasebookError.browserRefused]: GitHub's
/// release downloads send no CORS headers.
class StarterPhrasebooksCubit extends Cubit<StarterPhrasebooksState> {
  new(
    this._packs, {
    this._isWeb = runsInBrowser,
    ModelSource Function()? source,
  }) : _source = source ?? _currentSource,
       super(const StarterPhrasebooksState());

  final StarterPhrasebooks _packs;

  /// Whether the app runs in a browser.
  final bool _isWeb;

  final ModelSource Function() _source;

  static ModelSource _currentSource() => ModelSource.current;

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
              space: previous[info.id]?.space,
              statusCode: previous[info.id]?.statusCode,
            ),
        ],
      ),
    );
  }

  /// Downloads and installs [info].
  Future<void> install(StarterPhrasebookInfo info) async {
    _update(
      info.id,
      (item) => item.copyWith(
        progress: () => 0,
        error: () => null,
        space: () => null,
        statusCode: () => null,
      ),
    );
    final (error, space, status) = await _attempt(
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
      (item) => item.copyWith(
        progress: () => null,
        error: () => error,
        space: () => space,
        statusCode: () => status,
      ),
    );
    await load();
  }

  /// Deletes the installed phrasebook [id].
  Future<void> delete(String id) async {
    await _attempt(() => _packs.delete(id));
    await load();
  }

  /// Runs [action]; returns why it failed (and, for too little free
  /// space, how much it needs; for a server error, its HTTP status), or
  /// nulls.
  Future<(StarterPhrasebookError?, SpaceShortfall?, int?)> _attempt(
    Future<void> Function() action,
  ) async {
    try {
      await action();
      return (null, null, null);
    } on StarterPhrasebookChecksumException {
      return (StarterPhrasebookError.checksum, null, null);
    } on StarterPhrasebookDownloadException catch (error) {
      if (error.statusCode case final status?) {
        return (StarterPhrasebookError.server, null, status);
      }
      final source = _source();
      final original =
          source.kind == ModelSourceKind.defaultHosts ||
          source.fallsBackToDefault;
      return (
        _isWeb && original
            ? StarterPhrasebookError.browserRefused
            : StarterPhrasebookError.download,
        null,
        null,
      );
    } on NotEnoughSpaceException catch (error) {
      return (StarterPhrasebookError.space, SpaceShortfall.of(error), null);
    } on Object {
      return (StarterPhrasebookError.other, null, null);
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
