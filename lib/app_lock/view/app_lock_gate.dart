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
/// the lock screen, and nothing of the app (while it finds out, at start,
/// an empty surface).
///
/// Until the app was unlocked once, [child] (the router) is not built at
/// all: no screen opens and nothing a link asks for starts. From then on
/// it stays built while locked, so what runs in it keeps running (a
/// document translation, a conversation, Transcribe), but hidden: under
/// the lock screen, [Offstage] (nothing painted, no touch reaches it, left
/// out of the screen reader's tree), its animations stopped
/// ([TickerMode]) and out of the keyboard's reach ([ExcludeFocus]: a text
/// field in it loses the focus, which closes the on-screen keyboard). The
/// lock screen has a [ScaffoldMessenger] of its own then, so messages of
/// the hidden screens don't show on it.
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

  /// The [Offstage] that holds [child] once it was built.
  static const contentKey = Key('app_lock_content');

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

  /// Whether [AppLockGate.child] was shown once: from then on it stays
  /// built, hidden while locked.
  bool _childBuilt = false;

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
        builder: (context, state) {
          final locked = !state.unlocked;
          if (!locked) _childBuilt = true;
          if (!_childBuilt) return _lockScreen(state);
          return Stack(
            fit: StackFit.expand,
            children: [
              Offstage(
                key: AppLockGate.contentKey,
                offstage: locked,
                child: TickerMode(
                  enabled: !locked,
                  child: ExcludeFocus(excluding: locked, child: widget.child),
                ),
              ),
              if (locked) ScaffoldMessenger(child: _lockScreen(state)),
            ],
          );
        },
      ),
    );
  }

  Widget _lockScreen(AppLockState state) => switch (state.status) {
    AppLockStatus.locked when widget.compact => AppLockCompactScreen(
      prompting: state.prompting,
      failed: state.failed,
      onUnlock: () => unawaited(_cubit.unlock()),
      onClose: () => widget.onClose?.call(),
    ),
    AppLockStatus.locked => AppLockScreen(
      prompting: state.prompting,
      failed: state.failed,
      onUnlock: () => unawaited(_cubit.unlock()),
    ),
    AppLockStatus.checking ||
    AppLockStatus.unlocked => _Blank(compact: widget.compact),
  };
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
