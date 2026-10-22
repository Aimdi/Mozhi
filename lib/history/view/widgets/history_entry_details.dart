import 'dart:async';

import 'package:intl/intl.dart' show Bidi, DateFormat;
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/history/view/widgets/history_entry_tile.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/output_card.dart' show copyToClipboard;

/// Everything about one history entry: the language pair, the engine and
/// when it was made, the whole text and translation (selectable), and its
/// actions: open it in the translator (or look the word up again), copy,
/// share, favourite and delete.
///
/// The detail pane of the History page on wide screens, and the "Details"
/// sheet of an entry on phones.
class HistoryEntryDetails extends StatelessWidget {
  const new({
    required this.entry,
    required this.onOpen,
    required this.onToggleFavorite,
    required this.onDelete,
    super.key,
  });

  final HistoryEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDelete;

  /// Key of the open (or look up) button.
  static const openKey = Key('history_detail_open');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = AppPalette.of(context);
    final lookUp = entry.isDictionary;
    final created = entry.createdAt.toLocal();
    final when = DateFormat.yMMMEd(l10n.localeName).add_jm().format(created);
    final label = theme.textTheme.labelMedium?.copyWith(
      color: palette.secondaryText,
      fontWeight: FontWeight.w600,
    );
    final favoriteLabel = entry.isFavorite
        ? l10n.historyUnfavorite
        : l10n.historyFavorite;
    final translation = entry.translation.trim();
    return Column(
      key: ValueKey('history_details_${entry.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            historyEntryPair(l10n, entry),
            style: theme.textTheme.titleMedium?.copyWith(
              color: colors.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${entry.engineName} · $when',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: palette.secondaryText,
          ),
        ),
        const SizedBox(height: 20),
        SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                lookUp
                    ? l10n.historyDictionaryMarker
                    : l10n.historyDetailOriginal,
                style: label,
              ),
              const SizedBox(height: 4),
              _DetailText(
                text: entry.text,
                code: historySourceCode(entry),
                style: theme.textTheme.titleLarge?.copyWith(
                  color: colors.onSurface,
                  fontWeight: lookUp ? FontWeight.w700 : FontWeight.w400,
                  height: 1.35,
                ),
              ),
              if (translation.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  lookUp
                      ? l10n.historyDetailSummary
                      : l10n.historyDetailTranslation,
                  style: label,
                ),
                const SizedBox(height: 4),
                _DetailText(
                  text: entry.translation,
                  code: lookUp ? null : historyTargetCode(entry),
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: lookUp ? colors.onSurface : colors.primary,
                    fontWeight: FontWeight.w400,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.tonalIcon(
              key: openKey,
              onPressed: onOpen,
              icon: Icon(lookUp ? Icons.menu_book_outlined : Icons.translate),
              label: Text(
                lookUp ? l10n.historyOpenDictionaryHint : l10n.historyOpenHint,
              ),
            ),
            XActionButton(
              icon: Icons.copy_rounded,
              tooltip: l10n.commonCopy,
              onPressed: () =>
                  unawaited(copyToClipboard(context, historyCopyText(entry))),
            ),
            Builder(
              builder: (buttonContext) => XActionButton(
                icon: Icons.ios_share_rounded,
                tooltip: l10n.commonShare,
                onPressed: () =>
                    unawaited(shareHistoryEntry(buttonContext, entry)),
              ),
            ),
            XActionButton(
              icon: entry.isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              tooltip: favoriteLabel,
              active: entry.isFavorite,
              activeColor: palette.like,
              onPressed: onToggleFavorite,
            ),
            XActionButton(
              icon: Icons.delete_outline,
              tooltip: l10n.commonDelete,
              onPressed: onDelete,
            ),
          ],
        ),
      ],
    );
  }
}

/// [text] in its language's direction, tagged with its locale (see
/// `HistoryEntryTile`), in full.
class _DetailText extends StatelessWidget {
  const new({required this.text, required this.code, required this.style});

  final String text;
  final String? code;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final code = this.code;
    final known = code != null && code.isNotEmpty && code != 'auto';
    final rtl = known
        ? Bidi.isRtlLanguage(code)
        : Bidi.detectRtlDirectionality(text);
    return Text.rich(
      TextSpan(text: text, locale: known ? localeForLanguageCode(code) : null),
      style: style,
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
    );
  }
}

/// Shows [entry]'s details in a bottom sheet (phones); the actions close
/// it first.
Future<void> showHistoryEntryDetails(
  BuildContext context, {
  required HistoryEntry entry,
  required VoidCallback onOpen,
  required VoidCallback onToggleFavorite,
  required VoidCallback onDelete,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (sheetContext) {
    void then(VoidCallback action) {
      Navigator.of(sheetContext).pop();
      action();
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: HistoryEntryDetails(
        entry: entry,
        onOpen: () => then(onOpen),
        onToggleFavorite: () => then(onToggleFavorite),
        onDelete: () => then(onDelete),
      ),
    );
  },
);
