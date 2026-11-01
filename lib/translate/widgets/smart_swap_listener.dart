import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

/// Shows each `TranslateState.smartSwapNotice` once as a snack bar,
/// "Translating into X instead", whose Undo action calls
/// `TranslateCubit.undoSmartSwap`, then consumes the notice
/// (`TranslateCubit.consumeSmartSwapNotice`).
///
/// The snack bar stays until it is dismissed (close button) or replaced,
/// for everyone: the focus is usually in the input, and keyboard users
/// (with or without a screen reader) need time to reach Undo, which comes
/// late in the traversal order (WCAG 2.2.1).
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
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: ValueKey('translate_smart_swap_${notice.id}'),
          content: Text(
            l10n.translateSmartSwapNotice(
              context.languageName(notice.newTarget),
            ),
          ),
          persist: true,
          showCloseIcon: true,
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
