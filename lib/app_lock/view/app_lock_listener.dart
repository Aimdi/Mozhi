import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app_lock/cubit/app_lock_cubit.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';

/// The lock event of the app lock for a screen: [onLock] runs when the app
/// locks while this widget is built (the screen stays built, hidden under
/// the lock screen, see `AppLockGate`), [onUnlock] when it is unlocked
/// after that. Screens use it to drop what they show from memory and to
/// read it again.
///
/// Only a lock that follows an unlock counts: a screen is never built
/// before the first unlock, and the short check of a return to the app
/// (`AppLock.isLocked` while it runs) is not a lock. Without an app lock
/// gate above (the web, tests) nothing happens.
class AppLockListener extends StatefulWidget {
  const new({required this.child, this.onLock, this.onUnlock, super.key});

  /// Runs with this widget's context when the app locks.
  final void Function(BuildContext context)? onLock;

  /// Runs with this widget's context when the app is unlocked after
  /// [onLock].
  final void Function(BuildContext context)? onUnlock;

  final Widget child;

  @override
  State<AppLockListener> createState() => _AppLockListenerState();
}

class _AppLockListenerState extends State<AppLockListener> {
  /// Whether [AppLockListener.onLock] ran and [AppLockListener.onUnlock]
  /// not yet.
  bool _locked = false;

  @override
  Widget build(BuildContext context) {
    // The gate's cubit (rebuilt only when it is another one).
    final cubit = context.select<AppLockCubit?, AppLockCubit?>(
      (cubit) => cubit,
    );
    if (cubit == null) return widget.child;
    return BlocListener<AppLockCubit, AppLockState>(
      bloc: cubit,
      listenWhen: (previous, current) => previous.status != current.status,
      listener: (context, state) {
        if (state.status == AppLockStatus.locked && !_locked) {
          _locked = true;
          widget.onLock?.call(context);
        } else if (state.unlocked && _locked) {
          _locked = false;
          widget.onUnlock?.call(context);
        }
      },
      child: widget.child,
    );
  }
}
