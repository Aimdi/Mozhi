import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_mic.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// A round pill text field (with the side's language avatar), optional
/// microphone and send button for one [side], on a translucent bar with a
/// hairline on top.
///
/// Sending (button or keyboard action) translates the text for the other
/// side and clears the field. Dictation from the [micBuilder] button
/// replaces the text while the person speaks and sends the final result.
class ConversationComposer extends StatefulWidget {
  const new({required this.side, this.micBuilder, super.key});

  final ConversationSide side;
  final ConversationMicBuilder? micBuilder;

  @override
  State<ConversationComposer> createState() => _ConversationComposerState();
}

class _ConversationComposerState extends State<ConversationComposer> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    // Keep the text until an engine is available.
    if (context.read<TranslateCubit>().state.engine == null) return;
    _controller.clear();
    unawaited(context.read<ConversationCubit>().submit(widget.side, text));
  }

  void _onDictation(String text, {required bool isFinal}) {
    if (!mounted) return;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    if (isFinal) _submit();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final side = widget.side;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final language = context.select<ConversationCubit, Language>(
      (cubit) => cubit.state.languageOf(side),
    );
    final ready = context.select<TranslateCubit, bool>(
      (cubit) => cubit.state.engine != null,
    );
    final micBuilder = widget.micBuilder;

    // Nothing scrolls under the composer, so the bar skips the blur.
    return BlurBar(
      top: true,
      sigma: 0,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: Key('conversation_input_${side.name}'),
                controller: _controller,
                enableIMEPersonalizedLearning: imeLearningAllowed(context),
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => _submit(),
                // The theme's outlined, rounded field (no fill), like the
                // other text fields.
                decoration: InputDecoration(
                  hintText: l10n.conversationInputHint(
                    context.languageName(language),
                  ),
                  hintStyle: TextStyle(color: palette.secondaryText),
                  prefixIcon: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 8, end: 8),
                    child: LanguageAvatar(
                      code: language.isCustom ? language.name : language.code,
                      size: 28,
                    ),
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  contentPadding: const EdgeInsetsDirectional.fromSTEB(
                    4,
                    12,
                    20,
                    12,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            if (micBuilder != null)
              micBuilder(
                context,
                ConversationMicRequest(
                  side: side,
                  language: language,
                  onResult: _onDictation,
                ),
              ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, _) => IconButton(
                key: Key('conversation_send_${side.name}'),
                tooltip: l10n.conversationSend,
                color: theme.colorScheme.primary,
                icon: const Icon(Icons.send_rounded),
                onPressed: ready && value.text.trim().isNotEmpty
                    ? _submit
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
