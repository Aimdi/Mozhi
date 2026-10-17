import 'dart:async';
import 'dart:ui' show SemanticsInputType;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/bidi.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/undo_snack_bar.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
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

/// On-device translation history with search, favorites, filters by
/// language pair and by where the text went, and swipe to delete. Reads
/// the app-wide [HistoryCubit], [SettingsCubit] and [TranslateCubit].
class HistoryPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => const HistoryView();
}

class HistoryView extends StatefulWidget {
  const new({super.key});

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

  /// Entries swiped away but possibly not yet removed from the state.
  final Set<String> _dismissed = {};

  /// Tiles by entry id (see [_tile]).
  final Map<String, HistoryEntryTile> _tiles = {};

  /// The All / Favorites tabs, kept in step with the cubit's filter.
  late final TabController _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: context.read<HistoryCubit>().state.favoritesOnly ? 1 : 0,
  );

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  void _open(HistoryEntry entry) {
    context.read<TranslateCubit>()
      ..setSource(entry.source)
      ..setTarget(entry.target)
      ..setInputAndTranslate(entry.text);
    context.go(AppRoutes.translate);
  }

  void _delete(HistoryEntry entry) {
    final l10n = context.l10n;
    final cubit = context.read<HistoryCubit>();
    setState(() => _dismissed.add(entry.id));
    unawaited(cubit.delete(entry.id));
    showUndoSnackBar(
      context,
      message: l10n.historyDeleted,
      onUndo: () {
        unawaited(cubit.restore(entry));
        if (mounted) setState(() => _dismissed.remove(entry.id));
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
      builder: (_) => _PairSheet(pairs: state.pairs, selected: state.pair),
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
    final visible =
        state
            .visibleWith(destinationOf)
            .where((e) => !_dismissed.contains(e.id))
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final hasEntries = state.entries.any((e) => !_dismissed.contains(e.id));

    final cubit = context.read<HistoryCubit>();
    return MultiBlocListener(
      listeners: [
        BlocListener<HistoryCubit, HistoryState>(
          listenWhen: (previous, current) =>
              previous.entries != current.entries,
          listener: _forgetDeleted,
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

  /// Once the cubit no longer has a swiped entry, stop hiding its id so a
  /// later re-import shows it again.
  void _forgetDeleted(BuildContext context, HistoryState state) {
    final ids = {for (final entry in state.entries) entry.id};
    _dismissed.removeWhere((id) => !ids.contains(id));
    _tiles.removeWhere((id, _) => !ids.contains(id));
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
        SliverFillRemaining(
          hasScrollBody: false,
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
        SliverFillRemaining(
          hasScrollBody: false,
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
              Icons.star_outline_rounded,
              l10n.historyNoFavoritesTitle,
              l10n.historyNoFavoritesBody,
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
        SliverFillRemaining(
          hasScrollBody: false,
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
    final headerStyle = theme.textTheme.labelLarge?.copyWith(
      color: AppPalette.of(context).secondaryText,
      fontWeight: FontWeight.w700,
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
            final HistoryEntry entry => _tile(entry),
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

  /// The tile for [entry], reused while the entry is unchanged so that a
  /// state change (a favorite toggled, an entry added, a search) only
  /// rebuilds the tiles whose entries changed.
  HistoryEntryTile _tile(HistoryEntry entry) {
    final cached = _tiles[entry.id];
    if (cached != null && cached.entry == entry) return cached;
    return _tiles[entry.id] = HistoryEntryTile(
      key: ValueKey(entry.id),
      entry: entry,
      onTap: () => _open(entry),
      onToggleFavorite: () =>
          context.read<HistoryCubit>().toggleFavorite(entry.id),
      onDelete: () => _delete(entry),
    );
  }

  static DateTime _day(DateTime time) {
    final local = time.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  static String _dayLabel(AppLocalizations l10n, DateTime day) {
    final today = _day(DateTime.now());
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
            if (showPairs)
              FilterChip(
                key: HistoryView.pairFilterKey,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                selected: pair != null,
                showCheckmark: false,
                avatar: const Icon(Icons.translate, size: 18),
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
                onSelected: (_) => onPickPair(),
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
  const new({required this.pairs, required this.selected});

  final List<(HistoryPair, int)> pairs;
  final HistoryPair? selected;

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
              subtitle: Text(l10n.historyFilterPairCount(count)),
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

/// The history search field: a pill like [SearchBar], with keyboard
/// learning off while incognito ([imeLearningAllowed]), which [SearchBar]
/// cannot do.
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
    return Material(
      color: colors.surfaceContainerHigh,
      shape: const StadiumBorder(),
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
            borderRadius: BorderRadius.circular(16),
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
