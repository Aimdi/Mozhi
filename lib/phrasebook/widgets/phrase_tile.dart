import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/models/phrase.dart';
import 'package:mozhi/phrasebook/widgets/phrasebook_labels.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/search_highlight.dart';
import 'package:mozhi/speech/widgets/spoken_range_builder.dart';
import 'package:mozhi/translate/widgets/copy_action_button.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';
import 'package:mozhi/translate/widgets/output_card.dart' show copyToClipboard;
import 'package:mozhi/translate/widgets/show_mode.dart';
import 'package:share_plus/share_plus.dart';

enum _PhraseAction { copyPhrase, share, note, copyTo, moveTo, remove }

/// Sharing, replaceable in tests.
abstract final class PhrasebookShare {
  @visibleForTesting
  static Future<void> Function(ShareParams params) share = _share;

  // coverage:ignore-start
  static Future<void> _share(ShareParams params) async {
    await SharePlus.instance.share(params);
  }
  // coverage:ignore-end
}

/// What sharing [phrase] shares: the phrase and its translation, one per
/// line.
String phraseShareText(Phrase phrase) =>
    '${phrase.text}\n${phrase.translation}';

/// One phrase of a collection: the phrase, its translation (in the
/// primary colour), the pronunciation when the phrase has one and the
/// user's note, each text in its own language (direction and locale).
///
/// Under them the everyday actions, 48 dp each: Listen to the phrase,
/// Listen to the translation (a long press reads slowly), Copy the
/// translation and Show full screen (the translation in large type, to
/// show it to someone), then "Phrase actions" with Copy phrase, Share, the
/// note ([onEditNote]), Copy to / Move to another collection ([onCopyTo],
/// [onMoveTo]) and Remove ([onRemove], [removeLabel]); the entries without
/// a callback are left out (a starter phrasebook is read-only). Matches
/// of [query] are highlighted; while Listen reads the phrase or the
/// translation, the word being read is (`AppSettings.highlightSpokenWord`,
/// [SpokenRangeBuilder]).
class PhraseTile extends StatelessWidget {
  const new({
    required this.phrase,
    this.query = '',
    this.onEditNote,
    this.onCopyTo,
    this.onMoveTo,
    this.onRemove,
    this.removeLabel,
    super.key,
  });

  final Phrase phrase;
  final String query;
  final VoidCallback? onEditNote;
  final VoidCallback? onCopyTo;
  final VoidCallback? onMoveTo;
  final VoidCallback? onRemove;

  /// The label of [onRemove] ("Remove from collection" by default).
  final String? removeLabel;

  /// The `SpeechService` clip ids of the phrase and its translation.
  String get _sourceSpeechId => 'phrasebook:${phrase.id}:source';
  String get _targetSpeechId => 'phrasebook:${phrase.id}:target';

  /// `AppSettings.highlightSpokenWord`, on without settings above.
  static bool _highlightSpokenWord(BuildContext context) {
    try {
      return context.select<SettingsCubit, bool>(
        (cubit) => cubit.state.highlightSpokenWord,
      );
    } on ProviderNotFoundException {
      return true;
    }
  }

  Future<void> _share(BuildContext anchor) {
    final box = anchor.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    return PhrasebookShare.share(
      ShareParams(text: phraseShareText(phrase), sharePositionOrigin: origin),
    );
  }

