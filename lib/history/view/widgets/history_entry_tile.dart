import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show Bidi, DateFormat;
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/bidi.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/output_card.dart' show copyToClipboard;
import 'package:share_plus/share_plus.dart';
import 'package:translation_repository/translation_repository.dart';

enum _EntryAction { favorite, delete }

/// Sharing, replaceable in tests.
abstract final class HistoryShare {
  @visibleForTesting
  static Future<void> Function(ShareParams params) share = _share;

  // coverage:ignore-start
  static Future<void> _share(ShareParams params) async {
    await SharePlus.instance.share(params);
  }
  // coverage:ignore-end
}

/// One history entry as a timeline row: the target language's avatar, a
/// header (language pair · engine · time), the translation as the body,
/// the source text quoted below it and an action row (copy, favorite,
/// share, more).
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

  /// How long the copy action shows its check mark.
  static const copiedDuration = Duration(seconds: 2);

  @override
  State<HistoryEntryTile> createState() => _HistoryEntryTileState();
}

class _HistoryEntryTileState extends State<HistoryEntryTile> {
  final _menuKey = GlobalKey<PopupMenuButtonState<_EntryAction>>();
  Timer? _copiedTimer;

  HistoryEntry get entry => widget.entry;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  void _onAction(_EntryAction action) => switch (action) {
    _EntryAction.favorite => widget.onToggleFavorite(),
    _EntryAction.delete => widget.onDelete(),
  };

  void _copy() {
    unawaited(copyToClipboard(context, entry.translation));
    _copiedTimer?.cancel();
    setState(() {
      _copiedTimer = Timer(HistoryEntryTile.copiedDuration, () {
        if (mounted) setState(() => _copiedTimer = null);
      });
    });
  }

  void _share(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    unawaited(
      HistoryShare.share(
        ShareParams(text: entry.translation, sharePositionOrigin: origin),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = AppPalette.of(context);
    final time = relativeHistoryTime(l10n, entry.createdAt, DateTime.now());
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
    final copied = _copiedTimer != null;
    return Dismissible(
      key: ValueKey('history-${entry.id}'),
      background: const _DeleteBackground(
        alignment: AlignmentDirectional.centerStart,
      ),
      secondaryBackground: const _DeleteBackground(
        alignment: AlignmentDirectional.centerEnd,
      ),
      onDismissed: (_) => widget.onDelete(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            type: MaterialType.transparency,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.delete):
                    widget.onDelete,
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
                    padding: const EdgeInsetsDirectional.fromSTEB(4, 12, 4, 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LanguageAvatar(code: targetCode ?? entry.target.name),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _Header(
                                pair: pair,
                                meta: ' · ${entry.engineName} · $time',
                              ),
                              const SizedBox(height: 4),
                              _LanguageText(
                                text: entry.translation,
                                code: targetCode,
                                maxLines: 6,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: colors.onSurface,
                                  fontSize: 16,
                                  height: 1.35,
                                ),
                              ),
                              const SizedBox(height: 10),
                              // The source, quoted like a linked post: a
                              // hairline box with no fill.
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border.all(color: palette.hairline),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: _LanguageText(
                                      text: entry.text,
                                      code: sourceCode,
                                      maxLines: 3,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: palette.secondaryText,
                                            fontSize: 15,
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  XActionButton(
                                    icon: copied
                                        ? Icons.check_rounded
                                        : Icons.copy_rounded,
                                    tooltip: copied
                                        ? l10n.commonCopied
                                        : l10n.commonCopy,
                                    active: copied,
                                    activeColor: palette.success,
                                    onPressed: _copy,
                                  ),
                                  XActionButton(
                                    // The label says the state, so the icon
                                    // swaps instead of using toggle semantics.
                                    icon: entry.isFavorite
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    tooltip: entry.isFavorite
                                        ? l10n.historyUnfavorite
                                        : l10n.historyFavorite,
                                    active: entry.isFavorite,
                                    activeColor: palette.like,
                                    onPressed: widget.onToggleFavorite,
                                  ),
                                  Builder(
                                    builder: (buttonContext) => XActionButton(
                                      icon: Icons.ios_share_rounded,
                                      tooltip: l10n.commonShare,
                                      onPressed: () => _share(buttonContext),
                                    ),
                                  ),
                                  PopupMenuButton<_EntryAction>(
                                    key: _menuKey,
                                    tooltip: l10n.historyEntryActions,
                                    icon: Icon(
                                      Icons.more_horiz_rounded,
                                      size: 20,
                                      color: palette.secondaryText,
                                    ),
                                    onSelected: _onAction,
                                    itemBuilder: (context) => [
                                      PopupMenuItem(
                                        value: _EntryAction.favorite,
                                        child: ListTile(
                                          contentPadding: EdgeInsets.zero,
                                          leading: Icon(
                                            entry.isFavorite
                                                ? Icons.favorite_rounded
                                                : Icons.favorite_border_rounded,
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
                                          leading: const Icon(
                                            Icons.delete_outline,
                                          ),
                                          title: Text(l10n.commonDelete),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Hairline(),
        ],
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

/// X-style short relative time of [time] as seen at [now]: "now", "5m",
/// "3h"; older than a day (the list's day headers give the date) it is the
/// clock time.
@visibleForTesting
String relativeHistoryTime(AppLocalizations l10n, DateTime time, DateTime now) {
  final age = now.difference(time);
  if (age.isNegative || age < const Duration(minutes: 1)) {
    return l10n.historyTimeNow;
  }
  if (age < const Duration(hours: 1)) {
    return l10n.historyTimeMinutes(age.inMinutes);
  }
  if (age < const Duration(days: 1)) return l10n.historyTimeHours(age.inHours);
  return DateFormat.jm(l10n.localeName).format(time.toLocal());
}

/// The bold language pair followed by the secondary " · engine · time".
class _Header extends StatelessWidget {
  const new({required this.pair, required this.meta});

  final String pair;
  final String meta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(fontSize: 15);
    return Row(
      children: [
        Flexible(
          child: Text(
            pair,
            style: style?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Flexible(
          child: Text(
            meta,
            style: style?.copyWith(color: palette.secondaryText),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
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
  const new({
    required this.text,
    required this.code,
    required this.style,
    this.maxLines = 2,
  });

  final String text;
  final String? code;
  final TextStyle? style;
  final int maxLines;

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
      maxLines: maxLines,
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

class _DeleteBackground extends StatelessWidget {
  const new({required this.alignment});

  final AlignmentDirectional alignment;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: colors.errorContainer),
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
