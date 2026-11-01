import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/language_pair_bar.dart'
    show languagePairForms;
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/dictionary/widgets/dictionary_language_bar.dart';
import 'package:mozhi/dictionary/widgets/dictionary_language_picker.dart';
import 'package:mozhi/dictionary/widgets/dictionary_options_sheet.dart';
import 'package:mozhi/dictionary/widgets/dictionary_search_field.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/language_bar.dart'
    show FirstThatFits, LanguageLabelForm;
import 'package:mozhi/voice/voice.dart'
    show SpeechInputService, VoiceInputButton;
import 'package:translation_repository/translation_repository.dart';

/// The dictionary's composer, docked under the greeting like the
/// translate tab's: the search field ([DictionarySearchField]) with Clear
/// (once there is a word) and the microphone (when voice input is
/// available) at its top end, and the bar [options | languages | go]
/// ([DictionaryComposerBar]).
class DictionaryComposer extends StatelessWidget {
  const new({this.focusNode, this.autofocus = false, super.key});

  /// The search field's focus node.
  final FocusNode? focusNode;

  /// Focus the search field when it first shows.
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final focusNode = this.focusNode;
    return ComposerCard(
      key: const Key('dictionary_composer'),
      onTap: focusNode?.requestFocus,
      actions: [
        DictionaryClearButton(focusNode: focusNode),
        const DictionaryVoiceButton(),
      ],
      bar: const DictionaryComposerBar(),
      // Room for a couple of lines, like the translate composer, though a
      // word fits on one.
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: DictionarySearchField(
          focusNode: focusNode,
          autofocus: autofocus,
        ),
      ),
    );
  }
}

/// The bar of the [DictionaryComposer], in the order of every composer
/// (Translate, Proofread): the options button
/// ([DictionaryOptionsButton]), the languages ([DictionaryLanguagePair])
/// and the go button ([DictionaryGoButton]) at the trailing end.
class DictionaryComposerBar extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return const ComposerBar(
      key: Key('dictionary_bar'),
      children: [
        DictionaryOptionsButton(key: Key('dictionary_options_button')),
        Expanded(child: DictionaryLanguagePair()),
        DictionaryGoButton(),
      ],
    );
  }
}

/// Clears the word (nothing while there is none) and moves the focus to
/// the search field ([focusNode]), as the button goes away.
class DictionaryClearButton extends StatelessWidget {
  const new({this.focusNode, super.key});

  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final empty = context.select<DictionaryCubit, bool>(
      (cubit) => cubit.state.word.isEmpty,
    );
    if (empty) return const SizedBox.shrink();
    return IconButton(
      key: const Key('dictionary_clear'),
      tooltip: context.l10n.commonClear,
      color: AppPalette.of(context).secondaryText,
      icon: const Icon(Icons.close),
      onPressed: () {
        context.read<DictionaryCubit>().clear();
        focusNode?.requestFocus();
      },
    );
  }
}

/// "Look up" (the go arrow): looks the typed word up
/// ([lookUpDictionaryWord]); disabled without a word or an AI engine.
class DictionaryGoButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final enabled = context.select<DictionaryCubit, bool>(
      (cubit) => cubit.state.canLookUp,
    );
    return ComposerGoButton(
      key: const Key('dictionary_look_up'),
      label: context.l10n.dictionaryLookUp,
      onPressed: enabled ? () => lookUpDictionaryWord(context) : null,
    );
  }
}

/// The app-wide [SpeechInputService], or null when none is provided (voice
/// input is then not offered).
SpeechInputService? _speechInputServiceOf(BuildContext context) {
  try {
    return context.read<SpeechInputService>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// The microphone of the [DictionaryComposer]: the spoken word or phrase
/// replaces the typed one (in the word's language; the device's language
/// while it is detected). Nothing when voice input is not available.
class DictionaryVoiceButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final service = _speechInputServiceOf(context);
    if (service == null) return const SizedBox.shrink();
    final source = context.select<DictionaryCubit, Language>(
      (cubit) => cubit.state.source,
    );
    final cubit = context.read<DictionaryCubit>();
    return VoiceInputButton.standalone(
      key: const Key('dictionary_voice_input'),
      service: service,
      languageCode: source.code,
      onResult: (text, {required isFinal}) {
        final spoken = text.trim();
        if (spoken.isNotEmpty) cubit.setWord(spoken);
      },
    );
  }
}

/// Widths of two buttons sharing [width] whose own widths are [start] and
/// [end]: half each while both fit in half; otherwise the narrower one
/// keeps its own width (when it fits in half) and the wider one gets the
/// rest.
(double, double) dictionaryPairSplit(double width, double start, double end) {
  final available = math.max(0, width).toDouble();
  final half = available / 2;
  if (start <= half && end <= half) return (half, half);
  if (start <= half) return (start, available - start);
  if (end <= half) return (available - end, end);
  return (half, half);
}

