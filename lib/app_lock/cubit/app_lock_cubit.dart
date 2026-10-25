import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/app_lock/cubit/app_lock_state.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';

export 'app_lock_state.dart';

/// The lock gate's state over an [AppLockController]: its status, and the
/// unlock prompt the lock screen opens ([unlock], by itself once per return
/// with [autoUnlock]).
class AppLockCubit extends Cubit<AppLockState> {
  new(this._lock) : super(AppLockState(status: _lock.status)) {
    _statuses = _lock.statusChanges.listen(_onStatus);
  }

  final AppLockController _lock;
  late final StreamSubscription<AppLockStatus> _statuses;

  void _onStatus(AppLockStatus status) {
    if (isClosed) return;
    emit(
      state.copyWith(
        status: status,
        // A new lock starts without the last attempt's message.
        failed: status == AppLockStatus.unlocked ? false : null,
      ),
    );
  }

  /// Shows the system prompt (the lock screen's Unlock button).
  Future<void> unlock() async {
    if (isClosed || state.prompting) return;
    emit(state.copyWith(prompting: true, failed: false));
    final unlocked = await _lock.unlock();
    if (isClosed) return;
    emit(
      state.copyWith(status: _lock.status, prompting: false, failed: !unlocked),
    );
  }

  /// Opens the prompt by itself when it is due
  /// ([AppLockController.takeAutoPrompt]: once at start and once per
  /// return to the app, while locked). Call it while the app is in the
  /// foreground.
  Future<void> autoUnlock() async {
    if (isClosed || state.prompting || !_lock.takeAutoPrompt()) return;
    await unlock();
  }

  @override
  Future<void> close() async {
    await _statuses.cancel();
    await super.close();
  }
}
