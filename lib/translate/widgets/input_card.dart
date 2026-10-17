import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/widgets/image_translate_button.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/alignment_highlight.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';
import 'package:mozhi/translate/widgets/meaning_check_panel.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:mozhi/usage/usage.dart' show TokenEstimateLabel;
import 'package:mozhi/voice/voice.dart'
    show SpeechInputService, VoiceInputButton;

/// Whether the user has to press "Translate" (instant translation is off
/// for the current engine kind).
bool needsTranslateButton(TranslateState state, AppSettings settings) {
  if (state.compareMode) return false;
  return state.isAiEngine
      ? !settings.instantTranslateAi
      : !settings.instantTranslate;
}

/// Direction of the source text: the chosen source language's, or (when
/// detecting) the direction of the typed characters, falling back to the
/// detected language.
TextDirection? inputTextDirection(TranslateState state) {
  if (!state.source.isAuto) return textDirectionForLanguage(state.source);
  return textDirectionForText(state.input) ??
      textDirectionForCode(state.result?.detectedSource);
}

/// The limit the input was cut to when `TranslateState.inputTruncated` is
/// set: text from outside the app is cut to
/// [TranslateCubit.maxExternalInputLength], anything else to
/// [TranslateCubit.maxInputLength].
int truncatedInputLimit(TranslateState state) =>
    state.input.length > TranslateCubit.maxExternalInputLength
    ? TranslateCubit.maxInputLength
    : TranslateCubit.maxExternalInputLength;

/// Whether the alignment in [state] is loaded for [text] (the field's
/// current text).
bool _alignmentFits(TranslateState state, String text) =>
    state.alignmentStatus == ExtraStatus.ready &&
    state.alignment.isNotEmpty &&
    state.input == text;

/// The source phrases of the loaded alignment when it is for [text] (the
/// field's current text), else empty.
List<TextRange> inputAlignmentPhrases(TranslateState state, String text) => [
  if (_alignmentFits(state, text))
    for (final span in state.alignment)
      TextRange(start: span.sourceStart, end: span.sourceEnd),
];

/// The source range of the focused alignment pair
/// (`TranslateState.focusedAlignment`) when the alignment is loaded for
/// [text] (the field's current text), else null.
TextRange? inputAlignmentHighlight(TranslateState state, String text) {
  final span = state.focusedAlignment;
  if (span == null || !_alignmentFits(state, text)) return null;
  return TextRange(start: span.sourceStart, end: span.sourceEnd);
}

/// Index of the alignment pair whose source phrase holds the cursor at
/// [offset] (the character after it, else the one before it), or null.
int? inputAlignmentIndexAt(TranslateState state, int offset) =>
    state.alignmentIndexAtSource(offset) ??
    (offset > 0 ? state.alignmentIndexAtSource(offset - 1) : null);

