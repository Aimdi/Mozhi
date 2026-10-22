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
import 'package:mozhi/settings/view/widgets/search_highlight.dart';
import 'package:mozhi/translate/widgets/output_card.dart' show copyToClipboard;
import 'package:share_plus/share_plus.dart';
import 'package:translation_repository/translation_repository.dart';

enum _EntryAction { copy, share, details, favorite, delete }

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

/// The History screen's clock: the times of the entries and the day
/// headers. Replaceable in tests, so screenshots don't depend on the time
/// of day they run at.
abstract final class HistoryClock {
  static DateTime Function() now = DateTime.now;
}

/// What copying [entry] copies: the translation, or a look-up's word.
String historyCopyText(HistoryEntry entry) =>
    entry.isDictionary ? entry.text : entry.translation;

/// What sharing [entry] shares: the translation, or a look-up's word and
/// summary.
String historyShareText(HistoryEntry entry) {
  if (!entry.isDictionary) return entry.translation;
  final summary = entry.translation.trim();
  return summary.isEmpty ? entry.text : '${entry.text}\n$summary';
}

/// Shares [entry] ([historyShareText]), anchoring the share sheet on the
/// widget of [anchor] (iPad, macOS).
Future<void> shareHistoryEntry(BuildContext anchor, HistoryEntry entry) {
  final box = anchor.findRenderObject() as RenderBox?;
  final origin = box == null || !box.hasSize
      ? null
      : box.localToGlobal(Offset.zero) & box.size;
  return HistoryShare.share(
    ShareParams(text: historyShareText(entry), sharePositionOrigin: origin),
  );
}

/// The language code of [entry]'s source: the detected language when it
/// was detected, null when unknown or custom.
String? historySourceCode(HistoryEntry entry) => entry.source.isAuto
    ? entry.detectedSource
    : entry.source.isCustom
    ? null
    : entry.source.code;

/// The language code of [entry]'s target, null for a custom target.
String? historyTargetCode(HistoryEntry entry) =>
    entry.target.isCustom ? null : entry.target.code;

/// "English (detected) → French" for [entry], both names bidi-isolated so
/// that Latin-script names keep the arrow's direction in RTL locales.
String historyEntryPair(AppLocalizations l10n, HistoryEntry entry) {
  final detected = entry.detectedSource;
  final source = entry.source.isAuto && detected != null && detected.isNotEmpty
      ? l10n.historyDetected(LanguageCatalog.nameOf(detected))
      : entry.source.name;
  return l10n.historyLanguagePair(
    bidiIsolate(source),
    bidiIsolate(entry.target.name),
  );
}

