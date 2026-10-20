import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show Bidi, DateFormat;
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/bidi.dart';
import 'package:mozhi/core/haptics.dart';
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
/// A dictionary look-up ([HistoryEntry.isDictionary]) shows the word's
/// language as the avatar and, below the same header, a "Dictionary"
/// marker (a book icon and label), the word as the body and the entry's
/// summary quoted below it. Copy copies the word, share the word and the
/// summary; tapping it looks the word up ([onTap]).
///
/// Swipes work like a mail app's, mirrored in right-to-left layouts:
///
/// * towards the start (right to left in English) deletes: a red
///   background with a trash icon and "Delete";
/// * towards the end toggles the favourite: a background in the favourite
///   colour with a heart (a broken one to remove it), and the row springs
///   back – unless [unfavoriteRemoves] and it is a favourite, then it
///   slides away (it leaves the Favorites tab).
///
/// Neither needs a drag (WCAG 2.5.7): the favourite has its heart button,
/// delete the "More actions" menu (also opened by a long press) and the
/// Delete key while the entry has focus, and both are screen-reader custom
/// actions. With reduced motion the row jumps instead of sliding.
class HistoryEntryTile extends StatefulWidget {
  const new({
    required this.entry,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onDelete,
    this.unfavoriteRemoves = false,
    super.key,
  });

  final HistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDelete;

  /// Whether removing the favourite takes the entry out of the list (the
  /// Favorites tab): a swipe towards the end then slides a favourite away
  /// instead of springing back, and [onToggleFavorite] is called once it
  /// is gone.
  final bool unfavoriteRemoves;

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

  /// Whether a swipe in [direction] removes the row: always to delete; to
  /// toggle the favourite only when that takes the entry out of the list
  /// ([HistoryEntryTile.unfavoriteRemoves]). Otherwise the favourite is
  /// toggled right away and the row springs back.
  Future<bool> _confirmSwipe(DismissDirection direction) async {
    if (direction == DismissDirection.endToStart) return true;
    if (widget.unfavoriteRemoves && entry.isFavorite) return true;
    widget.onToggleFavorite();
    return false;
  }

  void _onSwiped(DismissDirection direction) =>
      direction == DismissDirection.endToStart
      ? widget.onDelete()
      : widget.onToggleFavorite();

  /// A tick when the swipe passes the point where letting go acts.
  void _onSwipeUpdate(DismissUpdateDetails details) {
    if (details.reached && !details.previousReached) {
      Haptics.selection(context);
    }
  }

  /// What copy copies: the translation, or a look-up's word.
  String get _copyText => entry.isDictionary ? entry.text : entry.translation;

  /// What share shares: the translation, or a look-up's word and summary.
  String get _shareText {
    if (!entry.isDictionary) return entry.translation;
    final summary = entry.translation.trim();
    return summary.isEmpty ? entry.text : '${entry.text}\n$summary';
  }

