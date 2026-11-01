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
import 'package:mozhi/history/view/widgets/history_entry_details.dart';
import 'package:mozhi/history/view/widgets/history_entry_tile.dart';
import 'package:mozhi/history/view/widgets/phrasebook_export.dart'
    deferred as phrasebook;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart'
    show PhraseCollection, PhraseDraft;
import 'package:mozhi/phrasebook/widgets/add_to_phrasebook.dart';
import 'package:mozhi/phrasebook/widgets/phrasebook_labels.dart'
    show maybePhrasebookRepository;
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

/// On-device history of translations and dictionary look-ups with search
/// (matches highlighted), favorites, filters by language pair and by where
/// the text went, and compact rows with swipe actions (delete, favourite;
/// see [HistoryEntryTile]). Reads the app-wide [HistoryCubit],
/// [SettingsCubit] and [TranslateCubit].
///
/// The Favorites tab is a phrasebook: grouped by language pair, with chips
/// to show one pair, and "Export favorites" to a CSV file for Anki and
/// spreadsheets (`showPhrasebookExport`).
///
/// From [HistoryView.twoPaneBreakpoint] the list sits beside the selected
/// entry's details ([HistoryEntryDetails]): tapping a row selects it, and
/// the details open it in the translator. On phones tapping a row opens it
/// and "Details" (in its menu) shows them in a sheet.
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

  /// Key of "Export favorites".
  static const exportKey = Key('history_export');

  /// Key of the language pair chips of the Favorites tab.
  static const favoritePairsKey = Key('history_favorite_pairs');

  /// Key of "Open phrasebook" (the Favorites tab).
  static const openPhrasebookKey = Key('history_open_phrasebook');

  /// Width from which the list and the selected entry are side by side.
  static const twoPaneBreakpoint = 840.0;

  /// Width of the list beside the selected entry.
  static const listPaneWidth = 440.0;

  /// Exports the favourites shown as a CSV file; replaceable in tests.
  /// Loads the export (and the file pickers) on first use.
  @visibleForTesting
  static Future<void> Function(BuildContext context, List<HistoryEntry> entries)
  exportFavorites = _exportFavorites;

  // coverage:ignore-start
  static Future<void> _exportFavorites(
    BuildContext context,
    List<HistoryEntry> entries,
  ) async {
    await phrasebook.loadLibrary();
    if (!context.mounted) return;
    await phrasebook.showPhrasebookExport(context, entries);
  }
  // coverage:ignore-end

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

  /// The entry shown beside the list on wide screens (null: the first).
  String? _selectedId;

  /// Whether each cached tile was built for a wide screen.
  final Map<String, bool> _tileWide = {};

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

  /// Shows [entry]'s details: beside the list on wide screens ([wide]),
  /// in a sheet otherwise.
  void _showDetails(HistoryEntry entry, {required bool wide}) {
    if (wide) {
      setState(() => _selectedId = entry.id);
      return;
    }
    unawaited(
      showHistoryEntryDetails(
        context,
        entry: entry,
        onOpen: () => _open(entry),
        onToggleFavorite: () => _toggleFavorite(entry),
        onDelete: () => _delete(entry),
      ),
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
            // The favorites are the phrasebook's Favorites collection.
            if (state.favoritesOnly &&
                maybePhrasebookRepository(context) != null)
              IconButton(
                key: HistoryView.openPhrasebookKey,
                tooltip: l10n.historyOpenPhrasebook,
                icon: const Icon(Icons.collections_bookmark_outlined),
                onPressed: () => unawaited(
                  context.push<void>(
                    phrasebookLocation(
                      collectionId: PhraseCollection.favoritesId,
                    ),
                  ),
                ),
              ),
            if (state.favoritesOnly && visible.isNotEmpty)
              Builder(
                builder: (context) => IconButton(
                  key: HistoryView.exportKey,
                  tooltip: l10n.historyExportFavorites,
                  icon: const Icon(Icons.file_download_outlined),
                  onPressed: () =>
                      unawaited(HistoryView.exportFavorites(context, visible)),
                ),
              ),
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
            final wide =
                constraints.maxWidth >= HistoryView.twoPaneBreakpoint &&
                hasEntries;
            if (!wide) {
              return _list(
                context,
                state: state,
                visible: visible,
                hasEntries: hasEntries,
                maxAge: maxAge,
                saveHistory: saveHistory,
                incognito: incognito,
                destinationOf: destinationOf,
                padding: centeredPadding(constraints.maxWidth, maxWidth: 760),
                wide: false,
              );
            }
            final selected =
                visible.where((e) => e.id == _selectedId).firstOrNull ??
                visible.firstOrNull;
            // Each pane is its own focus traversal group and semantics
            // container: the list is finished before the details.
            Widget pane(Widget child) => Semantics(
              container: true,
              explicitChildNodes: true,
              child: FocusTraversalGroup(child: child),
            );
            return Row(
              key: const Key('history_panes'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: HistoryView.listPaneWidth,
                  child: pane(
                    _list(
                      context,
                      state: state,
                      visible: visible,
                      hasEntries: hasEntries,
                      maxAge: maxAge,
                      saveHistory: saveHistory,
                      incognito: incognito,
                      destinationOf: destinationOf,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      wide: true,
                      selectedId: selected?.id,
                    ),
                  ),
                ),
                const Hairline(vertical: true),
                Expanded(child: pane(_detailPane(selected))),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The search, filters, tabs and entries; on wide screens beside the
  /// details of [selectedId].
  Widget _list(
    BuildContext context, {
    required HistoryState state,
    required List<HistoryEntry> visible,
    required bool hasEntries,
    required Duration? maxAge,
    required bool saveHistory,
    required bool incognito,
    required HistoryDestinationOf destinationOf,
    required EdgeInsets padding,
    required bool wide,
    String? selectedId,
  }) {
    final l10n = context.l10n;
    final cubit = context.read<HistoryCubit>();
    final favoritePairs = state.favoritesOnly
        ? _favoritePairs(state.entries)
        : const <(HistoryPair, int)>[];
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
                  // The Favorites tab has its pair chips.
                  showPairs: !state.favoritesOnly,
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
              padding: EdgeInsets.symmetric(horizontal: padding.left - 16),
              child: TabBar(
                controller: _tabs,
                dividerHeight: 0,
                onTap: (index) => cubit.setFavoritesOnly(enabled: index == 1),
                tabs: [
                  Tab(text: l10n.historyFilterAll),
                  Tab(text: l10n.historyFilterFavorites),
                ],
              ),
            ),
          ),
        ),
        if (favoritePairs.length > 1 ||
            (state.favoritesOnly && state.pair != null))
          SliverPadding(
            padding: padding.copyWith(top: 8, bottom: 0),
            sliver: SliverToBoxAdapter(
              child: _FavoritePairChips(
                pairs: favoritePairs,
                selected: state.pair,
                onSelected: cubit.filterByPair,
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
        ..._content(
          context,
          state,
          visible,
          hasEntries,
          padding,
          wide: wide,
          selectedId: selectedId,
        ),
      ],
    );
  }

  /// The language pairs of the favourites in [entries], with how many
  /// favourites each has, most first.
  static List<(HistoryPair, int)> _favoritePairs(List<HistoryEntry> entries) =>
      HistoryState(
        entries: [
          for (final entry in entries)
            if (entry.isFavorite) entry,
        ],
      ).pairs;

  /// The details of [entry] beside the list, or a hint without one.
  Widget _detailPane(HistoryEntry? entry) {
    final l10n = context.l10n;
    if (entry == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.historyDetailEmpty,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: AppPalette.of(context).secondaryText),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      key: const Key('history_detail_pane'),
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 96),
      child: Align(
        alignment: AlignmentDirectional.topStart,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: HistoryEntryDetails(
            entry: entry,
            onOpen: () => _open(entry),
            onToggleFavorite: () => _toggleFavorite(entry),
            onDelete: () => _delete(entry),
          ),
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
    _tileWide.removeWhere((id, _) => !byId.containsKey(id));
  }

  List<Widget> _content(
    BuildContext context,
    HistoryState state,
    List<HistoryEntry> visible,
    bool hasEntries,
    EdgeInsets padding, {
    required bool wide,
    String? selectedId,
  }) {
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

    // Favourites are a phrasebook, grouped by language pair; the history
    // is a timeline, grouped by day.
    final rows = <Object>[];
    if (state.favoritesOnly) {
      final byPair = <HistoryPair, List<HistoryEntry>>{};
      for (final entry in visible) {
        (byPair[HistoryPair.of(entry)] ??= []).add(entry);
      }
      // The biggest group first; groups of the same size in the order of
      // their newest entry (List.sort is not stable).
      final order = [for (final pair in byPair.keys) pair];
      final groups = byPair.entries.toList()
        ..sort((a, b) {
          final bySize = b.value.length.compareTo(a.value.length);
          return bySize != 0
              ? bySize
              : order.indexOf(a.key).compareTo(order.indexOf(b.key));
        });
      for (final MapEntry(key: pair, value: entries) in groups) {
        rows
          ..add((pair, entries.length, entries.any((e) => e.isDictionary)))
          ..addAll(entries);
      }
    } else {
      DateTime? lastDay;
      for (final entry in visible) {
        final day = _day(entry.createdAt);
        if (day != lastDay) rows.add(lastDay = day);
        rows.add(entry);
      }
    }
    final theme = Theme.of(context);
    // The days are section headings, like the settings sections.
    final headerStyle = theme.textTheme.titleLarge?.copyWith(
      color: theme.colorScheme.onSurface,
    );
    final query = state.query.trim();
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
              query: query,
              wide: wide,
              selected: wide && entry.id == selectedId,
            ),
            final DateTime day => Padding(
              key: ValueKey(day),
              padding: const EdgeInsetsDirectional.fromSTEB(4, 16, 4, 4),
              child: Semantics(
                header: true,
                child: Text(_dayLabel(l10n, day), style: headerStyle),
              ),
            ),
            (final HistoryPair pair, final int count, final bool lookUps) =>
              _PairHeader(
                key: ValueKey(pair),
                pair: pair,
                count: count,
                lookUps: lookUps,
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
    required String query,
    required bool wide,
    required bool selected,
  }) {
    final cached = _tiles[entry.id];
    if (cached != null &&
        cached.entry == entry &&
        cached.unfavoriteRemoves == unfavoriteRemoves &&
        cached.query == query &&
        cached.selected == selected &&
        _tileWide[entry.id] == wide) {
      return cached;
    }
    _tileWide[entry.id] = wide;
    return _tiles[entry.id] = HistoryEntryTile(
      key: ValueKey(entry.id),
      entry: entry,
      unfavoriteRemoves: unfavoriteRemoves,
      query: query,
      selected: selected,
      // Wide screens show the details beside the list: a tap selects.
      onTap: wide ? () => _showDetails(entry, wide: true) : () => _open(entry),
      onShowDetails: () => _showDetails(entry, wide: wide),
      onToggleFavorite: () => _toggleFavorite(entry),
      onDelete: () => _delete(entry),
      onAddToPhrasebook: maybePhrasebookRepository(context) == null
          ? null
          : () => unawaited(
              showAddToPhrasebook(context, PhraseDraft.fromHistory(entry)),
            ),
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
      bidiIsolate(languageNameIn(l10n, pair.source)),
      bidiIsolate(languageNameIn(l10n, pair.target)),
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
    this.showPairs = true,
  });

  final HistoryState state;

  /// Whether the language pair filter is offered here.
  final bool showPairs;

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
    final look = AppLook.of(context);
    final cubit = context.read<HistoryCubit>();
    final pair = state.pair;
    final destination = state.destination;
    final showPairs =
        this.showPairs && (pair != null || state.pairs.length > 1);
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
                  shape: look.control,
                  backgroundColor: pair == null
                      ? null
                      : colors.secondaryContainer,
                  foregroundColor: pair == null
                      ? colors.onSurfaceVariant
                      : colors.onSecondaryContainer,
                  side: pair == null
                      ? BorderSide(color: colors.outline)
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

