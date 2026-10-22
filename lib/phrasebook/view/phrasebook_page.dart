import 'dart:async';
import 'dart:ui' show SemanticsInputType;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/undo_snack_bar.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/history/view/widgets/phrasebook_export.dart'
    show showCsvExport;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/cubit/phrasebook_cubit.dart';
import 'package:mozhi/phrasebook/data/collection_csv.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/phrasebook/widgets/add_to_phrasebook.dart';
import 'package:mozhi/phrasebook/widgets/csv_import_dialog.dart';
import 'package:mozhi/phrasebook/widgets/phrase_tile.dart';
import 'package:mozhi/phrasebook/widgets/phrasebook_labels.dart';
import 'package:mozhi/phrasebook/widgets/starter_phrasebooks_sheet.dart';
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// The phrasebook (`/phrasebook`, `?collection=<id>` to open on one): the
/// user's collections, the history favorites and the installed starter
/// phrasebooks, each with its phrases. Reads the
/// `RepositoryProvider<PhrasebookRepository>` above.
///
/// A full page above the tabs (from History's Favorites tab, More tools
/// and the settings search); opened on its own (a link) its back arrow
/// goes to the first tab.
class PhrasebookPage extends StatelessWidget {
  const new({this.initialCollectionId, super.key});

  /// The query parameter naming the collection to open.
  static const collectionParameter = 'collection';

  /// The collection to show first (null: the list of collections).
  final String? initialCollectionId;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) {
      final cubit = PhrasebookCubit(
        repository: context.read<PhrasebookRepository>(),
        initialCollectionId: initialCollectionId,
      );
      unawaited(cubit.load());
      return cubit;
    },
    child: const PhrasebookView(),
  );
}

/// The phrasebook's screens: on phones the list of collections, and a
/// collection's phrases in its place (Back returns to the list); from
/// [twoPaneBreakpoint] the list beside the selected collection.
class PhrasebookView extends StatefulWidget {
  const new({super.key});

  /// Width from which the collections and the phrases are side by side.
  static const twoPaneBreakpoint = 840.0;

  /// Width of the collections beside the phrases.
  static const listPaneWidth = 380.0;

  /// Key of "New collection" in the app bar.
  static const newCollectionKey = Key('phrasebook_new_collection');

  /// Key of the phrase search field.
  static const searchFieldKey = Key('phrasebook_search');

  /// Key of the collection's menu.
  static const collectionMenuKey = Key('phrasebook_collection_menu');

  @override
  State<PhrasebookView> createState() => _PhrasebookViewState();
}

enum _CollectionAction {
  rename,
  moveUp,
  moveDown,
  export,
  import,
  about,
  delete,
}

class _PhrasebookViewState extends State<PhrasebookView> {
  final _search = TextEditingController();

  PhrasebookRepository get _repository => context.read<PhrasebookRepository>();

  PhrasebookCubit get _cubit => context.read<PhrasebookCubit>();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _say(String message) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  /// Runs [action]; says when it fails. Returns whether it worked, with
  /// its result (the result is returned rather than assigned from a
  /// closure: see the wave's dart2js notes).
  Future<(bool, T?)> _attempt<T>(Future<T> Function() action) async {
    try {
      return (true, await action());
    } on Object {
      if (mounted) _say(context.l10n.phrasebookSaveFailed);
      return (false, null);
    }
  }

  void _select(String? id) {
    _search.clear();
    _cubit.select(id);
  }

  Future<void> _newCollection() async {
    final l10n = context.l10n;
    final name = await showCollectionNameDialog(
      context,
      title: l10n.phrasebookNewCollection,
      action: l10n.phrasebookCreate,
    );
    if (name == null || !mounted) return;
    final (ok, created) = await _attempt(
      () => _repository.createCollection(name),
    );
    if (ok && mounted) _select(created?.id);
  }

  Future<void> _rename(PhraseCollection collection) async {
    final l10n = context.l10n;
    final name = await showCollectionNameDialog(
      context,
      title: l10n.phrasebookRenameTitle,
      action: l10n.phrasebookRename,
      initial: collection.name,
    );
    if (name == null || name == collection.name || !mounted) return;
    await _attempt(() => _repository.renameCollection(collection.id, name));
  }

