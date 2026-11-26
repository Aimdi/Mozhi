import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:mozhi/notification_translate/data/notification_translate_controls.dart';
import 'package:translation_repository/translation_repository.dart';

/// State for the opt-in offline notification translation setting.
final class NotificationTranslateSettingsState extends Equatable {
  const new({
    this.status = const NotificationTranslateStatus(),
    this.busy = false,
    this.loaded = false,
    this.pendingEnable = false,
    this.downloadedLanguages = const [],
    this.hasOfflineLanguages = true,
  });

  final NotificationTranslateStatus status;
  final bool busy;
  final bool loaded;

  /// True after sending the user to Android's Notification Access settings so
  /// returning with access granted completes enabling automatically.
  final bool pendingEnable;

  /// Canonical codes of downloaded offline languages.
  final List<String> downloadedLanguages;

  /// Whether at least one downloadable offline language pair is installed
  /// (false when fewer than 2 languages are downloaded).
  final bool hasOfflineLanguages;

  NotificationTranslateSettingsState copyWith({
    NotificationTranslateStatus? status,
    bool? busy,
    bool? loaded,
    bool? pendingEnable,
    List<String>? downloadedLanguages,
    bool? hasOfflineLanguages,
  }) => NotificationTranslateSettingsState(
    status: status ?? this.status,
    busy: busy ?? this.busy,
    loaded: loaded ?? this.loaded,
    pendingEnable: pendingEnable ?? this.pendingEnable,
    downloadedLanguages: downloadedLanguages ?? this.downloadedLanguages,
    hasOfflineLanguages: hasOfflineLanguages ?? this.hasOfflineLanguages,
  );

  @override
  List<Object?> get props => [
    status,
    busy,
    loaded,
    pendingEnable,
    downloadedLanguages,
    hasOfflineLanguages,
  ];
}

/// Manages the opt-in offline notification translation toggle, permissions,
/// dedicated target language, and muted apps.
class NotificationTranslateSettingsCubit
    extends Cubit<NotificationTranslateSettingsState> {
  new({required this._controls, this._offline})
    : super(const NotificationTranslateSettingsState());

  final NotificationTranslateControls _controls;
  final OfflineTranslator? _offline;

  /// Reloads current notification access, enabled state, downloaded offline
  /// languages, and completes any pending enable intent after returning from
  /// Android Notification Access settings.
  Future<void> refresh() async {
    var current = await _controls.status();
    if (isClosed) return;

    var pendingEnable = state.pendingEnable;
    if (pendingEnable) {
      pendingEnable = false;
      if (current.hasAccess && !current.enabled) {
        if (!current.notificationsAllowed) {
          await _controls.requestNotificationPermission();
          if (isClosed) return;
        }
        await _controls.setEnabled(enabled: true);
        if (isClosed) return;
        current = await _controls.status();
        if (isClosed) return;
      }
    }

    final (downloaded, hasOffline) = await _readOfflineLanguages();
    if (isClosed) return;
    emit(
      state.copyWith(
        status: current,
        busy: false,
        loaded: true,
        pendingEnable: pendingEnable,
        downloadedLanguages: downloaded,
        hasOfflineLanguages: hasOffline,
      ),
    );
  }

  /// Enables notification translation; opens Android's Notification Access
  /// settings first if access is not yet granted (remembering intent so
  /// returning with access granted finishes enabling), and requests Android
  /// 13+ `POST_NOTIFICATIONS` permission when needed.
  Future<void> enable() async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final current = await _controls.status();
    if (isClosed) return;
    if (!current.hasAccess) {
      final opened = await _controls.openAccessSettings();
      if (isClosed) return;
      emit(
        state.copyWith(
          status: current,
          busy: false,
          loaded: true,
          pendingEnable: opened,
        ),
      );
      return;
    }
    if (!current.notificationsAllowed) {
      await _controls.requestNotificationPermission();
      if (isClosed) return;
    }
    await _controls.setEnabled(enabled: true);
    if (isClosed) return;
    emit(state.copyWith(pendingEnable: false));
    await refresh();
  }

  /// Disables notification translation.
  Future<void> disable() async {
    if (state.busy) return;
    emit(state.copyWith(busy: true, pendingEnable: false));
    await _controls.setEnabled(enabled: false);
    if (isClosed) return;
    await refresh();
  }

  /// Requests Android 13+ notification posting permission and refreshes state.
  Future<void> requestNotificationPermission() async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    await _controls.requestNotificationPermission();
    if (isClosed) return;
    await refresh();
  }

  /// Sets the dedicated target language (or null to follow the Translate tab).
  Future<void> setTargetLanguage(String? code) async {
    await _controls.setTargetLanguage(code);
    if (isClosed) return;
    await refresh();
  }

  /// Mutes or unmutes [packageName].
  Future<void> setPackageMuted(
    String packageName, {
    required bool muted,
  }) async {
    await _controls.setPackageMuted(packageName, muted: muted);
    if (isClosed) return;
    await refresh();
  }

  Future<(List<String>, bool)> _readOfflineLanguages() async {
    final offline = _offline;
    if (offline == null) return (const <String>[], true);
    try {
      final downloaded = await offline.downloadedLanguages();
      final sorted = downloaded.toList()
        ..sort(
          (a, b) =>
              LanguageCatalog.nameOf(a).compareTo(LanguageCatalog.nameOf(b)),
        );
      return (List<String>.unmodifiable(sorted), downloaded.length >= 2);
    } on Object {
      return (const <String>[], true);
    }
  }
}
