import 'dart:async';
import 'dart:ui' show SemanticsInputType;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/core/bidi.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/undo_snack_bar.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/view/dictionary_request.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/history/view/widgets/clear_history_dialog.dart';
import 'package:mozhi/history/view/widgets/history_entry_tile.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// The tabs of the History page.
enum HistoryTab {
  /// Every entry: translations and dictionary look-ups.
  all,

  /// Only the favourites.
  favorites;

  /// The tab named [name] (`all`, `favorites`), or null for anything else.
  static HistoryTab? tryParse(String? name) =>
      values.where((tab) => tab.name == name).firstOrNull;
}

/// On-device history of translations and dictionary look-ups with search,
/// favorites, filters by language pair and by where the text went, and
/// swipe actions (delete, favourite; see [HistoryEntryTile]). Reads the
/// app-wide [HistoryCubit], [SettingsCubit] and [TranslateCubit].
///
/// A full page above the tabs, opened from their app bars
/// ([TopLevelActions]; a long press on the History button opens it on the
/// Favorites tab): its back arrow returns to the tab
/// ([topLevelBackButton]); opening a translation goes to the translate
/// tab, opening a look-up to the Dictionary tab, which looks the word up
/// again (with the detail level it was saved with).
///
/// Look-ups go to the destination filters by the AI engine that wrote them
/// ([historyDestinationOf]: a local model is self-hosted, other providers
/// are in the cloud).
class HistoryPage extends StatelessWidget {
  const new({this.initialTab, super.key});

  /// Query parameter of the page's location naming the tab to open on
  /// (the name of a [HistoryTab]), e.g. `/history?tab=favorites`.
  static const tabParameter = 'tab';

  /// The page's location, opening on [tab] (null: the tab shown last).
  static String location({HistoryTab? tab}) => Uri(
    path: AppRoutes.history,
    queryParameters: tab == null ? null : {tabParameter: tab.name},
  ).toString();

  /// The tab to show when the page opens; null keeps the one shown last
  /// ([HistoryState.favoritesOnly]).
  final HistoryTab? initialTab;

  @override
  Widget build(BuildContext context) => HistoryView(initialTab: initialTab);
}

class HistoryView extends StatefulWidget {
  const new({this.initialTab, super.key});

  /// See [HistoryPage.initialTab].
  final HistoryTab? initialTab;

  /// Key of the search field.
  static const searchFieldKey = Key('history_search');

  /// Key of the language pair filter chip.
  static const pairFilterKey = Key('history_filter_pair');

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _search = TextEditingController(
    text: context.read<HistoryCubit>().state.query,
  );

  /// Entries deleted but possibly not yet removed from the state.
  final Set<String> _dismissed = {};

  /// Favourites taken out of the Favorites tab, hidden there until the
  /// state no longer has them as favourites (or Undo puts them back).
  final Set<String> _unfavorited = {};

  /// Tiles by entry id (see [_tile]).
  final Map<String, HistoryEntryTile> _tiles = {};