  Future<void> _delete(PhraseCollection collection) async {
    final l10n = context.l10n;
    if (collection.starter) {
      final (ok, _) = await _attempt(
        () => _repository.deleteCollection(collection.id),
      );
      if (ok && mounted && _cubit.state.selectedId == collection.id) {
        _select(null);
      }
      return;
    }
    final (ok, deleted) = await _attempt(
      () => _repository.deleteCollection(collection.id),
    );
    if (!ok || !mounted) return;
    if (_cubit.state.selectedId == collection.id) _select(null);
    if (deleted == null) return;
    showUndoSnackBar(
      context,
      message: l10n.phrasebookCollectionDeleted(collection.name),
      onUndo: () => unawaited(_repository.restoreCollection(deleted)),
    );
  }

  void _move(PhraseCollection collection, int by) {
    final user = _cubit.state.userCollections;
    final index = user.indexWhere((c) => c.id == collection.id);
    if (index == -1) return;
    unawaited(_cubit.reorder(index, index + by));
  }

  Future<void> _export(PhraseCollection collection) {
    final l10n = context.l10n;
    final phrases = _cubit.state.phrasesOf(collection);
    return showCsvExport(
      context,
      fileName: CollectionCsv.fileName(
        phrasebookCollectionName(l10n, collection),
      ),
      bytes: () => CollectionCsv.bytes(phrases),
      title: l10n.phrasebookExportTitle(phrases.length),
      note: l10n.phrasebookExportNote,
      saved: l10n.phrasebookExportSaved(phrases.length),
      failed: l10n.phrasebookExportFailed,
    );
  }

  Future<void> _import(PhraseCollection collection) {
    final pairs = _cubit.state.pairsOf(collection);
    final pair = pairs.firstOrNull?.$1;
    return importCsvInto(
      context,
      repository: _repository,
      collection: collection,
      sourceCode: collection.sourceCode ?? pair?.sourceCode ?? 'en',
      targetCode:
          collection.targetCode ?? pair?.targetCode ?? Phrase.unknownLanguage,
    );
  }

  Future<void> _about(PhraseCollection collection) async {
    final packId = PhraseCollection.starterPackOf(collection.id);
    final pack = packId == null
        ? null
        : await _repository.starter?.load(packId);
    if (pack == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _StarterAboutDialog(pack: pack),
    );
  }

  void _onCollectionAction(
    PhraseCollection collection,
    _CollectionAction action,
  ) => switch (action) {
    _CollectionAction.rename => unawaited(_rename(collection)),
    _CollectionAction.moveUp => _move(collection, -1),
    _CollectionAction.moveDown => _move(collection, 1),
    _CollectionAction.export => unawaited(_export(collection)),
    _CollectionAction.import => unawaited(_import(collection)),
    _CollectionAction.about => unawaited(_about(collection)),
    _CollectionAction.delete => unawaited(_delete(collection)),
  };

  // Phrases -----------------------------------------------------------------

