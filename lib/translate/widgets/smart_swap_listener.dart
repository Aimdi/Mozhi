import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

/// How long the smart swap snack bar stays. Under accessible navigation
/// (screen readers, switch access) it stays until it is dismissed, with a
/// close button, so that there is time to reach Undo (WCAG 2.2.1).
const smartSwapNoticeDuration = Duration(seconds: 6);

/// Shows each `TranslateState.smartSwapNotice` once as a snack bar,
/// "Translating into X instead", whose Undo action calls
/// `TranslateCubit.undoSmartSwap`, then consumes the notice
/// (`TranslateCubit.consumeSmartSwapNotice`).
///
/// A notice that is already pending when this widget is built (e.g. a
/// shared text was translated before the translate screen was shown) is
/// shown after the first frame.
class SmartSwapListener extends StatefulWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  State<SmartSwapListener> createState() => _SmartSwapListenerState();
}

class _SmartSwapListenerState extends State<SmartSwapListener> {
  /// Id of the last notice shown, so none is shown twice.
  int? _shownId;

  @override
  void initState() {
    super.initState();
    if (context.read<TranslateCubit>().state.smartSwapNotice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _show(context.read<TranslateCubit>().state);
      });
    }
  }

  void _show(TranslateState state) {
    final notice = state.smartSwapNotice;
    if (notice == null || notice.id == _shownId) return;
    _shownId = notice.id;
    final cubit = context.read<TranslateCubit>();
    final l10n = context.l10n;
    final accessible = MediaQuery.accessibleNavigationOf(context);
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: ValueKey('translate_smart_swap_${notice.id}'),
          content: Text(l10n.translateSmartSwapNotice(notice.newTarget.name)),
          duration: smartSwapNoticeDuration,
          persist: accessible,
          showCloseIcon: accessible,
          action: SnackBarAction(
            label: l10n.commonUndo,
            onPressed: () => unawaited(cubit.undoSmartSwap()),
          ),
        ),
      );
    cubit.consumeSmartSwapNotice();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<TranslateCubit, TranslateState>(
      listenWhen: (previous, current) =>
          current.smartSwapNotice != null &&
          current.smartSwapNotice != previous.smartSwapNotice,
      listener: (context, state) => _show(state),
      child: widget.child,
    );
  }
}
