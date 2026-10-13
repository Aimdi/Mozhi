import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';

/// Whether the user has to press "Translate" (instant translation is off
/// for the current engine kind).
bool needsTranslateButton(TranslateState state, AppSettings settings) {
  if (state.compareMode) return false;
  return state.isAiEngine
      ? !settings.instantTranslateAi
      : !settings.instantTranslate;
}

/// The source text field with paste/clear/listen actions, character count
/// and (when instant translation is off) a "Translate" button.
class InputCard extends StatefulWidget {
  const new({this.minLines = 4, super.key});

  final int minLines;

  @override
  State<InputCard> createState() => _InputCardState();
}

class _InputCardState extends State<InputCard> {
  late final TranslateCubit _cubit = context.read<TranslateCubit>();
  late final TextEditingController _controller = TextEditingController(
    text: _cubit.state.input,
  );
  final _focusNode = FocusNode(debugLabel: 'translate_input');

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Mirrors external input changes (share, history, swap, clear) into the
  /// field without touching the cursor while the user types.
  void _syncController(String input) {
    if (_controller.text == input) return;
    _controller.value = TextEditingValue(
      text: input,
      selection: TextSelection.collapsed(offset: input.length),
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || text == null || text.isEmpty) return;
    _syncController(text);
    _cubit.setInput(text);
  }

  void _clear() {
    _syncController('');
    _cubit.clear();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final settings = context.watch<SettingsCubit>().state;
    return BlocConsumer<TranslateCubit, TranslateState>(
      listenWhen: (previous, current) => previous.input != current.input,
      listener: (context, state) => _syncController(state.input),
      builder: (context, state) {
        final input = state.input;
        final empty = input.trim().isEmpty;
        final transliteration = state.result?.sourceTransliteration ?? '';
        final showTranslate = needsTranslateButton(state, settings);
        return Card(
          key: const Key('translate_input_card'),
          margin: EdgeInsets.zero,
          elevation: 0,
          color: theme.colorScheme.surfaceContainerLow,
          shape: const RoundedRectangleBorder(
            borderRadius: TranslateLayout.cardBorderRadius,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: TextField(
                          key: const Key('translate_input_field'),
                          controller: _controller,
                          focusNode: _focusNode,
                          onChanged: _cubit.setInput,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          minLines: widget.minLines,
                          maxLines: null,
                          style: TranslateLayout.textStyle(
                            context,
                            input.length,
                          ),
                          decoration: InputDecoration(
                            hintText: l10n.translateInputHint,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 8,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (input.isNotEmpty)
                      IconButton(
                        key: const Key('translate_clear_button'),
                        tooltip: l10n.commonClear,
                        icon: const Icon(Icons.close),
                        onPressed: _clear,
                      ),
                  ],
                ),
                if (settings.showTransliteration &&
                    transliteration.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 12, bottom: 4),
                    child: Text(
                      transliteration,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 4,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListenButton(
                          id: 'source',
                          text: input,
                          languageCode: state.effectiveSourceCode,
                        ),
                        if (input.isEmpty)
                          IconButton(
                            key: const Key('translate_paste_button'),
                            tooltip: l10n.translatePaste,
                            icon: const Icon(Icons.content_paste),
                            onPressed: () => unawaited(_paste()),
                          ),
                        if (input.isNotEmpty)
                          Flexible(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Text(
                                l10n.translateCharacterCount(
                                  input.characters.length,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (showTranslate)
                      Tooltip(
                        message: l10n.translateShortcutTranslate,
                        child: FilledButton.icon(
                          key: const Key('translate_translate_button'),
                          onPressed: empty
                              ? null
                              : () => unawaited(_cubit.translate()),
                          icon: const Icon(Icons.translate),
                          label: Text(l10n.translateTranslateButton),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
