import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';

/// The go button of the proofreading composer (the go arrow of the
/// translate screen): proofreads the input; disabled without input or an
/// engine and while checking. Its accessible name is "Proofread"
/// ("Checking…" while a check runs, with a progress ring around it); the
/// tooltip adds the keyboard shortcut (Ctrl/Cmd+Enter).
///
/// On touch screens it puts the on-screen keyboard away, so the result
/// shows.
class ProofreadButton extends StatelessWidget {
  const new({super.key});

  /// Touch platforms, where the field brings up an on-screen keyboard.
  static bool get _hasSoftKeyboard =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (canProofread, isLoading) = context
        .select<ProofreadCubit, (bool, bool)>(
          (cubit) => (cubit.state.canProofread, cubit.state.isLoading),
        );
    return ComposerGoButton(
      label: isLoading ? l10n.proofreadActionBusy : l10n.proofreadAction,
      tooltip: isLoading
          ? l10n.proofreadActionBusy
          : l10n.proofreadShortcutTooltip,
      busy: isLoading,
      onPressed: canProofread
          ? () {
              if (_hasSoftKeyboard) {
                unawaited(
                  SystemChannels.textInput.invokeMethod<void>('TextInput.hide'),
                );
              }
              unawaited(context.read<ProofreadCubit>().proofread());
            }
          : null,
    );
  }
}