  void _copy() {
    unawaited(copyToClipboard(context, _copyText));
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
        ShareParams(text: _shareText, sharePositionOrigin: origin),
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
    final lookUp = entry.isDictionary;
    final copied = _copiedTimer != null;
    final favoriteLabel = entry.isFavorite
        ? l10n.historyUnfavorite
        : l10n.historyFavorite;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Dismissible(
      key: ValueKey('history-${entry.id}'),
      // Towards the end: what happens to the heart. Only an icon: the long
      // labels would be cut while the row moves.
      background: _SwipeBackground(
        icon: entry.isFavorite
            ? Icons.heart_broken_rounded
            : Icons.favorite_rounded,
        color: accentWithContrast(
          palette.like,
          Colors.white,
          minContrast: kTextContrast,
          darken: true,
        ),
        foreground: Colors.white,
        alignment: AlignmentDirectional.centerStart,
      ),
      // Towards the start: delete, in a red that carries white text in
      // both themes (the dark scheme's error colour is a light pink).
      secondaryBackground: _SwipeBackground(
        icon: Icons.delete_outline,
        label: l10n.commonDelete,
        color: accentWithContrast(
          colors.error,
          Colors.white,
          minContrast: kTextContrast,
          darken: true,
        ),
        foreground: Colors.white,
        alignment: AlignmentDirectional.centerEnd,
      ),
      // Reduced motion: the row jumps back or away instead of sliding, and
      // the gap closes at once.
      movementDuration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 200),
      resizeDuration: reduceMotion ? null : const Duration(milliseconds: 300),
      confirmDismiss: _confirmSwipe,
      onUpdate: _onSwipeUpdate,
      onDismissed: _onSwiped,
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
                onTapHint: lookUp
                    ? l10n.historyOpenDictionaryHint
                    : l10n.historyOpenHint,
                // What the swipes do, without swiping.
                customSemanticsActions: {
                  CustomSemanticsAction(label: l10n.commonDelete):
                      widget.onDelete,
                  CustomSemanticsAction(label: favoriteLabel):
                      widget.onToggleFavorite,
                },
                child: InkWell(
                  onTap: widget.onTap,
                  onLongPress: () => _menuKey.currentState?.showButtonMenu(),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(4, 12, 4, 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LanguageAvatar(
                          code: lookUp
                              ? sourceCode ?? entry.source.code
                              : targetCode ?? entry.target.name,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _Header(
                                pair: pair,
                                meta: '${entry.engineName} · $time',
                              ),
                              if (lookUp) ...[
                                const SizedBox(height: 6),
                                const _DictionaryMarker(),
                                const SizedBox(height: 2),
                                _LanguageText(
                                  text: entry.text,
                                  code: sourceCode,
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    color: colors.onSurface,
                                    fontWeight: FontWeight.w700,
                                    height: 1.3,
                                  ),
                                ),
                                if (entry.translation.trim().isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  // The summary, quoted like a translation's
                                  // source. Written in the app's language.
                                  _Quote(
                                    child: Text(
                                      entry.translation,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: palette.secondaryText,
                                            fontSize: 15,
                                          ),
                                    ),
                                  ),
                                ],
                              ] else ...[
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
                                // The source, quoted like a linked post.
                                _Quote(
                                  child: _LanguageText(
                                    text: entry.text,
                                    code: sourceCode,
                                    maxLines: 3,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: palette.secondaryText,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                              ],
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
                                    tooltip: favoriteLabel,
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
                                          title: Text(favoriteLabel),
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

/// [child] in a hairline box with no fill, full width (a quoted post).
class _Quote extends StatelessWidget {
  const new({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: AppPalette.of(context).hairline),
      borderRadius: AppRadius.cardBorderRadius,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: SizedBox(width: double.infinity, child: child),
    ),
  );
}

/// The small "Dictionary" label (with a book icon) of a look-up.
class _DictionaryMarker extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = AppPalette.of(context).secondaryText;
    return Row(
      key: const Key('history_dictionary_marker'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.menu_book_rounded, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            context.l10n.historyDictionaryMarker,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
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

/// The bold language pair followed by the secondary " · engine · time"
/// ([meta]) on one line when both fit. Otherwise the pair keeps the line
/// (wrapping to a second one rather than being cut to
/// "English (detected) → Fren…") and the meta moves below it.
class _Header extends StatelessWidget {
  const new({required this.pair, required this.meta});

  final String pair;
  final String meta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final base = DefaultTextStyle.of(context).style
        .merge(theme.textTheme.bodyMedium?.copyWith(fontSize: 15));
    final pairStyle = base.copyWith(
      fontWeight: FontWeight.w700,
      color: theme.colorScheme.onSurface,
    );
    final metaStyle = base.copyWith(color: palette.secondaryText);
    final oneLine = ' · $meta';
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(
            children: [
              TextSpan(text: pair, style: pairStyle),
              TextSpan(text: oneLine, style: metaStyle),
            ],
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final fits = painter.width <= constraints.maxWidth;
        painter.dispose();
        if (fits) {
          return Row(
            children: [
              // Ellipsis only guards against sub-pixel rounding.
              Flexible(
                child: Text(
                  pair,
                  style: pairStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(oneLine, style: metaStyle, maxLines: 1),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pair,
              style: pairStyle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              meta,
              style: metaStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        );
      },
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

/// What a swipe does, revealed behind the row: [icon] (and [label]) in
/// [foreground] on [color], at the side the row moves away from
/// ([alignment]: the icon nearest that edge).
class _SwipeBackground extends StatelessWidget {
  const new({
    required this.icon,
    required this.color,
    required this.foreground,
    required this.alignment,
    this.label,
  });

  final IconData icon;
  final String? label;
  final Color color;
  final Color foreground;
  final AlignmentDirectional alignment;

  @override
  Widget build(BuildContext context) {
    final atStart = alignment.start < 0;
    final label = this.label;
    final text = label == null
        ? null
        : Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(color: foreground, fontSize: 15),
            ),
          );
    // The row says the same in its actions (button, menu, custom actions).
    return ExcludeSemantics(
      child: ColoredBox(
        color: color,
        child: Align(
          alignment: alignment,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (text != null && !atStart) ...[
                  text,
                  const SizedBox(width: 12),
                ],
                Icon(icon, color: foreground),
                if (text != null && atStart) ...[
                  const SizedBox(width: 12),
                  text,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