  Future<void> _editNote(Phrase phrase) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _NoteDialog(note: phrase.note),
    );
    if (note == null || note.trim() == phrase.note || !mounted) return;
    await _attempt(() => _repository.updateNote(phrase.id, note));
  }

  /// Asks for another collection for [phrase] (making one if asked) and
  /// returns it.
  Future<PhraseCollection?> _chooseTarget(
    Phrase phrase,
    PhraseCollection from, {
    required String title,
  }) async {
    final state = _cubit.state;
    final marked = {
      for (final c in state.userCollections)
        if (c.phraseIds.contains(phrase.id) ||
            state.phrasesOf(c).any((p) => p.contentKey == phrase.contentKey))
          c.id,
    };
    final lastUsed = await _lastUsed();
    if (!mounted) return null;
    final choice = await showCollectionChooser(
      context,
      title: title,
      collections: state.userCollections,
      lastUsedId: lastUsed,
      marked: marked,
      excluded: {from.id},
    );
    if (choice == null || !mounted) return null;
    if (choice.newName case final name?) {
      final (_, created) = await _attempt(
        () => _repository.createCollection(
          name,
          sourceCode: phrase.sourceCode,
          targetCode: phrase.targetCode,
        ),
      );
      return created;
    }
    return state.userCollections.where((c) => c.id == choice.id).firstOrNull;
  }

  Future<String?> _lastUsed() async {
    try {
      return await _repository.lastCollectionId();
    } on Object {
      return null;
    }
  }

  Future<void> _copyTo(Phrase phrase, PhraseCollection from) async {
    final l10n = context.l10n;
    final target = await _chooseTarget(
      phrase,
      from,
      title: l10n.phrasebookCopyTo,
    );
    if (target == null || !mounted) return;
    final (ok, addition) = await _attempt(
      () => _repository.copyPhrase(phrase.id, target.id),
    );
    if (!ok || !mounted) return;
    _say(
      addition?.added ?? false
          ? l10n.phrasebookCopiedTo(target.name)
          : l10n.phrasebookAlreadyIn(target.name),
    );
  }

  Future<void> _moveTo(Phrase phrase, PhraseCollection from) async {
    final l10n = context.l10n;
    final target = await _chooseTarget(
      phrase,
      from,
      title: l10n.phrasebookMoveTo,
    );
    if (target == null || !mounted) return;
    final (ok, _) = await _attempt(
      () => _repository.movePhrase(phrase.id, from: from.id, to: target.id),
    );
    if (ok && mounted) _say(l10n.phrasebookMovedTo(target.name));
  }

  Future<void> _remove(Phrase phrase, PhraseCollection from) async {
    final l10n = context.l10n;
    final (ok, removed) = await _attempt(
      () => _repository.removePhrase(phrase.id, from.id),
    );
    if (!ok || removed == null || !mounted) return;
    showUndoSnackBar(
      context,
      message: from.isFavorites
          ? l10n.historyUnfavorited
          : l10n.phrasebookPhraseRemoved,
      onUndo: () => unawaited(_repository.restorePhrase(removed)),
    );
  }

  // Building -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<PhrasebookCubit>().state;
    final starter = _repository.starter;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= PhrasebookView.twoPaneBreakpoint;
        final selected = state.selected;
        final router = GoRouter.maybeOf(context);
        final routeCanPop = ModalRoute.of(context)?.canPop ?? true;
        final showsPhrases = !wide && selected != null;
        final actions = <Widget>[
          if (!showsPhrases) ...[
            IconButton(
              key: PhrasebookView.newCollectionKey,
              tooltip: l10n.phrasebookNewCollection,
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: state.status == PhrasebookStatus.ready
                  ? () => unawaited(_newCollection())
                  : null,
            ),
            if (starter != null)
              IconButton(
                key: const Key('phrasebook_starter_button'),
                tooltip: l10n.phrasebookStarterTitle,
                icon: const Icon(Icons.luggage_outlined),
                onPressed: () =>
                    unawaited(showStarterPhrasebooks(context, starter)),
              ),
          ] else
            ..._collectionActions(context, state, selected),
        ];
        final scaffold = Scaffold(
          appBar: AppBar(
            leading: showsPhrases
                ? BackButton(onPressed: () => _select(null))
                : topLevelBackButton(context),
            title: Text(
              showsPhrases
                  ? phrasebookCollectionName(l10n, selected)
                  : l10n.phrasebookTitle,
            ),
            actions: actions,
          ),
          body: switch (state.status) {
            PhrasebookStatus.loading => Center(
              child: CircularProgressIndicator(
                semanticsLabel: l10n.phrasebookTitle,
              ),
            ),
            PhrasebookStatus.unreadable => _unreadable(context),
            PhrasebookStatus.failure => _EmptyCentered(
              child: EmptyStateView(
                icon: Icons.error_outline,
                tone: EmptyStateTone.error,
                title: l10n.phrasebookLoadFailed,
                action: FilledButton.tonalIcon(
                  onPressed: () => unawaited(_cubit.load()),
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.commonRetry),
                ),
              ),
            ),
            PhrasebookStatus.ready when wide => Row(
              key: const Key('phrasebook_panes'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: PhrasebookView.listPaneWidth,
                  child: _pane(_collections(context, state, wide: true)),
                ),
                const Hairline(vertical: true),
                Expanded(
                  child: _pane(
                    selected == null
                        ? _EmptyCentered(
                            child: Text(
                              l10n.phrasebookSelectHint,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(
                                    color: AppPalette.of(context).secondaryText,
                                  ),
                            ),
                          )
                        : _phrases(context, state, selected, wide: true),
                  ),
                ),
              ],
            ),
            PhrasebookStatus.ready when selected != null => _phrases(
              context,
              state,
              selected,
              wide: false,
            ),
            PhrasebookStatus.ready => _collections(context, state, wide: false),
          },
        );
        // Back from a collection's phrases (phones) returns to the list;
        // from the list of a page opened on its own, to the first tab.
        return PopScope<Object?>(
          canPop: !showsPhrases && (routeCanPop || router == null),
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (showsPhrases) {
              _select(null);
            } else {
              router?.go(topLevelHomeLocation(context));
            }
          },
          child: scaffold,
        );
      },
    );
  }

  /// Each pane is its own focus traversal group and semantics container.
  static Widget _pane(Widget child) => Semantics(
    container: true,
    explicitChildNodes: true,
    child: FocusTraversalGroup(child: child),
  );

  Widget _unreadable(BuildContext context) {
    final l10n = context.l10n;
    return _EmptyCentered(
      child: EmptyStateView(
        icon: Icons.lock_outline,
        tone: EmptyStateTone.error,
        title: l10n.phrasebookUnreadableTitle,
        body: l10n.phrasebookUnreadableBody,
        action: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => unawaited(_cubit.load()),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.commonRetry),
            ),
            TextButton(
              key: const Key('phrasebook_start_over'),
              onPressed: () => unawaited(_confirmStartOver()),
              child: Text(l10n.phrasebookStartOver),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmStartOver() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.restart_alt),
        title: Text(l10n.phrasebookStartOverTitle),
        content: Text(l10n.phrasebookStartOverBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            key: const Key('phrasebook_start_over_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.phrasebookStartOver),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await _cubit.discardUnreadable();
  }

  /// The menu of [collection]'s actions (and its sort, when it has
  /// phrases), for the app bar or the pane's header.
  List<Widget> _collectionActions(
    BuildContext context,
    PhrasebookState state,
    PhraseCollection collection,
  ) {
    final l10n = context.l10n;
    final phrases = state.phrasesOf(collection);
    final user = state.userCollections;
    final index = user.indexWhere((c) => c.id == collection.id);
    return [
      if (phrases.length > 1)
        PopupMenuButton<PhraseSort>(
          key: const Key('phrasebook_sort'),
          tooltip: l10n.phrasebookSort,
          icon: const Icon(Icons.sort_rounded),
          initialValue: state.sort,
          onSelected: _cubit.sortBy,
          itemBuilder: (context) => [
            CheckedPopupMenuItem(
              value: PhraseSort.recent,
              checked: state.sort == PhraseSort.recent,
              child: Text(
                collection.starter
                    ? l10n.phrasebookSortPageOrder
                    : l10n.phrasebookSortRecent,
              ),
            ),
            CheckedPopupMenuItem(
              value: PhraseSort.alphabetical,
              checked: state.sort == PhraseSort.alphabetical,
              child: Text(l10n.phrasebookSortAlphabetical),
            ),
          ],
        ),
      _CollectionMenu(
        key: PhrasebookView.collectionMenuKey,
        collection: collection,
        canExport: phrases.isNotEmpty && !collection.starter,
        canMoveUp: index > 0,
        canMoveDown: index != -1 && index < user.length - 1,
        onSelected: (action) => _onCollectionAction(collection, action),
      ),
    ];
  }

  /// The list of collections: Favorites, the user's (reorderable), the
  /// starter phrasebooks and the way to get them.
  Widget _collections(
    BuildContext context,
    PhrasebookState state, {
    required bool wide,
  }) {
    final l10n = context.l10n;
    final starter = _repository.starter;
    final user = state.userCollections;
    final favorites = state.favorites;
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = wide
            ? const EdgeInsets.fromLTRB(8, 8, 8, 32)
            : centeredPadding(constraints.maxWidth, maxWidth: 760);
        Widget tile(PhraseCollection collection, {int? index}) =>
            _CollectionTile(
              key: ValueKey(collection.id),
              collection: collection,
              languages: _languagesOf(l10n, state, collection),
              selected: wide && state.selectedId == collection.id,
              index: index,
              onTap: () => _select(collection.id),
              menu: collection.isFavorites
                  ? null
                  : _CollectionMenu(
                      collection: collection,
                      canExport: false,
                      canMoveUp: index != null && index > 0,
                      canMoveDown: index != null && index < user.length - 1,
                      inList: true,
                      onSelected: (action) =>
                          _onCollectionAction(collection, action),
                    ),
            );
        return CustomScrollView(
          key: const Key('phrasebook_collections'),
          slivers: [
            SliverPadding(
              padding: padding.copyWith(bottom: 0),
              sliver: SliverList.list(
                children: [?(favorites == null ? null : tile(favorites))],
              ),
            ),
            SliverPadding(
              padding: padding.copyWith(top: 16, bottom: 0),
              sliver: SliverToBoxAdapter(
                child: _SectionHeader(title: l10n.phrasebookYourCollections),
              ),
            ),
            if (user.isEmpty)
              SliverPadding(
                padding: padding.copyWith(top: 0, bottom: 0),
                sliver: SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: EmptyStateView(
                      compact: true,
                      icon: Icons.collections_bookmark_outlined,
                      title: l10n.phrasebookEmptyCollectionsTitle,
                      body: l10n.phrasebookEmptyCollectionsBody,
                      action: FilledButton.icon(
                        key: const Key('phrasebook_empty_new_collection'),
                        onPressed: () => unawaited(_newCollection()),
                        icon: const Icon(Icons.add_rounded),
                        label: Text(l10n.phrasebookNewCollection),
                      ),
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: padding.copyWith(top: 0, bottom: 0),
                sliver: SliverReorderableList(
                  itemCount: user.length,
                  onReorderItem: (from, to) =>
                      unawaited(_cubit.reorder(from, to)),
                  itemBuilder: (context, index) =>
                      tile(user[index], index: index),
                ),
              ),
            if (starter != null) ...[
              SliverPadding(
                padding: padding.copyWith(top: 16, bottom: 0),
                sliver: SliverToBoxAdapter(
                  child: _SectionHeader(title: l10n.phrasebookStarterSection),
                ),
              ),
              SliverPadding(
                padding: padding,
                sliver: SliverList.list(
                  children: [
                    for (final collection in state.starterCollections)
                      tile(collection),
                    ListTile(
                      key: const Key('phrasebook_get_starter'),
                      leading: const Icon(Icons.luggage_outlined),
                      title: Text(l10n.phrasebookGetStarter),
                      subtitle: Text(l10n.phrasebookGetStarterSubtitle),
                      onTap: () =>
                          unawaited(showStarterPhrasebooks(context, starter)),
                    ),
                  ],
                ),
              ),
            ] else
              SliverPadding(padding: padding.copyWith(top: 0)),
          ],
        );
      },
    );
  }

  /// "English → Portuguese", "2 language pairs" or nothing, for the row of
  /// [collection].
  static String? _languagesOf(
    AppLocalizations l10n,
    PhrasebookState state,
    PhraseCollection collection,
  ) {
    final pairs = state.pairsOf(collection);
    if (pairs.length > 1) return l10n.phrasebookPairCount(pairs.length);
    if (pairs.length == 1) {
      final pair = pairs.single.$1;
      return phrasebookPairLabel(l10n, pair.sourceCode, pair.targetCode);
    }
    final source = collection.sourceCode;
    final target = collection.targetCode;
    if (source == null || target == null) return null;
    return phrasebookPairLabel(l10n, source, target);
  }

  /// [collection]'s phrases: its search, language pair chips and phrases,
  /// or a way forward when there are none.
  Widget _phrases(
    BuildContext context,
    PhrasebookState state,
    PhraseCollection collection, {
    required bool wide,
  }) {
    final l10n = context.l10n;
    final all = state.phrasesOf(collection);
    final visible = state.visible;
    final pairs = state.pairsOf(collection);
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = wide
            ? const EdgeInsets.fromLTRB(32, 8, 32, 96)
            : centeredPadding(constraints.maxWidth, maxWidth: 760);
        final rows = <Object>[];
        final byTopic = collection.starter && state.sort == PhraseSort.recent;
        String? topic;
        for (final phrase in visible) {
          if (byTopic && phrase.topic.isNotEmpty && phrase.topic != topic) {
            rows.add(topic = phrase.topic);
          }
          rows.add(phrase);
        }
        return CustomScrollView(
          key: ValueKey('phrasebook_phrases_${collection.id}'),
          slivers: [
            SliverPadding(
              padding: padding.copyWith(bottom: 0),
              sliver: SliverList.list(
                children: [
                  if (wide)
                    Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            header: true,
                            child: Text(
                              phrasebookCollectionName(l10n, collection),
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                        ..._collectionActions(context, state, collection),
                      ],
                    ),
                  if (collection.starter)
                    _StarterCredit(
                      onPressed: () => unawaited(_about(collection)),
                    ),
                  if (all.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _PhraseSearchField(
                        controller: _search,
                        onChanged: (query) {
                          setState(() {});
                          _cubit.search(query);
                        },
                        onClear: () {
                          _search.clear();
                          setState(() {});
                          _cubit.search('');
                        },
                      ),
                    ),
                  if (pairs.length > 1 || state.pair != null)
                    _PairChips(
                      pairs: pairs,
                      selected: state.pair,
                      onSelected: _cubit.filterByPair,
                    ),
                ],
              ),
            ),
            if (visible.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyCentered(
                  child: _emptyPhrases(context, state, collection, all),
                ),
              )
            else
              SliverPadding(
                padding: padding.copyWith(top: 8),
                sliver: SliverList.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) => switch (rows[index]) {
                    final Phrase phrase => PhraseTile(
                      key: ValueKey(phrase.id),
                      phrase: phrase,
                      query: state.query.trim(),
                      onEditNote: phrase.isStarter
                          ? null
                          : () => unawaited(_editNote(phrase)),
                      onCopyTo: () => unawaited(_copyTo(phrase, collection)),
                      onMoveTo: phrase.isStored && collection.isEditable
                          ? () => unawaited(_moveTo(phrase, collection))
                          : null,
                      onRemove: collection.starter
                          ? null
                          : () => unawaited(_remove(phrase, collection)),
                      removeLabel: collection.isFavorites
                          ? l10n.historyUnfavorite
                          : null,
                    ),
                    final String heading => Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        4,
                        20,
                        4,
                        0,
                      ),
                      child: Semantics(
                        header: true,
                        child: Text(
                          heading,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ),
                    _ => const SizedBox.shrink(), // coverage:ignore-line
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _emptyPhrases(
    BuildContext context,
    PhrasebookState state,
    PhraseCollection collection,
    List<Phrase> all,
  ) {
    final l10n = context.l10n;
    if (all.isNotEmpty) {
      final query = state.query.trim();
      return EmptyStateView(
        icon: Icons.search_off,
        title: l10n.historyNoMatchesTitle,
        body: query.isEmpty ? null : l10n.historyNoMatchesBody(query),
        announce: true,
        action: FilledButton.tonalIcon(
          onPressed: () {
            _search.clear();
            _cubit
              ..search('')
              ..filterByPair(null);
          },
          icon: const Icon(Icons.close),
          label: Text(l10n.historyClearSearch),
        ),
      );
    }
    final translate = FilledButton.icon(
      key: const Key('phrasebook_translate'),
      onPressed: () => context.go(AppRoutes.translate),
      icon: const Icon(Icons.translate),
      label: Text(l10n.phrasebookStartTranslating),
    );
    if (collection.isFavorites) {
      return EmptyStateView(
        icon: Icons.favorite_border_rounded,
        title: l10n.historyNoFavoritesTitle,
        body: l10n.historyNoFavoritesHeartBody,
        action: translate,
      );
    }
    return EmptyStateView(
      icon: Icons.bookmark_add_outlined,
      title: l10n.phrasebookEmptyTitle,
      body: l10n.phrasebookEmptyBody,
      action: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          translate,
          OutlinedButton.icon(
            key: const Key('phrasebook_empty_import'),
            onPressed: () => unawaited(_import(collection)),
            icon: const Icon(Icons.upload_file_outlined),
            label: Text(l10n.phrasebookImportCsv),
          ),
        ],
      ),
    );
  }
}

/// [child] centred in the space it has, scrolling when it does not fit.
class _EmptyCentered extends StatelessWidget {
  const new({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: child,
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  const new({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 4),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// A collection in the list: its icon, name, languages and number of
/// phrases; the user's have their menu and, on touch, can be dragged by
/// their handle (or long pressed) to reorder them.
class _CollectionTile extends StatelessWidget {
  const new({
    required this.collection,
    required this.languages,
    required this.selected,
    required this.onTap,
    this.menu,
    this.index,
    super.key,
  });

  final PhraseCollection collection;
  final String? languages;
  final bool selected;
  final VoidCallback onTap;
  final Widget? menu;

  /// Its index among the user's collections (they can be dragged).
  final int? index;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final index = this.index;
    final count = l10n.phrasebookPhraseCount(collection.length);
    final languages = this.languages;
    final tile = ListTile(
      selected: selected,
      leading: Icon(
        collection.isFavorites
            ? Icons.favorite_rounded
            : collection.starter
            ? Icons.luggage_outlined
            : Icons.collections_bookmark_outlined,
      ),
      title: Text(phrasebookCollectionName(l10n, collection)),
      subtitle: Text(
        [
          if (languages == null)
            count
          else
            l10n.phrasebookCollectionSubtitle(languages, count),
          if (collection.starter) l10n.phrasebookStarterCredit,
        ].join('\n'),
      ),
      isThreeLine: collection.starter,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?menu,
          if (index != null)
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: ExcludeSemantics(child: Icon(Icons.drag_handle)),
              ),
            ),
        ],
      ),
      onTap: onTap,
    );
    if (index == null) return tile;
    return ReorderableDelayedDragStartListener(index: index, child: tile);
  }
}

