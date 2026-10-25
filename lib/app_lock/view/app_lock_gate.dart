import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app_lock/cubit/app_lock_cubit.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/app_lock/data/app_lock_platform.dart';
import 'package:mozhi/app_lock/view/app_lock_screen.dart';
import 'package:mozhi/l10n/l10n.dart';

/// The app lock's gate above the router: while [lock] is locked it shows
/// the lock screen *instead of* [child], so none of the app's routes is
/// built (nothing to see, read aloud or tap behind it); while it finds out
/// (at start) it shows an empty surface.
///
/// It tells [lock] when the app goes to the background and comes back
/// ([AppLock.noteBackground], [AppLock.noteForeground]), gives it the
/// prompt's texts in the app's language, and opens the system prompt by
/// itself once at start and once per return while locked; a cancelled
/// prompt leaves the Unlock button.
///
/// [compact] is for the translucent quick translate window: a card at the
/// bottom above the other app, whose Close calls [onClose]. With
/// [blocking] false (the screen-translate window, which gates itself
/// before it shows anything) [child] is always shown and nothing is drawn
/// or prompted, but the lifecycle still reaches [lock].
class AppLockGate extends StatefulWidget {
  const new({
    required this.lock,
    required this.child,
    this.compact = false,
    this.blocking = true,
    this.onClose,
    super.key,
  });

  final AppLockController lock;
  final Widget child;
  final bool compact;
  final bool blocking;

  /// Closes the window ([compact]).
  final VoidCallback? onClose;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  late AppLockCubit _cubit;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _cubit = AppLockCubit(widget.lock);
    _lifecycle = AppLifecycleListener(
      onHide: () => widget.lock.noteBackground(),
      onShow: () => widget.lock.noteForeground(),
      onResume: _autoUnlock,
    );
    // At start: once the first frame is up (the prompt needs a window).
    SchedulerBinding.instance.addPostFrameCallback((_) => _autoUnlock());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final l10n = context.l10n;
    widget.lock
      ..promptTexts = AppLockPromptTexts(
        title: l10n.appLockPromptTitle,
        subtitle: l10n.appLockPromptSubtitle,
        fallback: l10n.appLockPromptFallback,
      )
      ..confirmTexts = AppLockPromptTexts(
        title: l10n.appLockConfirmTitle,
        subtitle: l10n.appLockConfirmSubtitle,
        fallback: l10n.appLockPromptFallback,
      );
  }

  @override
  void didUpdateWidget(AppLockGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lock != widget.lock) {
      unawaited(_cubit.close());
      _cubit = AppLockCubit(widget.lock);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_cubit.close());
    super.dispose();
  }

  /// Whether the app is in the foreground (the prompt needs it). Unknown
  /// counts as yes: some embedders never report it.
  static bool get _inForeground {
    final state = SchedulerBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _autoUnlock() {
    if (!mounted || !widget.blocking || !_inForeground) return;
    unawaited(_cubit.autoUnlock());
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.blocking) return widget.child;
    return BlocProvider.value(
      value: _cubit,
      child: BlocConsumer<AppLockCubit, AppLockState>(
        listenWhen: (previous, current) =>
            previous.status != current.status &&
            current.status == AppLockStatus.locked,
        listener: (context, state) => _autoUnlock(),
        builder: (context, state) => switch (state.status) {
          AppLockStatus.unlocked => widget.child,
          AppLockStatus.checking => _Blank(compact: widget.compact),
          AppLockStatus.locked =>
            widget.compact
                ? AppLockCompactScreen(
                    prompting: state.prompting,
                    failed: state.failed,
                    onUnlock: () => unawaited(_cubit.unlock()),
                    onClose: () => widget.onClose?.call(),
                  )
                : AppLockScreen(
                    prompting: state.prompting,
                    failed: state.failed,
                    onUnlock: () => unawaited(_cubit.unlock()),
                  ),
        },
      ),
    );
  }
}

/// What shows while the lock finds out: the window's plain background
/// (transparent in the translucent windows).
class _Blank extends StatelessWidget {
  const new({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const Key('app_lock_checking'),
    color: compact ? Colors.transparent : Theme.of(context).colorScheme.surface,
    child: const SizedBox.expand(),
  );
}
