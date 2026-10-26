import 'package:bloc/bloc.dart';
import 'package:mozhi/screen_translate/cubit/screen_translate_settings_state.dart';
import 'package:mozhi/screen_translate/data/screen_translate_controls.dart';

export 'screen_translate_settings_state.dart';

/// The "Translate screen" settings (Settings › General › Android
/// integration): the bubble's switch and the Quick Settings tile.
///
/// The bubble's state lives on the platform (its service runs or not):
/// [refresh] reads it (the view does so when the app comes back, e.g. after
/// the bubble was removed by dragging it onto ×). [enableBubble] asks for
/// "Display over other apps" when it is not allowed yet (the view explains
/// it first), then for notifications (Android 13+; the bubble starts
/// without them, with a notice), then starts it. Nothing is stored in the
/// app's settings.
class ScreenTranslateSettingsCubit extends Cubit<ScreenTranslateSettingsState> {
  new({required this._controls}) : super(const ScreenTranslateSettingsState());

  final ScreenTranslateControls _controls;

  /// Reads the platform's state.
  Future<void> refresh() async {
    final support = await _controls.status();
    if (isClosed) return;
    emit(state.copyWith(support: support, loaded: true));
  }

  /// Turns the bubble on (see the class documentation).
  Future<void> enableBubble() async {
    if (state.busy || state.bubbleOn) return;
    emit(state.copyWith(busy: true));
    var support = await _controls.status();
    if (isClosed) return;
    if (!support.canDrawOverlays) {
      final granted = await _controls.requestOverlayPermission();
      if (isClosed) return;
      if (!granted) {
        support = await _controls.status();
        if (isClosed) return;
        emit(
          state
              .copyWith(support: support, loaded: true, busy: false)
              .withNotice(ScreenTranslateNotice.overlayDenied),
        );
        return;
      }
    }
    final notifications = await _controls.requestNotificationPermission();
    if (isClosed) return;
    final started = await _controls.startBubble();
    if (isClosed) return;
    support = await _controls.status();
    if (isClosed) return;
    // The service starts a moment after it was asked to: it is on unless
    // starting failed.
    final next = state.copyWith(
      support: ScreenTranslateSupport(
        bubbleRunning: started || support.bubbleRunning,
        canDrawOverlays: support.canDrawOverlays,
        notificationsAllowed: support.notificationsAllowed,
        canAddTile: support.canAddTile,
      ),
      loaded: true,
      busy: false,
    );
    if (!started) {
      emit(next.withNotice(ScreenTranslateNotice.bubbleFailed));
    } else if (!notifications) {
      emit(next.withNotice(ScreenTranslateNotice.notificationsDenied));
    } else {
      emit(next);
    }
  }

  /// Turns the bubble off.
  Future<void> disableBubble() async {
    if (state.busy || !state.bubbleOn) return;
    emit(state.copyWith(busy: true));
    await _controls.stopBubble();
    if (isClosed) return;
    final support = state.support;
    emit(
      state.copyWith(
        support: ScreenTranslateSupport(
          canDrawOverlays: support.canDrawOverlays,
          notificationsAllowed: support.notificationsAllowed,
          canAddTile: support.canAddTile,
        ),
        busy: false,
      ),
    );
  }

  /// Offers the "Translate screen" tile for Quick Settings.
  Future<void> addTile() async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final result = await _controls.requestAddTile();
    if (isClosed) return;
    final idle = state.copyWith(busy: false);
    switch (result) {
      case TileRequestResult.added:
        emit(idle.withNotice(ScreenTranslateNotice.tileAdded));
      case TileRequestResult.alreadyAdded:
        emit(idle.withNotice(ScreenTranslateNotice.tileAlreadyAdded));
      case TileRequestResult.failed:
        emit(idle.withNotice(ScreenTranslateNotice.tileFailed));
      case TileRequestResult.notAdded:
      case TileRequestResult.unsupported:
        emit(idle);
    }
  }
}