/// The actions on a collection: Rename, Move up and down (the list's
/// alternative to dragging), Export and Import CSV, About (a starter
/// phrasebook's credit) and Delete; what does not apply is left out.
class _CollectionMenu extends StatelessWidget {
  const new({
    required this.collection,
    required this.canExport,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onSelected,
    this.inList = false,
    super.key,
  });

  final PhraseCollection collection;
  final bool canExport;
  final bool canMoveUp;
  final bool canMoveDown;

  /// Whether it is the menu of a row in the list (with Move up and down).
  final bool inList;
  final ValueChanged<_CollectionAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    PopupMenuItem<_CollectionAction> item(
      _CollectionAction action,
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
    final editable = collection.isEditable;
    return PopupMenuButton<_CollectionAction>(
      tooltip: l10n.phrasebookCollectionActions,
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: onSelected,
      itemBuilder: (context) => [
        if (editable)
          item(
            _CollectionAction.rename,
            Icons.edit_outlined,
            l10n.phrasebookRename,
          ),
        if (editable && inList && canMoveUp)
          item(
            _CollectionAction.moveUp,
            Icons.arrow_upward,
            l10n.phrasebookMoveUp,
          ),
        if (editable && inList && canMoveDown)
          item(
            _CollectionAction.moveDown,
            Icons.arrow_downward,
            l10n.phrasebookMoveDown,
          ),
        if (canExport)
          item(
            _CollectionAction.export,
            Icons.file_download_outlined,
            l10n.phrasebookExportCsv,
          ),
        if (editable && !inList)
          item(
            _CollectionAction.import,
            Icons.upload_file_outlined,
            l10n.phrasebookImportCsv,
          ),
        if (collection.starter)
          item(
            _CollectionAction.about,
            Icons.info_outline_rounded,
            l10n.phrasebookStarterAbout,
          ),
        if (!collection.isFavorites)
          item(
            _CollectionAction.delete,
            Icons.delete_outline,
            collection.starter
                ? l10n.phrasebookDeleteStarter
                : l10n.phrasebookDeleteCollection,
          ),
      ],
    );
  }
}

