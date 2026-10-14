import 'dart:async';

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
    super.dispose();
  }

  void _lookUp() {
    final cubit = context.read<DictionaryCubit>();
    if (cubit.state.word.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    unawaited(cubit.lookUp());
  }

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
        autofocus: widget.autofocus,
        onChanged: cubit.setWord,
        onSubmitted: (_) => _lookUp(),
        textInputAction: TextInputAction.search,
        inputFormatters: [
          LengthLimitingTextInputFormatter(DictionaryCubit.maxWordLength),
        ],
        decoration: InputDecoration(
          hintText: l10n.dictionarySearchHint,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (word.isNotEmpty)
                IconButton(
                  key: const Key('dictionary_clear'),
                  tooltip: l10n.commonClear,
                  icon: const Icon(Icons.close),
                  onPressed: cubit.clear,
                ),
              IconButton(
                key: const Key('dictionary_look_up'),
                tooltip: l10n.dictionaryLookUp,
                icon: const Icon(Icons.arrow_forward),
                onPressed: word.trim().isEmpty || !hasEngine ? null : _lookUp,
              ),
            ],
          ),
          filled: true,
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(28)),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