  /// The All / Favorites tabs, kept in step with the cubit's filter.
  late final TabController _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: context.read<HistoryCubit>().state.favoritesOnly ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    _showTab(widget.initialTab);
  }

  @override
  void didUpdateWidget(HistoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTab != oldWidget.initialTab) {
      _showTab(widget.initialTab);
    }
  }

  /// Switches the cubit's filter to [tab] (the tab bar follows it).
  void _showTab(HistoryTab? tab) {
    if (tab == null) return;
    final cubit = context.read<HistoryCubit>();
    final favorites = tab == HistoryTab.favorites;
    if (cubit.state.favoritesOnly != favorites) {
      cubit.setFavoritesOnly(enabled: favorites);
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  void _open(HistoryEntry entry) {
    if (entry.isDictionary) {
      _openLookUp(entry);
      return;
    }
    context.read<TranslateCubit>()
      ..setSource(entry.source)
      ..setTarget(entry.target)
      ..setInputAndTranslate(entry.text);
    context.go(AppRoutes.translate);
  }

  /// Opens the Dictionary tab on [entry]'s word and languages and looks it
  /// up with its detail level (also when the tab already shows that word,
  /// see [DictionaryLookUpRequest]).
  void _openLookUp(HistoryEntry entry) {
    final source = entry.source;
    final target = entry.target;
    context.go(
      AppRoutes.dictionaryWord(
        word: entry.text,
        from: source.isCustom ? null : source.code,
        to: target.isCustom || target.isAuto ? null : target.code,
      ),
      extra: DictionaryLookUpRequest(verbosity: entry.verbosity),
    );
  }

  /// Deletes [entry]; Undo puts it back as it was (its place, favourite
  /// and time: [HistoryCubit.restore]).
  void _delete(HistoryEntry entry) {
    final l10n = context.l10n;
    final cubit = context.read<HistoryCubit>();
    setState(() => _dismissed.add(entry.id));
    unawaited(cubit.delete(entry.id));
    showUndoSnackBar(
      context,
      message: entry.isDictionary
          ? l10n.historyLookUpDeleted
          : l10n.historyDeleted,
      onUndo: () {
        unawaited(cubit.restore(entry));
        if (mounted) setState(() => _dismissed.remove(entry.id));
      },
    );
  }

  /// Toggles [entry]'s favourite. In the Favorites tab that takes a
  /// favourite out of the list, so it goes at once and Undo puts it back.
  void _toggleFavorite(HistoryEntry entry) {
    final cubit = context.read<HistoryCubit>();
    if (!cubit.state.favoritesOnly || !entry.isFavorite) {
      unawaited(cubit.toggleFavorite(entry.id));
      return;
    }
    final l10n = context.l10n;
    setState(() => _unfavorited.add(entry.id));
    unawaited(cubit.toggleFavorite(entry.id));
    showUndoSnackBar(
      context,
      message: l10n.historyUnfavorited,
      onUndo: () {
        // Stars the entry as it is now: a new look-up may have updated it.
        unawaited(cubit.restoreFavorite(entry));
        if (mounted) setState(() => _unfavorited.remove(entry.id));
      },
    );
  }

  void _onSearch(String query) {
    setState(() {});
    context.read<HistoryCubit>().search(query);
  }

  void _clearSearch() {
    _search.clear();
    _onSearch('');
  }

  /// Picks the language pair to show (or all of them).
  Future<void> _pickPair(HistoryState state) async {
    final cubit = context.read<HistoryCubit>();
    final choice = await showModalBottomSheet<(HistoryPair?,)>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _PairSheet(
        pairs: state.pairs,
        selected: state.pair,
        lookUps: state.hasLookUps,
      ),
    );
    if (choice == null) return;
    cubit.filterByPair(choice.$1);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<HistoryCubit>().state;
    final saveHistory = context.select<SettingsCubit, bool>(
      (cubit) => cubit.state.saveHistory,
    );
    final incognito = context.select<SettingsCubit, bool>(
      (cubit) => cubit.state.incognito,
    );
    final maxAge = context.select<SettingsCubit, Duration?>(
      (cubit) => cubit.state.historyRetention.maxAge,
    );
    final providers = context.select<SettingsCubit, List<AiProviderConfig>>(
      (cubit) => cubit.state.providers,
    );
    final instances = context.select<SettingsCubit, List<MozhiInstance>>(
      (cubit) => cubit.state.instances,
    );
    HistoryDestination? destinationOf(String engineId) => historyDestinationOf(
      engineId,
      providers: providers,
      instances: instances,
    );
    bool hidden(HistoryEntry entry) =>
        _dismissed.contains(entry.id) ||
        (state.favoritesOnly && _unfavorited.contains(entry.id));
    final visible =
        state.visibleWith(destinationOf).where((e) => !hidden(e)).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final hasEntries = state.entries.any((e) => !_dismissed.contains(e.id));

    final cubit = context.read<HistoryCubit>();
    return MultiBlocListener(
      listeners: [
        BlocListener<HistoryCubit, HistoryState>(
          listenWhen: (previous, current) =>
              previous.entries != current.entries,
          listener: _forgetHidden,
        ),
        BlocListener<HistoryCubit, HistoryState>(
          listenWhen: (previous, current) =>
              previous.favoritesOnly != current.favoritesOnly,
          listener: (context, state) =>
              _tabs.animateTo(state.favoritesOnly ? 1 : 0),
        ),
      ],
      child: Scaffold(
        appBar: AppBar(
          leading: topLevelBackButton(context),
          title: Text(l10n.historyTitle),
          actions: [
            if (hasEntries)
              IconButton(
                tooltip: l10n.historyClearMenu,
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () => confirmClearHistory(context),
              ),
          ],
        ),
        floatingActionButton: hasEntries
            ? FloatingActionButton(
                tooltip: l10n.historyNewTranslation,
                onPressed: () => context.go(AppRoutes.translate),
                child: const Icon(Icons.add_rounded),
              )
            : null,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final padding = centeredPadding(
              constraints.maxWidth,
              maxWidth: 760,
            );
            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: padding.copyWith(bottom: 8),
                  sliver: SliverList.list(
                    children: [
                      if (incognito || !saveHistory)
                        _HistoryPausedBanner(incognito: incognito),
                      _HistorySearchField(
                        controller: _search,
                        onChanged: _onSearch,
                        onClear: _clearSearch,
                      ),
                      if (hasEntries)
                        _HistoryFilterBar(
                          state: state,
                          destinations: state.destinationsWith(destinationOf),
                          onPickPair: () => unawaited(_pickPair(state)),
                        ),
                    ],
                  ),
                ),
                // X-style tabs that stay on top of the timeline.
                PinnedHeaderSliver(
                  child: BlurBar(
                    bottom: true,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: padding.left - 16,
                      ),
                      child: TabBar(
                        controller: _tabs,
                        dividerHeight: 0,
                        onTap: (index) =>
                            cubit.setFavoritesOnly(enabled: index == 1),
                        tabs: [
                          Tab(text: l10n.historyFilterAll),
                          Tab(text: l10n.historyFilterFavorites),
                        ],
                      ),
                    ),
                  ),
                ),
                if (maxAge != null)
                  SliverPadding(
                    padding: padding.copyWith(top: 0, bottom: 0),
                    sliver: SliverToBoxAdapter(
                      child: _RetentionNote(days: maxAge.inDays),
                    ),
                  ),
                ..._content(context, state, visible, hasEntries, padding),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Once the cubit no longer has a deleted entry (or no longer has an
  /// entry taken out of the Favorites tab as a favourite), stop hiding its
  /// id: the state hides it now, and a later re-import or favourite shows
  /// it again.
  void _forgetHidden(BuildContext context, HistoryState state) {
    final byId = {for (final entry in state.entries) entry.id: entry};
    _dismissed.removeWhere((id) => !byId.containsKey(id));
    _unfavorited.removeWhere((id) => !(byId[id]?.isFavorite ?? false));
    _tiles.removeWhere((id, _) => !byId.containsKey(id));
  }

  List<Widget> _content(
    BuildContext context,
    HistoryState state,
    List<HistoryEntry> visible,
    bool hasEntries,
    EdgeInsets padding,
  ) {
    final l10n = context.l10n;
    if (!hasEntries &&
        (state.status == HistoryStatus.initial ||
            state.status == HistoryStatus.loading)) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: CircularProgressIndicator(
              semanticsLabel: l10n.historyLoading,
            ),
          ),
        ),
      ];
    }
    if (state.status == HistoryStatus.unreadable) {
      return [
        _EmptyStateSliver(
          child: EmptyStateView(
            icon: Icons.lock_outline,
            tone: EmptyStateTone.error,
            title: l10n.historyUnreadableTitle,
            body: l10n.historyUnreadableBody,
            action: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => context.read<HistoryCubit>().load(),
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.commonRetry),
                ),
                TextButton(
                  onPressed: () => _confirmStartOver(context),
                  child: Text(l10n.historyUnreadableStartOver),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (!hasEntries && state.status == HistoryStatus.failure) {
      return [
        _EmptyStateSliver(
          child: EmptyStateView(
            icon: Icons.cloud_off_outlined,
            tone: EmptyStateTone.error,
            title: l10n.historyLoadFailed,
            action: FilledButton.tonalIcon(
              onPressed: () => context.read<HistoryCubit>().load(),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.commonRetry),
            ),
          ),
        ),
      ];
    }
    if (visible.isEmpty) {
      final query = state.query.trim();
      final cubit = context.read<HistoryCubit>();
      final (icon, title, body, action) = !hasEntries
          ? (
              Icons.history_rounded,
              l10n.historyEmptyTitle,
              l10n.historyEmptyBody,
              FilledButton.icon(
                onPressed: () => context.go(AppRoutes.translate),
                icon: const Icon(Icons.translate),
                label: Text(l10n.historyEmptyAction),
              ),
            )
          : query.isNotEmpty
          ? (
              Icons.search_off,
              l10n.historyNoMatchesTitle,
              l10n.historyNoMatchesBody(query),
              FilledButton.tonalIcon(
                onPressed: _clearSearch,
                icon: const Icon(Icons.close),
                label: Text(l10n.historyClearSearch),
              ),
            )
          : state.hasFilters
          ? (
              Icons.filter_alt_off_outlined,
              l10n.historyNoFilterMatchesTitle,
              l10n.historyNoFilterMatchesBody,
              FilledButton.tonalIcon(
                onPressed: cubit.clearFilters,
                icon: const Icon(Icons.close),
                label: Text(l10n.historyClearFilters),
              ),
            )
          : state.favoritesOnly
          ? (
              // The heart of the favourite buttons.
              Icons.favorite_border_rounded,
              l10n.historyNoFavoritesTitle,
              l10n.historyNoFavoritesHeartBody,
              FilledButton.tonal(
                onPressed: () => cubit.setFavoritesOnly(enabled: false),
                child: Text(l10n.historyShowAll),
              ),
            )
          : (
              Icons.history_rounded,
              l10n.historyEmptyTitle,
              l10n.historyEmptyBody,
              null,
            );
      return [
        _EmptyStateSliver(
          child: EmptyStateView(
            icon: icon,
            title: title,
            body: body,
            action: action,
            // Search and filter results change as the user types or
            // picks: say when there are none (WCAG 4.1.3).
            announce: hasEntries && (query.isNotEmpty || state.hasFilters),
          ),
        ),
      ];
    }

    final rows = <Object>[];
    DateTime? lastDay;
    for (final entry in visible) {
      final day = _day(entry.createdAt);
      if (day != lastDay) rows.add(lastDay = day);
      rows.add(entry);
    }
    final theme = Theme.of(context);
    // The days are section headings, like the settings sections.
    final headerStyle = theme.textTheme.titleLarge?.copyWith(
      color: theme.colorScheme.onSurface,
    );
    return [
      SliverPadding(
        // Room below the last row for the floating action button.
        padding: padding.copyWith(top: 0, bottom: 96),
        // Built lazily: only the rows on screen exist, however long the
        // history is.
        sliver: SliverList.builder(
          itemCount: rows.length,
          findChildIndexCallback: (key) {
            if (key is! ValueKey<String>) return null;
            final index = rows.indexWhere(
              (row) => row is HistoryEntry && row.id == key.value,
            );
            return index < 0 ? null : index;
          },
          itemBuilder: (context, index) => switch (rows[index]) {
            final HistoryEntry entry => _tile(
              entry,
              unfavoriteRemoves: state.favoritesOnly,
            ),
            final DateTime day => Padding(
              key: ValueKey(day),
              padding: const EdgeInsetsDirectional.fromSTEB(4, 16, 4, 4),
              child: Semantics(
                header: true,
                child: Text(_dayLabel(l10n, day), style: headerStyle),
              ),
            ),
            _ => const SizedBox.shrink(), // coverage:ignore-line
          },
        ),
      ),
    ];
  }

  /// Asks before setting the unreadable history aside for a new one.
  Future<void> _confirmStartOver(BuildContext context) async {
    final l10n = context.l10n;
    final cubit = context.read<HistoryCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.restart_alt),
        title: Text(l10n.historyUnreadableConfirmTitle),
        content: Text(l10n.historyUnreadableConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            key: const Key('history_start_over_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.historyUnreadableStartOver),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await cubit.discardUnreadable();
  }

  /// The tile for [entry], reused while the entry (and the tab) is
  /// unchanged so that a state change (a favorite toggled, an entry added,
  /// a search) only rebuilds the tiles whose entries changed.
  HistoryEntryTile _tile(
    HistoryEntry entry, {
    required bool unfavoriteRemoves,
  }) {
    final cached = _tiles[entry.id];
    if (cached != null &&
        cached.entry == entry &&
        cached.unfavoriteRemoves == unfavoriteRemoves) {
      return cached;
    }
    return _tiles[entry.id] = HistoryEntryTile(
      key: ValueKey(entry.id),
      entry: entry,
      unfavoriteRemoves: unfavoriteRemoves,
      onTap: () => _open(entry),
      onToggleFavorite: () => _toggleFavorite(entry),
      onDelete: () => _delete(entry),
    );
  }

  static DateTime _day(DateTime time) {
    final local = time.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  static String _dayLabel(AppLocalizations l10n, DateTime day) {
    final today = _day(HistoryClock.now());
    if (day == today) return l10n.historyToday;
    if (day == DateTime(today.year, today.month, today.day - 1)) {
      return l10n.historyYesterday;
    }
    final format = day.year == today.year
        ? DateFormat.MMMMEEEEd(l10n.localeName)
        : DateFormat.yMMMMEEEEd(l10n.localeName);
    return format.format(day);
  }
}

/// An empty or error state ([child], an [EmptyStateView]) in the space
/// below the tabs, a third of the way down: the optical centre, close to
/// the search and the tabs it answers rather than low on a tall screen. It
/// scrolls when it does not fit (large text).
class _EmptyStateSliver extends StatelessWidget {
  const new({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SliverFillRemaining(
    hasScrollBody: false,
    child: Column(children: [const Spacer(), child, const Spacer(flex: 2)]),
  );
}

/// The label of [destination] (as in the translator's destination badges).
String historyDestinationLabel(
  AppLocalizations l10n,
  HistoryDestination destination,
) => switch (destination) {
  HistoryDestination.onDevice => l10n.commonDestinationOnDevice,
  HistoryDestination.selfHosted => l10n.translateBadgeSelfHosted,
  HistoryDestination.publicServer => l10n.translateBadgePublic,
  HistoryDestination.cloud => l10n.translateBadgeCloud,
};

/// "English → French" for [pair], with both names bidi-isolated.
String historyPairLabel(AppLocalizations l10n, HistoryPair pair) =>
    l10n.historyLanguagePair(
      bidiIsolate(pair.source.name),
      bidiIsolate(pair.target.name),
    );

/// The filters below the search: the language pair (a chip that opens a
/// list of the pairs in the history) and where the text went (one chip per
/// destination in the history), plus "Clear filters" while one is set.
///
/// Filters that would not narrow anything (a single pair, a single
/// destination) are left out unless set.
class _HistoryFilterBar extends StatelessWidget {
  const new({
    required this.state,
    required this.destinations,
    required this.onPickPair,
  });

  final HistoryState state;

  /// The destinations of the entries, in display order.
  final List<HistoryDestination> destinations;
  final VoidCallback onPickPair;

  static IconData _iconOf(HistoryDestination destination) =>
      switch (destination) {
        HistoryDestination.onDevice => Icons.phone_android_outlined,
        HistoryDestination.selfHosted => Icons.home_outlined,
        HistoryDestination.publicServer => Icons.public,
        HistoryDestination.cloud => Icons.cloud_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final cubit = context.read<HistoryCubit>();
    final pair = state.pair;
    final destination = state.destination;
    final showPairs = pair != null || state.pairs.length > 1;
    final shown = [
      ...destinations,
      if (destination != null && !destinations.contains(destination))
        destination,
    ];
    final showDestinations = destination != null || destinations.length > 1;
    if (!showPairs && !showDestinations) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: l10n.historyFilters,
        child: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // A plain button styled like the chips (it opens the list of
            // pairs, it is not a toggle), tinted while a pair is set; the
            // label names the pair.
            if (showPairs)
              OutlinedButton.icon(
                key: HistoryView.pairFilterKey,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.padded,
                  padding: const EdgeInsetsDirectional.only(start: 8, end: 4),
                  shape: const StadiumBorder(),
                  backgroundColor: pair == null
                      ? null
                      : colors.secondaryContainer,
                  foregroundColor: pair == null
                      ? colors.onSurfaceVariant
                      : colors.onSecondaryContainer,
                  side: pair == null
                      ? BorderSide(color: colors.outlineVariant)
                      : BorderSide.none,
                ),
                onPressed: onPickPair,
                icon: const Icon(Icons.translate, size: 18),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        pair == null
                            ? l10n.historyFilterAllPairs
                            : historyPairLabel(l10n, pair),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const ExcludeSemantics(
                      child: Icon(Icons.arrow_drop_down, size: 18),
                    ),
                  ],
                ),
              ),
            if (showDestinations)
              for (final value in shown)
                FilterChip(
                  key: Key('history_filter_${value.name}'),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  selected: destination == value,
                  avatar: Icon(_iconOf(value), size: 18),
                  label: Text(historyDestinationLabel(l10n, value)),
                  onSelected: (selected) =>
                      cubit.filterByDestination(selected ? value : null),
                ),
            if (state.hasFilters)
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: cubit.clearFilters,
                child: Text(l10n.historyClearFilters),
              ),
          ],
        ),
      ),
    );
  }
}

