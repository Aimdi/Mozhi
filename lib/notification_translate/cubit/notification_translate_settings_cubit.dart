import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:mozhi/notification_translate/data/notification_translate_controls.dart';

/// State for the opt-in offline notification translation setting.
final class NotificationTranslateSettingsState extends Equatable {
  const new({
    this.status = const NotificationTranslateStatus(),
    this.busy = false,
  });

  final NotificationTranslateStatus status;
  final bool busy;

  NotificationTranslateSettingsState copyWith({
    NotificationTranslateStatus? status,
    bool? busy,
  }) => NotificationTranslateSettingsState(
    status: status ?? this.status,
    busy: busy ?? this.busy,
  );

  @override
  List<Object?> get props => [status, busy];
}

/// Manages the opt-in offline notification translation toggle and permission.
class NotificationTranslateSettingsCubit
    extends Cubit<NotificationTranslateSettingsState> {
  new({required this._controls})
    : super(const NotificationTranslateSettingsState());

  final NotificationTranslateControls _controls;

  /// Reloads current notification access and enabled state from Android.
  Future<void> refresh() async {
    final current = await _controls.status();
    if (isClosed) return;
    emit(state.copyWith(status: current, busy: false));
  }

  /// Enables notification translation; opens Android's Notification Access
  /// settings first if permission is not yet granted.
  Future<void> enable() async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final current = await _controls.status();
    if (!current.hasAccess) {
      await _controls.openAccessSettings();
      if (isClosed) return;
      emit(state.copyWith(status: current, busy: false));
      return;
    }
    await _controls.setEnabled(enabled: true);
    await refresh();
  }

  /// Disables notification translation.
  Future<void> disable() async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    await _controls.setEnabled(enabled: false);
    await refresh();
  }
}