/// "From Wikivoyage · CC BY-SA 4.0" above a starter phrasebook, opening
/// its credit, and that it is read-only.
class _StarterCredit extends StatelessWidget {
  const new({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          key: const Key('phrasebook_starter_credit'),
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            foregroundColor: muted,
          ),
          onPressed: onPressed,
          icon: const Icon(Icons.travel_explore_outlined, size: 16),
          label: Text(l10n.phrasebookStarterCredit),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 8),
          child: Text(
            l10n.phrasebookStarterReadOnly,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// The credit of a starter phrasebook its licence asks for: where it comes
/// from, who wrote it, the revision and the licence, with links.
class _StarterAboutDialog extends StatelessWidget {
  const new({required this.pack});

  final StarterPhrasebook pack;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    Uri? link(String url) {
      final uri = Uri.tryParse(url);
      return uri != null && uri.isScheme('https') ? uri : null;
    }

    final source = link(pack.revisionUrl) ?? link(pack.sourceUrl);
    final authors = link(pack.authorsUrl);
    final license = link(pack.licenseUrl);
    return AlertDialog(
      key: const Key('phrasebook_starter_about'),
      icon: const Icon(Icons.travel_explore_outlined),
      title: Text(l10n.phrasebookStarterAbout),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(
              l10n.dictionaryOfflineSource(pack.source, pack.license),
              style: theme.textTheme.titleSmall,
            ),
            if (pack.title.isNotEmpty)
              Text(pack.title, style: theme.textTheme.bodyMedium),
            if (pack.attribution.isNotEmpty)
              SelectableText(
                pack.attribution,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
            if (pack.revision > 0)
              Text(
                l10n.phrasebookStarterRevision(
                  '${pack.revision}',
                  pack.retrieved,
                ),
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
          ],
        ),
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        if (source != null)
          TextButton(
            onPressed: () => unawaited(LinkLauncher.open(context, source)),
            child: Text(l10n.dictionaryAttributionSource),
          ),
        if (authors != null)
          TextButton(
            onPressed: () => unawaited(LinkLauncher.open(context, authors)),
            child: Text(l10n.phrasebookStarterAuthors),
          ),
        if (license != null)
          TextButton(
            onPressed: () => unawaited(LinkLauncher.open(context, license)),
            child: Text(l10n.dictionaryAttributionLicense),
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}

/// Edits a phrase's note; pops the new note (null when cancelled).
class _NoteDialog extends StatefulWidget {
  const new({required this.note});

  final String note;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final _note = TextEditingController(text: widget.note);

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(
        widget.note.isEmpty ? l10n.phrasebookAddNote : l10n.phrasebookEditNote,
      ),
      content: TextField(
        key: const Key('phrasebook_note_field'),
        controller: _note,
        autofocus: true,
        minLines: 2,
        maxLines: 5,
        maxLength: 500,
        enableIMEPersonalizedLearning: imeLearningAllowed(context),
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: l10n.phrasebookNote,
          hintText: l10n.phrasebookNoteHint,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          key: const Key('phrasebook_note_save'),
          onPressed: () => Navigator.of(context).pop(_note.text),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}

/// The search over a collection's phrases.
class _PhraseSearchField extends StatelessWidget {
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
    return Semantics(
      inputType: SemanticsInputType.search,
      child: TextField(
        key: PhrasebookView.searchFieldKey,
        controller: controller,
        onChanged: onChanged,
        enableIMEPersonalizedLearning: imeLearningAllowed(context),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: l10n.phrasebookSearchHint,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: l10n.historyClearSearch,
                  icon: const Icon(Icons.close),
                  onPressed: onClear,
                ),
        ),
      ),
    );
  }
}

/// Chips that show one language pair of the collection (or all).
class _PairChips extends StatelessWidget {
  const new({
    required this.pairs,
    required this.selected,
    required this.onSelected,
  });

  final List<(PhrasePair, int)> pairs;
  final PhrasePair? selected;
  final ValueChanged<PhrasePair?> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selected = this.selected;
    final shown = [
      for (final (pair, _) in pairs) pair,
      if (selected != null && !pairs.any((p) => p.$1 == selected)) selected,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        key: const Key('phrasebook_pairs'),
        container: true,
        explicitChildNodes: true,
        label: l10n.historyPairFilters,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            spacing: 8,
            children: [
              ChoiceChip(
                materialTapTargetSize: MaterialTapTargetSize.padded,
                label: Text(l10n.historyFilterAll),
                selected: selected == null,
                onSelected: (_) => onSelected(null),
              ),
              for (final pair in shown)
                ChoiceChip(
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  label: Text(
                    phrasebookPairLabel(l10n, pair.sourceCode, pair.targetCode),
                  ),
                  selected: selected == pair,
                  onSelected: (on) => onSelected(on ? pair : null),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
