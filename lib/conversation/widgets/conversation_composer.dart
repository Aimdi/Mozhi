import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_mic.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/widgets/side_colors.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// Text field, optional microphone and send button for one [side].
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
    final colors = ConversationSideColors.of(context, side);
    final language = context.select<ConversationCubit, Language>(
      (cubit) => cubit.state.languageOf(side),
    );
    final ready = context.select<TranslateCubit, bool>(
      (cubit) => cubit.state.engine != null,
    );
    final micBuilder = widget.micBuilder;

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: Key('conversation_input_${side.name}'),
              controller: _controller,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              textCapitalization: TextCapitalization.sentences,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: l10n.conversationInputHint(language.name),
                filled: true,
                fillColor: colors.container.withValues(alpha: 0.45),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(28)),
                  borderSide: BorderSide.none,
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
            builder: (context, value, _) => IconButton.filled(
              key: Key('conversation_send_${side.name}'),
              tooltip: l10n.conversationSend,
              style: IconButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.onAccent,
                minimumSize: const Size.square(48),
              ),
              icon: const Icon(Icons.send),
              onPressed: ready && value.text.trim().isNotEmpty ? _submit : null,
            ),
          ),
        ],
      ),
    );
  }
}