  void _onAction(BuildContext context, _PhraseAction action) =>
      switch (action) {
        _PhraseAction.copyPhrase => unawaited(
          copyToClipboard(context, phrase.text),
        ),
        _PhraseAction.share => unawaited(_share(context)),
        _PhraseAction.note => onEditNote?.call(),
        _PhraseAction.copyTo => onCopyTo?.call(),
        _PhraseAction.moveTo => onMoveTo?.call(),
        _PhraseAction.remove => onRemove?.call(),
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = AppPalette.of(context);
    final highlight = searchHighlightStyle(context);
    final source = phrase.sourceCode == Phrase.unknownLanguage
        ? null
        : phrase.sourceCode;
    final target = phrase.targetCode == Phrase.unknownLanguage
        ? null
        : phrase.targetCode;

    final highlightSpoken = _highlightSpokenWord(context);
    final spokenStyle = spokenWordStyle(colors);

    Widget text(
      String value,
      String code,
      TextStyle? style, {
      required String speechId,
    }) => SpokenRangeBuilder(
      id: speechId,
      text: value,
      enabled: highlightSpoken,
      builder: (context, spoken) => Text.rich(
        spoken != null
            ? spokenTextSpan(
                value,
                spoken,
                highlight: spokenStyle,
                locale: phrasebookLocale(code),
              )
            : highlightedSpan(
                value,
                query,
                highlight: highlight,
                locale: phrasebookLocale(code),
              ),
        style: style,
        textDirection: phrasebookTextDirection(code, value),
      ),
    );

    final menu = PopupMenuButton<_PhraseAction>(
      tooltip: l10n.phrasebookPhraseActions,
      icon: Icon(
        Icons.more_vert_rounded,
        size: 20,
        color: palette.secondaryText,
      ),
      onSelected: (action) => _onAction(context, action),
      itemBuilder: (context) => [
        _item(
          _PhraseAction.copyPhrase,
          Icons.copy_rounded,
          l10n.phrasebookCopyPhrase,
        ),
        _item(_PhraseAction.share, Icons.ios_share_rounded, l10n.commonShare),
        if (onEditNote != null)
          _item(
            _PhraseAction.note,
            Icons.edit_note_rounded,
            phrase.note.isEmpty
                ? l10n.phrasebookAddNote
                : l10n.phrasebookEditNote,
          ),
        if (onCopyTo != null)
          _item(
            _PhraseAction.copyTo,
            Icons.library_add_outlined,
            l10n.phrasebookCopyTo,
          ),
        if (onMoveTo != null)
          _item(
            _PhraseAction.moveTo,
            Icons.drive_file_move_outline,
            l10n.phrasebookMoveTo,
          ),
        if (onRemove != null)
          _item(
            _PhraseAction.remove,
            Icons.remove_circle_outline,
            removeLabel ?? l10n.phrasebookRemove,
          ),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(4, 12, 4, 0),
          child: Semantics(
            container: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                text(
                  phrase.text,
                  phrase.sourceCode,
                  theme.textTheme.bodyLarge?.copyWith(color: colors.onSurface),
                  speechId: _sourceSpeechId,
                ),
                text(
                  phrase.translation,
                  phrase.targetCode,
                  theme.textTheme.bodyLarge?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                  speechId: _targetSpeechId,
                ),
                if (phrase.pronunciation.isNotEmpty)
                  Semantics(
                    label: l10n.phrasebookPronunciation(phrase.pronunciation),
                    excludeSemantics: true,
                    child: Text(
                      phrase.pronunciation,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: palette.secondaryText,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                if (phrase.note.isNotEmpty)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(
                          Icons.sticky_note_2_outlined,
                          size: 14,
                          color: palette.secondaryText,
                          semanticLabel: l10n.phrasebookNote,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text.rich(
                          highlightedSpan(
                            phrase.note,
                            query,
                            highlight: highlight,
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: palette.secondaryText,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        Wrap(
          spacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ListenButton(
              id: _sourceSpeechId,
              text: phrase.text,
              languageCode: source,
              tooltip: l10n.phrasebookListenPhrase,
              quiet: true,
            ),
            ListenButton(
              id: _targetSpeechId,
              text: phrase.translation,
              languageCode: target,
              tooltip: l10n.phrasebookListenTranslation,
              quiet: true,
            ),
            CopyActionButton(
              text: phrase.translation,
              tooltip: l10n.phrasebookCopyTranslation,
              quiet: true,
            ),
            XActionButton(
              icon: Icons.fullscreen,
              tooltip: l10n.translateShowMode,
              onPressed: () => unawaited(
                showTranslationFullScreen(
                  context,
                  text: phrase.translation,
                  textDirection: phrasebookTextDirection(
                    phrase.targetCode,
                    phrase.translation,
                  ),
                  locale: phrasebookLocale(phrase.targetCode),
                ),
              ),
            ),
            menu,
          ],
        ),
        const Hairline(),
      ],
    );
  }

  static PopupMenuItem<_PhraseAction> _item(
    _PhraseAction action,
    IconData icon,
    String label,
  ) => PopupMenuItem(
    value: action,
    child: ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
    ),
  );
}
