import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';

/// Looks the word of [context]'s [DictionaryCubit] up (nothing for a
/// blank word). Only the on-screen keyboard is put away so the entry
/// shows; keyboard focus is left to the screen (the entry's "New look-up"
/// button takes it, WCAG 2.4.3).
void lookUpDictionaryWord(BuildContext context) {
  final cubit = context.read<DictionaryCubit>();
  if (cubit.state.word.trim().isEmpty) return;
  if (_hasSoftKeyboard) {
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }
  unawaited(cubit.lookUp());
}

/// Touch platforms, where a text field brings up an on-screen keyboard.
bool get _hasSoftKeyboard =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// The word to look up, the text field of the dictionary's composer: no
/// box of its own (the composer card is the box) and the compose-like
/// text size of the translate screen. Enter looks the word up
/// ([lookUpDictionaryWord]); the go button is on the composer's bar and
/// Clear at its top end (`DictionaryClearButton`).
class DictionarySearchField extends StatefulWidget {
  const new({this.autofocus = false, this.focusNode, super.key});

  /// Focus the field when it first shows (no word given).
  final bool autofocus;

  /// The field's focus node (the screen focuses it for a new look-up, and
  /// Clear hands the focus to it); null: the field's own.
  final FocusNode? focusNode;

  @override
  State<DictionarySearchField> createState() => _DictionarySearchFieldState();
}

class _DictionarySearchFieldState extends State<DictionarySearchField> {
  late final TextEditingController _controller;
  FocusNode? _ownFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ??
      (_ownFocusNode ??= FocusNode(debugLabel: 'dictionary_search_field'));

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: context.read<DictionaryCubit>().state.word,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _ownFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = AppPalette.of(context);
    final cubit = context.read<DictionaryCubit>();
    return BlocListener<DictionaryCubit, DictionaryState>(
      listenWhen: (previous, current) => previous.word != current.word,
      listener: (context, state) {
        if (_controller.text == state.word) return;
        _controller.value = TextEditingValue(
          text: state.word,
          selection: TextSelection.collapsed(offset: state.word.length),
        );
      },
      // The hint disappears once there is a word, so the field is named
      // explicitly (WCAG 4.1.2, 3.3.2).
      child: Semantics(
        label: l10n.dictionarySearchHint,
        child: TextField(
          key: const Key('dictionary_search_field'),
          controller: _controller,
          focusNode: _focusNode,
          enableIMEPersonalizedLearning: imeLearningAllowed(context),
          autofocus: widget.autofocus,
          onChanged: cubit.setWord,
          // Enter looks up. Not via onSubmitted: without onEditingComplete
          // the field drops focus on Enter, and with onSubmitted it
          // restarts the input connection, bringing the on-screen keyboard
          // back.
          onEditingComplete: () => lookUpDictionaryWord(context),
          textInputAction: TextInputAction.search,
          inputFormatters: [
            LengthLimitingTextInputFormatter(DictionaryCubit.maxWordLength),
          ],
          style: TranslateLayout.textStyle(context, 0),
          decoration: InputDecoration(
            hintText: l10n.dictionarySearchHint,
            hintStyle: TranslateLayout.textStyle(
              context,
              0,
            )?.copyWith(color: palette.secondaryText),
            hintMaxLines: 2,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            isDense: true,
            contentPadding: const EdgeInsetsDirectional.fromSTEB(10, 14, 4, 14),
          ),
        ),
      ),
    );
  }
}
