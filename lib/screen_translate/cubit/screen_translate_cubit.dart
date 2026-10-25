import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';
import 'package:mozhi/screen_translate/cubit/screen_translate_state.dart';
import 'package:mozhi/screen_translate/screen_translate_host.dart';

export 'screen_translate_state.dart';

/// The screen-translate window's flow ([ScreenTranslateHost]):
///
/// 1. [start] waits for the screenshot ([ScreenTranslateHost.capture]),
///    while the window draws nothing ([ScreenTranslateState.isInvisible]).
///    A declined consent closes the window; a failed capture or a black
///    frame (an app that blocks screenshots) is reported.
/// 2. When Mozhi is locked ([AppLock.isLocked]), it asks to unlock before
///    showing anything ([ScreenTranslateStatus.unlocking]); a cancelled
///    prompt leaves a lock card ([unlock] tries again).
/// 3. The screenshot is shown ([ScreenTranslateStatus.ready]) and
///    translated by the image translation (`ImageTranslateCubit`, see the
///    view). Should the app lock again meanwhile, it is hidden until
///    unlocked.
///
/// [closeWindow], [openInApp] and [openLocation] leave the window.
class ScreenTranslateCubit extends Cubit<ScreenTranslateState> {
  new({required this._host, this._lock}) : super(const ScreenTranslateState());

  final ScreenTranslateHost _host;
  final AppLock? _lock;
  StreamSubscription<bool>? _lockChanges;
  bool _started = false;

  /// Takes the screenshot and shows it (once).
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final capture = await _host.capture();
    if (isClosed) return;
    switch (capture) {
      case ScreenCaptureDeclined():
        await _host.close();
      case ScreenCaptureFailed(:final reason):
        emit(
          state.copyWith(status: ScreenTranslateStatus.failed, failure: reason),
        );
      case ScreenCaptured(blank: true):
        emit(state.copyWith(status: ScreenTranslateStatus.blank));
      case ScreenCaptured(:final bytes):
        emit(
          state.copyWith(
            screenshot: PickedImage(
              bytes: bytes,
              mimeType: 'image/png',
              name: 'screenshot.png',
            ),
          ),
        );
        _lockChanges = _lock?.changes.listen(_onLockChanged);
        await _reveal();
    }
  }

  /// Asks to unlock again after a cancelled prompt.
  Future<void> unlock() async {
    if (state.status != ScreenTranslateStatus.locked) return;
    await _reveal();
  }

  /// Closes the window.
  Future<void> closeWindow() => _host.close();

  /// Continues with [text] (the recognised text) in the main window's
  /// translate tab.
  Future<void> openInApp(String text) => _host.openTextInApp(text);

  /// Continues at the app [location] in the main window.
  Future<void> openLocation(String location) =>
      _host.openLocationInApp(location);

  /// Shows the screenshot, once Mozhi is unlocked.
  Future<void> _reveal() async {
    final lock = _lock;
    if (lock != null && lock.isLocked) {
      emit(state.copyWith(status: ScreenTranslateStatus.unlocking));
      bool unlocked;
      try {
        unlocked = await lock.unlock();
      } on Object {
        unlocked = false;
      }
      if (isClosed) return;
      if (!unlocked || lock.isLocked) {
        emit(state.copyWith(status: ScreenTranslateStatus.locked));
        return;
      }
    }
    emit(state.copyWith(status: ScreenTranslateStatus.ready));
  }

  void _onLockChanged(bool locked) {
    if (isClosed) return;
    if (locked && state.status == ScreenTranslateStatus.ready) {
      emit(state.copyWith(status: ScreenTranslateStatus.locked));
    } else if (!locked && state.status == ScreenTranslateStatus.locked) {
      emit(state.copyWith(status: ScreenTranslateStatus.ready));
    }
  }

  @override
  Future<void> close() async {
    await _lockChanges?.cancel();
    await super.close();
  }
}
