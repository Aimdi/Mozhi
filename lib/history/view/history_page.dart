import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/undo_snack_bar.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/history/view/widgets/clear_history_dialog.dart';
import 'package:mozhi/history/view/widgets/history_entry_tile.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
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

class _HistoryViewState extends State<HistoryView> {
  late final TextEditingController _search = TextEditingController(
    text: context.read<HistoryCubit>().state.query,
  );

  /// Entries swiped away but possibly not yet removed from the state.
  final Set<String> _dismissed = {};

  /// Tiles by entry id (see [_tile]).
  final Map<String, HistoryEntryTile> _tiles = {};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(HistoryEntry entry) {
    context.read<TranslateCubit>()
      ..setSource(entry.source)
      ..setTarget(entry.target)
      ..setInputAndTranslate(entry.text);
    context.go('/translate');
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

    return BlocListener<HistoryCubit, HistoryState>(
      listenWhen: (previous, current) => previous.entries != current.entries,
      listener: _forgetDeleted,
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
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          // Checkmarks show the selection; the app theme
                          // hides them and the fill alone is too faint
                          // (WCAG 1.4.1, 1.4.11).
                          ChoiceChip(
                            showCheckmark: true,
                            label: Text(l10n.historyFilterAll),
                            selected: !state.favoritesOnly,
                            onSelected: (_) => context
                                .read<HistoryCubit>()
                                .setFavoritesOnly(enabled: false),
                          ),
                          ChoiceChip(
                            showCheckmark: true,
                            avatar: state.favoritesOnly
                                ? null
                                : const Icon(Icons.star_outline_rounded),
                            label: Text(l10n.historyFilterFavorites),
                            selected: state.favoritesOnly,
                            onSelected: (_) => context
                                .read<HistoryCubit>()
                                .setFavoritesOnly(enabled: true),
                          ),
                        ],
                      ),
                      if (maxAge != null) _RetentionNote(days: maxAge.inDays),
                    ],
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
          child: _EmptyState(
            icon: Icons.error_outline,
            title: l10n.historyLoadFailed,
            action: TextButton(
              onPressed: () => context.read<HistoryCubit>().load(),
              child: Text(l10n.commonRetry),
            ),
          ),
        ),
      ];
    }
    if (visible.isEmpty) {
      final query = state.query.trim();
      final (icon, title, body) = !hasEntries
          ? (Icons.history, l10n.historyEmptyTitle, l10n.historyEmptyBody)
          : query.isNotEmpty
          ? (
              Icons.search_off,
              l10n.historyNoMatchesTitle,
              l10n.historyNoMatchesBody(query),
            )
          : state.favoritesOnly
          ? (
              Icons.star_outline_rounded,
              l10n.historyNoFavoritesTitle,
              l10n.historyNoFavoritesBody,
            )
          : (Icons.history, l10n.historyEmptyTitle, l10n.historyEmptyBody);
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyState(
            icon: icon,
            title: title,
            body: body,
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
    final headerStyle = Theme.of(context).textTheme.titleSmall
        ?.copyWith(color: Theme.of(context).colorScheme.primary);
    return [
      SliverPadding(
        padding: padding.copyWith(top: 8, bottom: 32),
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
              padding: EdgeInsets.fromLTRB(4, index == 0 ? 8 : 24, 4, 8),
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
    final color = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 12, 4, 0),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card.filled(
        margin: EdgeInsets.zero,
        color: colors.tertiaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.history_toggle_off,
                    color: colors.onTertiaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.historyDisabledBanner,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: colors.onTertiaryContainer,
                  ),
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

class _EmptyState extends StatelessWidget {
  const new({
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.announce = false,
  });

  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;

  /// Whether the title and body form a live region.
  final bool announce;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: colors.outline),
              const SizedBox(height: 16),
              Semantics(
                container: announce,
                liveRegion: announce,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: theme.textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (body case final body?) ...[
                      const SizedBox(height: 8),
                      Text(
                        body,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
              if (action case final action?) ...[
                const SizedBox(height: 16),
                action,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
