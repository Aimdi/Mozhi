import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';

/// The word to look up; Enter (or the arrow button) looks it up.
class DictionarySearchField extends StatefulWidget {
  const new({this.autofocus = false, super.key});

  /// Focus the field when it first shows (no word given).
  final bool autofocus;

  @override
  State<DictionarySearchField> createState() => _DictionarySearchFieldState();
}

class _DictionarySearchFieldState extends State<DictionarySearchField> {
  late final TextEditingController _controller;
  final _focusNode = FocusNode(debugLabel: 'dictionary_search_field');

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
    _focusNode.dispose();
    super.dispose();
  }

  /// Looks the word up. Keyboard focus stays where it is (the field or the
  /// Look up button) instead of leaving the page (WCAG 2.4.3); only the
  /// on-screen keyboard is put away so the entry shows.
  void _lookUp() {
    final cubit = context.read<DictionaryCubit>();
    if (cubit.state.word.trim().isEmpty) return;
    if (_hasSoftKeyboard) {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    }
    unawaited(cubit.lookUp());
  }

  /// Clears the word and moves focus to the field, as the Clear button
  /// that had it goes away.
  void _clear() {
    context.read<DictionaryCubit>().clear();
    _focusNode.requestFocus();
  }

  /// Touch platforms, where the field brings up an on-screen keyboard.
  static bool get _hasSoftKeyboard =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<DictionaryCubit>();
    final (word, hasEngine) = context.select<DictionaryCubit, (String, bool)>(
      (cubit) => (cubit.state.word, cubit.state.hasEngine),
    );
    return BlocListener<DictionaryCubit, DictionaryState>(
      listenWhen: (previous, current) => previous.word != current.word,
      listener: (context, state) {
        if (_controller.text == state.word) return;
        _controller.value = TextEditingValue(
          text: state.word,
          selection: TextSelection.collapsed(offset: state.word.length),
        );
      },
      child: TextField(
        key: const Key('dictionary_search_field'),
        controller: _controller,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onChanged: cubit.setWord,
        // Enter looks up. Not via onSubmitted: without onEditingComplete
        // the field drops focus on Enter, and with onSubmitted it restarts
        // the input connection, bringing the on-screen keyboard back.
        onEditingComplete: _lookUp,
        textInputAction: TextInputAction.search,
        inputFormatters: [
          LengthLimitingTextInputFormatter(DictionaryCubit.maxWordLength),
        ],
        decoration: InputDecoration(
          // A label, unlike a hint, still names the field once it holds a
          // word (WCAG 4.1.2, 3.3.2).
          labelText: l10n.dictionarySearchHint,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (word.isNotEmpty)
                IconButton(
                  key: const Key('dictionary_clear'),
                  tooltip: l10n.commonClear,
                  icon: const Icon(Icons.close),
                  onPressed: _clear,
                ),
              IconButton.filled(
                key: const Key('dictionary_look_up'),
                tooltip: l10n.dictionaryLookUp,
                icon: const Icon(Icons.arrow_forward),
                onPressed: word.trim().isEmpty || !hasEngine ? null : _lookUp,
              ),
              const SizedBox(width: 4),
            ],
          ),
          filled: true,
          // A filled pill: the label floats inside it (an outline border
          // would put the label across its top edge).
          border: const UnderlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(28)),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