/// The heading of a language pair's group in the Favorites tab: the pair
/// and how many favourites it has.
class _PairHeader extends StatelessWidget {
  const new({
    required this.pair,
    required this.count,
    required this.lookUps,
    super.key,
  });

  final HistoryPair pair;
  final int count;

  /// Whether to count entries rather than translations.
  final bool lookUps;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final counted = lookUps
        ? l10n.historyFilterPairEntries(count)
        : l10n.historyFilterPairCount(count);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 16, 4, 4),
      child: Semantics(
        header: true,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: historyPairLabel(l10n, pair)),
              TextSpan(
                text: ' · $counted',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppPalette.of(context).secondaryText,
                ),
              ),
            ],
          ),
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// Chips that show one language pair of the favourites (or all of them),
/// in a row that scrolls sideways.
class _FavoritePairChips extends StatelessWidget {
  const new({
    required this.pairs,
    required this.selected,
    required this.onSelected,
  });

  final List<(HistoryPair, int)> pairs;
  final HistoryPair? selected;
  final ValueChanged<HistoryPair?> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selected = this.selected;
    final shown = [
      ...pairs,
      if (selected != null && !pairs.any((p) => p.$1 == selected))
        (selected, 0),
    ];
    return Semantics(
      key: HistoryView.favoritePairsKey,
      container: true,
      explicitChildNodes: true,
      label: l10n.historyPairFilters,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ChoiceChip(
              materialTapTargetSize: MaterialTapTargetSize.padded,
              label: Text(l10n.historyFilterAll),
              selected: selected == null,
              onSelected: (_) => onSelected(null),
            ),
            for (final (pair, _) in shown) ...[
              const SizedBox(width: 8),
              ChoiceChip(
                materialTapTargetSize: MaterialTapTargetSize.padded,
                label: Text(historyPairLabel(l10n, pair)),
                selected: selected == pair,
                onSelected: (on) => onSelected(on ? pair : null),
              ),
            ],
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
        borderRadius: AppLook.of(context).fieldRadius,
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
    final look = AppLook.of(context);
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
            border: Border.all(color: colors.outline),
            borderRadius: look.cardRadius,
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
                    style: FilledButton.styleFrom(shape: look.control),
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
