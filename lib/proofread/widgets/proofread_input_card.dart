import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:mozhi/voice/voice.dart'
    show SpeechInputService, VoiceInputButton;

/// The app-wide [SpeechInputService], or null when none is provided (voice
/// input is then not offered).
SpeechInputService? _speechInputServiceOf(BuildContext context) {
  try {
    return context.read<SpeechInputService>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// The text to proofread, flat like a compose box: the multiline field
/// with the microphone (when voice input is available) at its top end,
/// then a toolbar of accent paste and clear actions and the character
/// count. [compact] (the docked composer of the empty screen) leaves the
/// toolbar out and keeps paste next to the microphone while the field is
/// empty. Ctrl/Cmd+Enter proofreads.
///
/// Dictated text is appended to the input. [focusNode] is the field's
/// focus node (the screen follows it to leave the empty screen); without
/// one the card makes its own.
class ProofreadInputCard extends StatefulWidget {
  const new({
    this.compact = false,
    this.focusNode,
    this.minLines = 6,
    super.key,
  });

  /// Whether the toolbar is left out (the empty screen's composer).
  final bool compact;

  /// The text field's focus node; null: the card's own.
  final FocusNode? focusNode;

  final int minLines;

  @override
  State<ProofreadInputCard> createState() => _ProofreadInputCardState();
}

class _ProofreadInputCardState extends State<ProofreadInputCard> {
  late final TextEditingController _controller;
  FocusNode? _ownFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ??
      (_ownFocusNode ??= FocusNode(debugLabel: 'proofread_input'));

  static final _endsWithSpace = RegExp(r'\s$');

  /// The input before the current dictation; recognised speech is appended
  /// to it (each partial result replaces the previous one).
  String? _dictationBase;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: context.read<ProofreadCubit>().state.input,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _ownFocusNode?.dispose();
    super.dispose();
  }

  /// Inserts the clipboard text at the cursor, replacing the selection (or
  /// appends it when the field has no cursor), so typed text is kept.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || text == null || text.isEmpty) return;
    final value = _controller.value;
    final current = value.text;
    final selection = value.selection;
    final start = selection.isValid
        ? selection.start.clamp(0, current.length)
        : current.length;
    final end = selection.isValid
        ? selection.end.clamp(start, current.length)
        : current.length;
    final combined = current.replaceRange(start, end, text);
    _controller.value = TextEditingValue(
      text: combined,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    context.read<ProofreadCubit>().setInput(combined);
  }

  void _proofread() {
    final cubit = context.read<ProofreadCubit>();
    if (cubit.state.canProofread) unawaited(cubit.proofread());
  }

  /// Clears the input and keeps the focus in the field, as the Clear
  /// button that had it goes away.
  void _clear() {
    context.read<ProofreadCubit>().clear();
    _focusNode.requestFocus();
  }

  void _onListeningChanged(bool listening) {
    _dictationBase = listening ? _controller.text : null;
  }

  void _onVoiceResult(String text, {required bool isFinal}) {
    final spoken = text.trim();
    final base = _dictationBase ?? _controller.text;
    // A later utterance of the same session goes after this one.
    _dictationBase = isFinal ? null : base;
    if (spoken.isEmpty) return;
    final separator = base.isEmpty || _endsWithSpace.hasMatch(base) ? '' : ' ';
    final combined = '$base$separator$spoken';
    _controller.value = TextEditingValue(
      text: combined,
      selection: TextSelection.collapsed(offset: combined.length),
    );
    context.read<ProofreadCubit>().setInput(combined);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = AppPalette.of(context);
    final (input, variety) = context.select<ProofreadCubit, (String, String?)>(
      (cubit) => (cubit.state.input, cubit.state.variety?.code),
    );
    final compact = widget.compact;
    final paste = IconButton(
      key: const Key('proofread_paste'),
      tooltip: l10n.proofreadPaste,
      onPressed: _paste,
      color: colors.primary,
      icon: const Icon(Icons.content_paste_rounded),
    );
    final speech = _speechInputServiceOf(context);
    final textStyle = TranslateLayout.textStyle(context, input.length);

    return BlocListener<ProofreadCubit, ProofreadState>(
      listenWhen: (previous, current) => previous.input != current.input,
      listener: (context, state) {
        if (_controller.text == state.input) return;
        _controller.value = TextEditingValue(
          text: state.input,
          selection: TextSelection.collapsed(offset: state.input.length),
        );
      },
      child: Semantics(
        container: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(
                        LogicalKeyboardKey.enter,
                        control: true,
                      ): _proofread,
                      const SingleActivator(
                        LogicalKeyboardKey.enter,
                        meta: true,
                      ): _proofread,
                    },
                    // The hint disappears once there is text, so name the
                    // field explicitly. As its own container the field's
                    // node does not merge into the card's, which would
                    // also absorb the character count below and make it
                    // part of the field's name.
                    child: Semantics(
                      container: true,
                      label: l10n.proofreadInputLabel,
                      child: TextField(
                        key: const Key('proofread_input'),
                        controller: _controller,
                        focusNode: _focusNode,
                        enableIMEPersonalizedLearning: imeLearningAllowed(
                          context,
                        ),
                        onChanged: context.read<ProofreadCubit>().setInput,
                        minLines: widget.minLines,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        style: textStyle,
                        decoration: InputDecoration(
                          hintText: l10n.proofreadInputHint,
                          hintMaxLines: 3,
                          border: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          filled: false,
                          isDense: true,
                          hintStyle: TranslateLayout.textStyle(
                            context,
                            0,
                          )?.copyWith(color: palette.secondaryText),
                          contentPadding: const EdgeInsetsDirectional.fromSTEB(
                            4,
                            14,
                            8,
                            8,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // The top end, like the translate composer: paste (empty
                // composer) and the microphone, in one place in both
                // layouts so a dictation keeps going when the screen
                // changes.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (compact && input.isEmpty) paste,
                    if (speech != null)
                      IconButtonTheme(
                        data: IconButtonThemeData(
                          style: IconButton.styleFrom(
                            foregroundColor: colors.primary,
                          ),
                        ),
                        child: VoiceInputButton.standalone(
                          key: const Key('proofread_voice_input'),
                          service: speech,
                          // Null: the device's recognition language.
                          languageCode: variety,
                          onResult: _onVoiceResult,
                          onListeningChanged: _onListeningChanged,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            if (!compact) ...[
              Row(
                children: [
                  paste,
                  if (input.isNotEmpty)
                    IconButton(
                      key: const Key('proofread_clear'),
                      tooltip: l10n.commonClear,
                      onPressed: _clear,
                      color: colors.primary,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(end: 4),
                      child: Text(
                        l10n.proofreadCharacterCount(input.characters.length),
                        textAlign: TextAlign.end,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: palette.secondaryText,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const Hairline(),
            ],
          ],
        ),
      ),
    );
  }
}
