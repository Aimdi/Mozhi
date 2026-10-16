import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show Bidi, DateFormat;
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/bidi.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

enum _EntryAction { favorite, delete }

/// One history entry: languages, source text, translation, engine and time,
/// with a favorite toggle.
///
/// Delete is available by swiping, from the "More actions" menu (also opened
/// by a long press), with the Delete key while the entry has focus, and as a
/// screen-reader custom action, so it never needs a drag (WCAG 2.5.7).
class HistoryEntryTile extends StatefulWidget {
  const new({
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
  State<HistoryEntryTile> createState() => _HistoryEntryTileState();
}

class _HistoryEntryTileState extends State<HistoryEntryTile> {
  final _menuKey = GlobalKey<PopupMenuButtonState<_EntryAction>>();

  HistoryEntry get entry => widget.entry;

  void _onAction(_EntryAction action) => switch (action) {
    _EntryAction.favorite => widget.onToggleFavorite(),
    _EntryAction.delete => widget.onDelete(),
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final time = DateFormat.jm(l10n.localeName)
        .format(entry.createdAt.toLocal());
    // Isolated so Latin-script names keep the arrow's direction in RTL
    // locales.
    final pair = l10n.historyLanguagePair(
      bidiIsolate(_sourceName(l10n)),
      bidiIsolate(entry.target.name),
    );
    final sourceCode = entry.source.isAuto
        ? entry.detectedSource
        : entry.source.isCustom
        ? null
        : entry.source.code;
    final targetCode = entry.target.isCustom ? null : entry.target.code;
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
        onDismissed: (_) => widget.onDelete(),
        child: Card.filled(
          margin: EdgeInsets.zero,
          color: colors.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.delete): widget.onDelete,
            },
            child: Semantics(
              onTapHint: l10n.historyOpenHint,
              customSemanticsActions: {
                CustomSemanticsAction(label: l10n.commonDelete):
                    widget.onDelete,
              },
              child: InkWell(
                onTap: widget.onTap,
                onLongPress: () => _menuKey.currentState?.showButtonMenu(),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 4, 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _PairBadge(pair: pair),
                            const SizedBox(height: 10),
                            _LanguageText(
                              text: entry.text,
                              code: sourceCode,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: colors.onSurface,
                              ),
                            ),
                            const SizedBox(height: 8),
                            // A quiet accent line marks the translation.
                            DecoratedBox(
                              decoration: BoxDecoration(
                                border: BorderDirectional(
                                  start: BorderSide(
                                    color: colors.primary.withValues(
                                      alpha: 0.5,
                                    ),
                                    width: 3,
                                  ),
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  start: 10,
                                ),
                                child: _LanguageText(
                                  text: entry.translation,
                                  code: targetCode,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: colors.primary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
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
                        onPressed: widget.onToggleFavorite,
                      ),
                      PopupMenuButton<_EntryAction>(
                        key: _menuKey,
                        tooltip: l10n.historyEntryActions,
                        onSelected: _onAction,
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: _EntryAction.favorite,
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                entry.isFavorite
                                    ? Icons.star_rounded
                                    : Icons.star_outline_rounded,
                              ),
                              title: Text(
                                entry.isFavorite
                                    ? l10n.historyUnfavorite
                                    : l10n.historyFavorite,
                              ),
                            ),
                          ),
                          PopupMenuItem(
                            value: _EntryAction.delete,
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.delete_outline),
                              title: Text(l10n.commonDelete),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
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

/// User or translated text in its own language: laid out in that
/// language's direction (WCAG 1.3.2) and tagged with its locale so screen
/// readers pick the right voice and CJK text the right glyphs (WCAG 3.1.2).
///
/// [code] is a language code, or null when unknown (auto-detected without
/// a result, or a custom AI target); the direction is then guessed from
/// the text itself.
class _LanguageText extends StatelessWidget {
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
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A [Locale] for a language code such as `ja`, `pt-BR`, `zh_TW` or
/// `sr-Latn`, or null when [code] is not a valid language subtag.
@visibleForTesting
Locale? localeForLanguageCode(String code) {
  final parts = code.split(RegExp('[-_]'));
  final language = parts.first.toLowerCase();
  if (!RegExp(r'^[a-z]{2,3}$').hasMatch(language)) return null;
  String? script;
  String? country;
  for (final part in parts.skip(1)) {
    if (part.length == 4 && script == null && country == null) {
      script = part[0].toUpperCase() + part.substring(1).toLowerCase();
    } else if ((part.length == 2 || part.length == 3) && country == null) {
      country = part.toUpperCase();
    }
  }
  return Locale.fromSubtags(
    languageCode: language,
    scriptCode: script,
    countryCode: country,
  );
}

/// The language pair as a small tonal badge.
class _PairBadge extends StatelessWidget {
  const new({required this.pair});

  final String pair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(6, 2, 8, 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            Icon(Icons.translate, size: 14, color: colors.onSecondaryContainer),
            Flexible(
              child: Text(
                pair,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.onSecondaryContainer,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeleteBackground extends StatelessWidget {
  const new({required this.alignment});

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