/// The app-wide [SpeechInputService], or null when none is provided (voice
/// input is then not offered).
SpeechInputService? _speechInputServiceOf(BuildContext context) {
  try {
    return context.read<SpeechInputService>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// The source text field with listen/voice/image/paste/clear actions,
/// character count (plus a token estimate for AI engines), a notice when
/// long text was shortened and (when instant translation is off) a
/// "Translate" button. Esc clears the field while it is focused and not
/// empty.
///
/// The field is limited to [TranslateCubit.maxInputLength] characters;
/// longer pasted text is passed on whole so the cubit cuts it and reports
/// it (`TranslateState.inputTruncated`). Voice input is offered when a
/// [SpeechInputService] is provided above; dictated text is appended to the
/// input.
///
/// When a phrase alignment is loaded (`TranslateCubit.loadAlignment`), the
/// aligned source phrases are underlined in the field and the phrase of the
/// focused pair is highlighted ([HighlightTextEditingController]); moving
/// the cursor into an aligned phrase focuses its pair
/// (`TranslateCubit.focusAlignment`), and any edit clears the alignment.
/// The difference highlighted in the meaning check
/// (`TranslateState.focusedMeaningIssue`) is highlighted the same way.
class InputCard extends StatefulWidget {
  const new({this.minLines = 4, super.key});

  final int minLines;

  @override
  State<InputCard> createState() => _InputCardState();
}

class _InputCardState extends State<InputCard> {
  late final TranslateCubit _cubit = context.read<TranslateCubit>();
  late final HighlightTextEditingController _controller =
      HighlightTextEditingController(text: _cubit.state.input);
  final _focusNode = FocusNode(debugLabel: 'translate_input');

  /// The field's value at the last controller notification (to tell cursor
  /// moves from edits).
  TextEditingValue _lastValue = TextEditingValue.empty;

  /// The whole text of the last field edit that the length limit cut (see
  /// [_LengthOverflowFormatter]); reset by every edit.
  String? _overflow;

  static final _endsWithSpace = RegExp(r'\s$');

  /// The input before the current dictation; recognised speech is appended
  /// to it (each partial result replaces the previous one).
  String? _dictationBase;

  @override
  void initState() {
    super.initState();
    _showAlignment(_cubit.state);
    _lastValue = _controller.value;
    _controller.addListener(_onValueChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onValueChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// A cursor move (no edit) into an aligned source phrase focuses its pair;
  /// a move out of every phrase clears the focus.
  void _onValueChanged() {
    final value = _controller.value;
    final previous = _lastValue;
    _lastValue = value;
    if (value.text != previous.text || value.selection == previous.selection) {
      return;
    }
    final selection = value.selection;
    final state = _cubit.state;
    if (!selection.isValid ||
        !selection.isCollapsed ||
        state.alignment.isEmpty ||
        state.alignmentStatus != ExtraStatus.ready ||
        state.input != value.text) {
      return;
    }
    final index = inputAlignmentIndexAt(state, selection.baseOffset);
    if (index != state.alignmentFocus) _cubit.focusAlignment(index);
  }

  /// Mirrors the state into the field: external input changes, then the
  /// alignment.
  void _syncState(TranslateState state) {
    _syncController(state.input);
    _showAlignment(state);
  }

  void _showAlignment(TranslateState state) {
    final text = _controller.text;
    _controller.showAlignment(
      phrases: inputAlignmentPhrases(state, text),
      highlight:
          inputMeaningHighlight(state, text) ??
          inputAlignmentHighlight(state, text),
    );
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

  /// Typed or pasted text; text the field's length limit cut is passed on
  /// whole so the cubit cuts it the same way and shows the notice.
  void _onChanged(String text) {
    final overflow = _overflow;
    _overflow = null;
    _cubit.setInput(overflow ?? text);
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
    _syncController(combined);
    _cubit.setInput(combined);
  }

  /// Esc clears a non-empty field; otherwise the key keeps bubbling (e.g.
  /// to dismiss a route).
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        _controller.text.isEmpty ||
        (_controller.value.composing.isValid &&
            !_controller.value.composing.isCollapsed)) {
      return KeyEventResult.ignored;
    }
    _clear();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final settings = context.watch<SettingsCubit>().state;
    return BlocConsumer<TranslateCubit, TranslateState>(
      listenWhen: (previous, current) =>
          previous.input != current.input ||
          previous.alignment != current.alignment ||
          previous.alignmentFocus != current.alignmentFocus ||
          previous.alignmentStatus != current.alignmentStatus ||
          previous.meaningFocus != current.meaningFocus ||
          previous.meaningStatus != current.meaningStatus,
      listener: (context, state) => _syncState(state),
      builder: (context, state) {
        final input = state.input;
        final empty = input.trim().isEmpty;
        final transliteration = state.result?.sourceTransliteration ?? '';
        final showTranslate = needsTranslateButton(state, settings);
        final accent = theme.colorScheme.primary;
        final palette = AppPalette.of(context);
        return TranslateFlatCard(
          key: const Key('translate_input_card'),
          look: TranslateCardLook.plain,
          // Keep the field, its counter and buttons as separate nodes (a
          // merged card would read the counter as part of the field name).
          semanticContainer: false,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(
              start: TranslateLayout.cardPadding,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: _onKeyEvent,
                  // The hint disappears once there is text, so name the
                  // field explicitly for screen readers.
                  child: Semantics(
                    label: l10n.translateInputLabel,
                    child: TextField(
                      key: const Key('translate_input_field'),
                      controller: _controller,
                      focusNode: _focusNode,
                      enableIMEPersonalizedLearning: imeLearningAllowed(
                        context,
                      ),
                      onChanged: _onChanged,
                      maxLength: TranslateCubit.maxInputLength,
                      inputFormatters: [
                        _LengthOverflowFormatter(
                          TranslateCubit.maxInputLength,
                          onOverflow: (text) => _overflow = text,
                        ),
                      ],
                      // The toolbar shows its own character count.
                      buildCounter: (
                        context, {
                        required currentLength,
                        required isFocused,
                        required maxLength,
                      }) => null,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      textDirection: inputTextDirection(state),
                      minLines: widget.minLines,
                      maxLines: null,
                      style: TranslateLayout.textStyle(context, input.length),
                      decoration: InputDecoration(
                        hintText: l10n.translateInputHint,
                        hintStyle: TranslateLayout.textStyle(
                          context,
                          0,
                        )?.copyWith(color: palette.secondaryText),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding: const EdgeInsetsDirectional.only(
                          top: 14,
                          bottom: 8,
                          end: 8,
                        ),
                      ),
                    ),
                  ),
                ),
                if (state.inputTruncated)
                  _TruncatedNotice(limit: truncatedInputLimit(state)),
                if (settings.showTransliteration &&
                    transliteration.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      end: 12,
                      bottom: 4,
                    ),
                    child: Text(
                      transliteration,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.secondaryText,
                      ),
                    ),
                  ),
                // X's compose toolbar: accent icons at the start, the
                // count ring, clear and the action at the end.
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    key: const Key('translate_input_toolbar'),
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 4,
                    children: [
                      IconButtonTheme(
                        data: IconButtonThemeData(
                          style: IconButton.styleFrom(
                            foregroundColor: accent,
                            disabledForegroundColor: accent.withValues(
                              alpha: 0.38,
                            ),
                          ),
                        ),
                        child: Transform.translate(
                          // Line the first icon up with the text.
                          offset: Offset(
                            Directionality.of(context) == TextDirection.rtl
                                ? 8
                                : -8,
                            0,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListenButton(
                                id: 'source',
                                text: input,
                                languageCode: state.effectiveSourceCode,
                              ),
                              if (_speechInputServiceOf(context)
                                  case final speech?)
                                VoiceInputButton.standalone(
                                  key: const Key('translate_voice_input'),
                                  service: speech,
                                  // `auto` uses the device's recognition
                                  // language.
                                  languageCode: state.source.code,
                                  onResult: _onVoiceResult,
                                  onListeningChanged: _onListeningChanged,
                                ),
                              if (GoRouter.maybeOf(context) != null)
                                const ImageTranslateButton(
                                  key: Key('translate_image_button'),
                                ),
                              if (input.isEmpty)
                                IconButton(
                                  key: const Key('translate_paste_button'),
                                  tooltip: l10n.translatePaste,
                                  icon: const Icon(Icons.content_paste),
                                  onPressed: () => unawaited(_paste()),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Wrap(
                        alignment: WrapAlignment.end,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          if (input.isNotEmpty)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        l10n.translateCharacterCount(
                                          input.characters.length,
                                        ),
                                        key: const Key(
                                          'translate_character_count',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                              color: palette.secondaryText,
                                            ),
                                      ),
                                      // Nothing below 500 characters; one line
                                      // like the count.
                                      if (state.isAiEngine)
                                        DefaultTextStyle.merge(
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          child: TokenEstimateLabel(
                                            key: const Key(
                                              'translate_token_estimate',
                                            ),
                                            text: input,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                // The count above says the same in words.
                                ExcludeSemantics(
                                  child: CountRing(
                                    key: const Key('translate_count_ring'),
                                    count: input.characters.length,
                                    limit: TranslateCubit.maxInputLength,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  key: const Key('translate_clear_button'),
                                  tooltip: l10n.commonClear,
                                  color: palette.secondaryText,
                                  icon: const Icon(Icons.close),
                                  onPressed: _clear,
                                ),
                              ],
                            ),
                          if (showTranslate)
                            Tooltip(
                              message: l10n.translateShortcutTranslate,
                              child: FilledButton.icon(
                                key: const Key('translate_translate_button'),
                                style: FilledButton.styleFrom(
                                  shape: const StadiumBorder(),
                                ),
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
              ],
            ),
          ),
        );
      },
    );
  }
}

/// "Text shortened to the maximum length of N characters." under the
/// field, announced once to screen readers when it appears.
class _TruncatedNotice extends StatelessWidget {
  const new({required this.limit});

  final int limit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = context.l10n.translateInputTruncated(limit);
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 12, top: 4, bottom: 4),
      child: StatusAnnouncer(
        message: message,
        announceInitial: true,
        child: Row(
          key: const Key('translate_input_truncated'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.content_cut,
              size: 18,
              color: AppPalette.of(context).secondaryText,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.of(context).secondaryText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reports, before the field's length limit cuts an edit, the whole text
/// of an edit longer than [maxLength] characters (null otherwise). Leaves
/// the value unchanged.
class _LengthOverflowFormatter extends TextInputFormatter {
  new(this.maxLength, {required this.onOverflow});

  final int maxLength;
  final ValueChanged<String?> onOverflow;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    onOverflow(
      newValue.text.characters.length > maxLength ? newValue.text : null,
    );
    return newValue;
  }
}