/// One history entry as a compact two-line row, Google Translate style:
/// the source text (`bodyLarge`) with its translation below it
/// (`bodyMedium`, in the primary colour), a small language pair tag
/// ("EN → FR", read as the full pair) and the favourite heart at the end,
/// then "More actions". Matches of [query] are highlighted in both lines
/// (ignoring case, as the search does).
///
/// The engine and the time are not repeated on every row: the day headers
/// group the rows, and [onShowDetails] ("Details" in the menu) or the
/// detail pane on wide screens show them.
///
/// A dictionary look-up ([HistoryEntry.isDictionary]) shows a book icon
/// ("Dictionary" for screen readers) before the word and the entry's
/// summary below it. Copy copies the word, share the word and the summary;
/// tapping it looks the word up ([onTap]).
///
/// Copy, share and delete are in the "More actions" menu (also opened by a
/// long press), behind the swipes, in screen readers' custom actions and,
/// while a mouse hovers the row or the keyboard focus is in it, buttons in
/// place of the pair tag.
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
/// delete the "More actions" menu and the Delete key while the entry has
/// focus, and both are screen-reader custom actions. With reduced motion
/// the row jumps instead of sliding.
class HistoryEntryTile extends StatefulWidget {
  const new({
    required this.entry,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onDelete,
    this.unfavoriteRemoves = false,
    this.query = '',
    this.selected = false,
    this.onShowDetails,
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

  /// The search, whose matches are highlighted.
  final String query;

  /// Whether the row is the one shown in the detail pane (wide screens).
  final bool selected;

  /// Shows the entry's details ("Details" in the menu); none without it.
  final VoidCallback? onShowDetails;

  /// How long the copy action shows its check mark.
  static const copiedDuration = Duration(seconds: 2);

  /// Key of the language pair tag.
  static const pairTagKey = Key('history_pair_tag');

  @override
  State<HistoryEntryTile> createState() => _HistoryEntryTileState();
}

class _HistoryEntryTileState extends State<HistoryEntryTile> {
  final _menuKey = GlobalKey<PopupMenuButtonState<_EntryAction>>();
  Timer? _copiedTimer;
  bool _hovered = false;
  bool _focused = false;

  HistoryEntry get entry => widget.entry;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  void _onAction(_EntryAction action) => switch (action) {
    _EntryAction.copy => _copy(),
    _EntryAction.share => unawaited(shareHistoryEntry(context, entry)),
    _EntryAction.details => widget.onShowDetails?.call(),
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

  void _copy() {
    unawaited(copyToClipboard(context, historyCopyText(entry)));
    _copiedTimer?.cancel();
    setState(() {
      _copiedTimer = Timer(HistoryEntryTile.copiedDuration, () {
        if (mounted) setState(() => _copiedTimer = null);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = AppPalette.of(context);
    final lookUp = entry.isDictionary;
    final copied = _copiedTimer != null;
    final favoriteLabel = entry.isFavorite
        ? l10n.historyUnfavorite
        : l10n.historyFavorite;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final showActions = _hovered || _focused;
    final highlight = searchHighlightStyle(context);
    final sourceCode = historySourceCode(entry);
    final targetCode = historyTargetCode(entry);

    final first = _LanguageText(
      text: entry.text,
      code: sourceCode,
      query: widget.query,
      highlight: highlight,
      style: theme.textTheme.bodyLarge?.copyWith(
        color: colors.onSurface,
        fontWeight: lookUp ? FontWeight.w600 : null,
      ),
    );
    final second = entry.translation.trim().isEmpty
        ? null
        : _LanguageText(
            text: entry.translation,
            // A look-up's summary is in the app's language.
            code: lookUp ? null : targetCode,
            query: widget.query,
            highlight: highlight,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: lookUp ? palette.secondaryText : colors.primary,
            ),
          );

    final menu = PopupMenuButton<_EntryAction>(
      key: _menuKey,
      tooltip: l10n.historyEntryActions,
      icon: Icon(
        Icons.more_vert_rounded,
        size: 20,
        color: palette.secondaryText,
      ),
      onSelected: _onAction,
      itemBuilder: (context) => [
        _menuItem(_EntryAction.copy, Icons.copy_rounded, l10n.commonCopy),
        _menuItem(
          _EntryAction.share,
          Icons.ios_share_rounded,
          l10n.commonShare,
        ),
        if (widget.onShowDetails != null)
          _menuItem(
            _EntryAction.details,
            Icons.info_outline_rounded,
            l10n.historyDetails,
          ),
        _menuItem(
          _EntryAction.favorite,
          entry.isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          favoriteLabel,
        ),
        _menuItem(_EntryAction.delete, Icons.delete_outline, l10n.commonDelete),
      ],
    );

    final row = Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 8, 0, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (lookUp)
                  Row(
                    children: [
                      const _DictionaryMarker(),
                      const SizedBox(width: 6),
                      Flexible(child: first),
                    ],
                  )
                else
                  first,
                if (second != null) ...[const SizedBox(height: 2), second],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (showActions) ...[
            XActionButton(
              icon: copied ? Icons.check_rounded : Icons.copy_rounded,
              tooltip: copied ? l10n.commonCopied : l10n.commonCopy,
              active: copied,
              activeColor: palette.success,
              onPressed: _copy,
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
              icon: Icons.delete_outline,
              tooltip: l10n.commonDelete,
              onPressed: widget.onDelete,
            ),
          ] else
            _PairTag(entry: entry),
          XActionButton(
            // The label says the state, so the icon swaps instead of using
            // toggle semantics.
            icon: entry.isFavorite
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            tooltip: favoriteLabel,
            active: entry.isFavorite,
            activeColor: palette.like,
            onPressed: widget.onToggleFavorite,
          ),
          menu,
        ],
      ),
    );

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
            color: widget.selected
                ? colors.primary.withValues(alpha: 0.08)
                : Colors.transparent,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.delete):
                    widget.onDelete,
              },
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onFocusChange: (focused) => setState(() => _focused = focused),
                child: MouseRegion(
                  onEnter: (_) => setState(() => _hovered = true),
                  onExit: (_) => setState(() => _hovered = false),
                  child: Semantics(
                    selected: widget.selected ? true : null,
                    onTapHint: lookUp
                        ? l10n.historyOpenDictionaryHint
                        : l10n.historyOpenHint,
                    // What the swipes and the menu do, without them.
                    customSemanticsActions: {
                      CustomSemanticsAction(label: l10n.commonDelete):
                          widget.onDelete,
                      CustomSemanticsAction(label: favoriteLabel):
                          widget.onToggleFavorite,
                      CustomSemanticsAction(label: l10n.commonCopy): _copy,
                      CustomSemanticsAction(label: l10n.commonShare): () =>
                          unawaited(shareHistoryEntry(context, entry)),
                    },
                    child: InkWell(
                      onTap: widget.onTap,
                      onLongPress: () =>
                          _menuKey.currentState?.showButtonMenu(),
                      // The long press vibrates only with haptic feedback
                      // on.
                      enableFeedback: Haptics.enabled(context),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 56),
                        child: row,
                      ),
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

  static PopupMenuItem<_EntryAction> _menuItem(
    _EntryAction action,
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

/// The small "EN → FR" tag of a row (custom languages by name), read as
/// the whole pair ("English (detected) → French").
class _PairTag extends StatelessWidget {
  const new({required this.entry});

  final HistoryEntry entry;

  static String _short(Language language, String? code) =>
      language.isCustom ? language.name : (code ?? '?').toUpperCase();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final label = l10n.historyLanguagePair(
      bidiIsolate(_short(entry.source, historySourceCode(entry))),
      bidiIsolate(_short(entry.target, historyTargetCode(entry))),
    );
    return Semantics(
      label: historyEntryPair(l10n, entry),
      excludeSemantics: true,
      child: ConstrainedBox(
        key: HistoryEntryTile.pairTagKey,
        constraints: const BoxConstraints(maxWidth: 96),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: palette.hairline),
            borderRadius: const BorderRadius.all(
              Radius.circular(AppRadius.badge),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: palette.secondaryText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The book icon before a look-up's word, read as "Dictionary".
class _DictionaryMarker extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) => Icon(
    Icons.menu_book_rounded,
    key: const Key('history_dictionary_marker'),
    size: 18,
    color: AppPalette.of(context).secondaryText,
    semanticLabel: context.l10n.historyDictionaryMarker,
  );
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

/// User or translated text in its own language: laid out in that
/// language's direction (WCAG 1.3.2) and tagged with its locale so screen
/// readers pick the right voice and CJK text the right glyphs (WCAG 3.1.2),
/// with the matches of [query] highlighted.
///
/// [code] is a language code, or null when unknown (auto-detected without
/// a result, or a custom AI target); the direction is then guessed from
/// the text itself.
class _LanguageText extends StatelessWidget {
  const new({
    required this.text,
    required this.code,
    required this.style,
    required this.query,
    required this.highlight,
  });

  final String text;
  final String? code;
  final TextStyle? style;
  final String query;
  final TextStyle highlight;

  /// Lines shown at most (long texts end with an ellipsis).
  static const maxLines = 2;

  @override
  Widget build(BuildContext context) {
    final code = this.code;
    final known = code != null && code.isNotEmpty && code != 'auto';
    final rtl = known
        ? Bidi.isRtlLanguage(code)
        : Bidi.detectRtlDirectionality(text);
    return Text.rich(
      highlightedSpan(
        text,
        query,
        highlight: highlight,
        locale: known ? localeForLanguageCode(code) : null,
      ),
      style: style,
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A [Locale] for a language code such as `ja`, `pt-BR`, `zh_TW` or
/// `sr-Latn`, or null when [code] is not a valid language subtag.
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