/// The languages on the [DictionaryComposerBar], compact: "Detect
/// language → French". Each name is a button of its own that opens its
/// searchable list ([pickDictionaryLanguage]), named for screen readers
/// like the buttons of the [DictionaryLanguageBar] ("Language of the
/// word: …", "Translations in: …"); the arrow between them is decorative.
/// The longer name gets the room the shorter one does not need (
/// [dictionaryPairSplit]); swapping is in the options sheet.
class DictionaryLanguagePair extends StatelessWidget {
  const new({super.key});

  /// Width of the arrow between the names.
  static const double arrowWidth = 20;

  /// Width of a button around its name (padding and chevron).
  static const double buttonChrome = 34;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final (source, target) = context
        .select<DictionaryCubit, (Language, Language)>(
          (cubit) => (cubit.state.source, cubit.state.target),
        );
    final sourceName = dictionaryLanguageName(l10n, source);
    final targetName = dictionaryLanguageName(l10n, target);
    final style = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w700,
    );
    final targetStyle = style?.copyWith(fontWeight: FontWeight.w800);
    final textScaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double widthOf(String text, TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      // Rounded up: a name that just fits is not shortened.
      return width.ceilToDouble() + 1 + buttonChrome;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final (sourceWidth, targetWidth) = dictionaryPairSplit(
          constraints.maxWidth - arrowWidth,
          widthOf(sourceName, style),
          widthOf(targetName, targetStyle),
        );
        return Row(
          key: const Key('dictionary_language_pair'),
          children: [
            SizedBox(
              width: sourceWidth,
              child: _PairButton(
                key: const Key('dictionary_bar_source'),
                label: sourceName,
                forms: languagePairForms(
                  source,
                  label: sourceName,
                  autoShort: l10n.translateDetectLanguageShort,
                ),
                style: style,
                semanticsLabel: source.isAuto
                    ? l10n.dictionarySourceLanguageAuto
                    : l10n.dictionarySourceLanguage(sourceName),
                onPressed: () =>
                    unawaited(pickDictionaryLanguage(context, source: true)),
              ),
            ),
            SizedBox(
              width: arrowWidth,
              child: ExcludeSemantics(
                child: Icon(
                  Icons.arrow_forward,
                  size: 16,
                  color: AppPalette.of(context).secondaryText,
                ),
              ),
            ),
            SizedBox(
              width: targetWidth,
              child: _PairButton(
                key: const Key('dictionary_bar_target'),
                label: targetName,
                forms: languagePairForms(
                  target,
                  label: targetName,
                  autoShort: l10n.translateDetectLanguageShort,
                ),
                style: targetStyle,
                semanticsLabel: l10n.dictionaryTargetLanguage(targetName),
                onPressed: () =>
                    unawaited(pickDictionaryLanguage(context, source: false)),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A language name with a small chevron, on the bar without an outline of
/// its own. The button keeps its own semantics (tap action, focus); only
/// its visible content is replaced by [semanticsLabel].
///
/// It shows the first of [forms] that fits whole (the name, then the code;
/// "Detect language", then the sparkle and "Auto"), each first with the
/// chevron, then without; never a cut name. The full [label] stays in the
/// tooltip.
class _PairButton extends StatelessWidget {
  const new({
    required this.label,
    required this.forms,
    required this.style,
    required this.semanticsLabel,
    required this.onPressed,
    super.key,
  });

  final String label;
  final List<LanguageLabelForm> forms;
  final TextStyle? style;
  final String semanticsLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final secondary = AppPalette.of(context).secondaryText;
    Widget content(LanguageLabelForm form, {required bool chevron}) {
      final (:icon, :text) = form;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) Icon(icon, size: 18, color: scheme.primary),
          if (icon != null && text != null) const SizedBox(width: 6),
          if (text != null)
            Text(text, maxLines: 1, softWrap: false, style: style),
          if (chevron) ...[
            if (icon != null || text != null) const SizedBox(width: 2),
            Icon(Icons.expand_more, size: 16, color: secondary),
          ],
        ],
      );
    }

    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsetsDirectional.only(start: 10, end: 6),
          shape: AppLook.of(context).control,
          foregroundColor: scheme.onSurface,
        ),
        onPressed: onPressed,
        child: Semantics(
          label: semanticsLabel,
          excludeSemantics: true,
          child: FirstThatFits(
            children: [
              for (final form in forms) ...[
                content(form, chevron: true),
                if (form.icon != null || form.text != null)
                  content(form, chevron: false),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
