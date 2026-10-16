import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
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

/// On-device translation history with search, favorites and swipe to
/// delete. Reads the app-wide [HistoryCubit], [SettingsCubit] and
/// [TranslateCubit].
class HistoryPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => const HistoryView();
}

class HistoryView extends StatefulWidget {
  const new({super.key});

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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<HistoryCubit>().state;
    final saveHistory = context.select<SettingsCubit, bool>(
      (cubit) => cubit.state.saveHistory,
    );
    final maxAge = context.select<SettingsCubit, Duration?>(
      (cubit) => cubit.state.historyRetention.maxAge,
    );
    final visible =
        state.visible.where((e) => !_dismissed.contains(e.id)).toList()
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
                      if (!saveHistory) const _HistoryDisabledBanner(),
                      SearchBar(
                        controller: _search,
                        hintText: l10n.historySearchHint,
                        elevation: const WidgetStatePropertyAll(0),
                        leading: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(Icons.search),
                        ),
                        trailing: [
                          if (_search.text.isNotEmpty)
                            IconButton(
                              tooltip: l10n.historyClearSearch,
                              icon: const Icon(Icons.close),
                              onPressed: _clearSearch,
                            ),
                        ],
                        onChanged: _onSearch,
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
            // Search results change as the user types: say when there are
            // none (WCAG 4.1.3).
            announce: hasEntries && query.isNotEmpty,
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

class _HistoryDisabledBanner extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = AppPalette.of(context);
    // A flat, hairline-bordered notice with a pill action.
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
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
                  Icon(Icons.history_toggle_off, color: colors.onSurface),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.historyDisabledBanner,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton(
                  style: FilledButton.styleFrom(shape: const StadiumBorder()),
                  onPressed: () => context.read<SettingsCubit>().setSaveHistory(
                    enabled: true,
                  ),
                  child: Text(l10n.historyTurnOn),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