/// The language pairs of the history (with their number of entries) and
/// "All language pairs"; pops the choice as a record (null pair: all).
class _PairSheet extends StatelessWidget {
  const new({
    required this.pairs,
    required this.selected,
    required this.lookUps,
  });

  final List<(HistoryPair, int)> pairs;
  final HistoryPair? selected;

  /// Whether the history has dictionary look-ups: the counts are then
  /// "entries" rather than "translations".
  final bool lookUps;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final check = Icon(Icons.check, color: theme.colorScheme.primary);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      builder: (context, controller) => ListView(
        controller: controller,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Semantics(
              header: true,
              child: Text(
                l10n.historyFilterPairTitle,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          ListTile(
            selected: selected == null,
            leading: const Icon(Icons.translate),
            title: Text(l10n.historyFilterAllPairs),
            trailing: selected == null ? check : null,
            onTap: () => Navigator.of(context).pop((null,)),
          ),
          for (final (pair, count) in pairs)
            ListTile(
              selected: selected == pair,
              leading: pair.source.isAuto || pair.source.isCustom
                  ? const Icon(Icons.auto_awesome_outlined)
                  : LanguageAvatar(code: pair.source.code),
              title: Text(historyPairLabel(l10n, pair)),
              subtitle: Text(
                lookUps
                    ? l10n.historyFilterPairEntries(count)
                    : l10n.historyFilterPairCount(count),
              ),
              trailing: selected == pair ? check : null,
              onTap: () => Navigator.of(context).pop((pair,)),
            ),
        ],
      ),
    );
  }
}

