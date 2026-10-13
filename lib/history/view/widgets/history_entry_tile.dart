import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// One history entry: languages, source text, translation, engine and time,
/// with a favorite toggle. Swipe to delete.
class HistoryEntryTile extends StatelessWidget {
  const HistoryEntryTile({
    required this.entry,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onDelete,
    super.key,
  });

  final HistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final time = DateFormat.jm(l10n.localeName)
        .format(entry.createdAt.toLocal());
    final pair = l10n.historyLanguagePair(_sourceName(l10n), entry.target.name);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Dismissible(
        key: ValueKey('history-${entry.id}'),
        background: const _DeleteBackground(
          alignment: AlignmentDirectional.centerStart,
        ),
        secondaryBackground: const _DeleteBackground(
          alignment: AlignmentDirectional.centerEnd,
        ),
        onDismissed: (_) => onDelete(),
        child: Card.filled(
          margin: EdgeInsets.zero,
          color: colors.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Semantics(
            onTapHint: l10n.historyOpenHint,
            customSemanticsActions: {
              CustomSemanticsAction(label: l10n.commonDelete): onDelete,
            },
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 4, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            pair,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            entry.text,
                            style: theme.textTheme.bodyLarge,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entry.translation,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: colors.primary,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${entry.engineName} · $time',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: entry.isFavorite
                          ? l10n.historyUnfavorite
                          : l10n.historyFavorite,
                      isSelected: entry.isFavorite,
                      icon: const Icon(Icons.star_outline_rounded),
                      selectedIcon: Icon(
                        Icons.star_rounded,
                        color: colors.primary,
                      ),
                      onPressed: onToggleFavorite,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _sourceName(AppLocalizations l10n) {
    final detected = entry.detectedSource;
    if (entry.source.isAuto && detected != null && detected.isNotEmpty) {
      return l10n.historyDetected(LanguageCatalog.nameOf(detected));
    }
    return entry.source.name;
  }
}

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground({required this.alignment});

  final AlignmentDirectional alignment;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Icon(Icons.delete_outline, color: colors.onErrorContainer),
        ),
      ),
    );
  }
}