/// Says that old entries are deleted automatically (history retention).
class _RetentionNote extends StatelessWidget {
  const new({required this.days});

  final int days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = AppPalette.of(context).secondaryText;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 12, 4, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.auto_delete_outlined, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.l10n.historyRetentionNote(days),
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The history search field: outlined and rounded like the app's other
/// search fields, with keyboard learning off while incognito
/// ([imeLearningAllowed]), which [SearchBar] cannot do.
class _HistorySearchField extends StatelessWidget {
  const new({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const none = InputBorder.none;
    // The outline of the theme's text fields.
    final outline =
        theme.inputDecorationTheme.enabledBorder?.borderSide.color ??
        colors.outline;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.fieldBorderRadius,
        side: BorderSide(color: outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.search, color: colors.onSurface),
              ),
              Expanded(
                child: Semantics(
                  inputType: SemanticsInputType.search,
                  child: TextField(
                    key: HistoryView.searchFieldKey,
                    controller: controller,
                    onChanged: onChanged,
                    enableIMEPersonalizedLearning: imeLearningAllowed(context),
                    textInputAction: TextInputAction.search,
                    style: theme.textTheme.bodyLarge,
                    decoration: InputDecoration(
                      hintText: l10n.historySearchHint,
                      hintStyle: theme.textTheme.bodyLarge?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                      filled: false,
                      border: none,
                      enabledBorder: none,
                      focusedBorder: none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ),
              if (controller.text.isNotEmpty)
                IconButton(
                  tooltip: l10n.historyClearSearch,
                  icon: Icon(Icons.close, color: colors.onSurfaceVariant),
                  onPressed: onClear,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "History is paused": incognito is on ([incognito]) or saving history is
/// off; the action turns that off.
class _HistoryPausedBanner extends StatelessWidget {
  const new({required this.incognito});

  final bool incognito;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = AppPalette.of(context);
    final settings = context.read<SettingsCubit>();
    final (icon, body, action, onPressed) = incognito
        ? (
            Icons.visibility_off_outlined,
            l10n.historyPausedIncognito,
            l10n.historyTurnOffIncognito,
            () => settings.setIncognito(enabled: false),
          )
        : (
            Icons.history_toggle_off,
            l10n.historyDisabledBanner,
            l10n.historyTurnOn,
            () => settings.setSaveHistory(enabled: true),
          );
    // A flat, hairline-bordered notice with a pill action.
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        container: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: palette.hairline),
            borderRadius: AppRadius.cardBorderRadius,
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: colors.onSurface),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.historyPausedTitle,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: colors.onSurface,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            body,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton(
                    style: FilledButton.styleFrom(shape: const StadiumBorder()),
                    onPressed: onPressed,
                    child: Text(action),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
