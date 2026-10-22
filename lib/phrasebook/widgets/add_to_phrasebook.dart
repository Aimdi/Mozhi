import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/haptics.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/phrasebook/widgets/phrasebook_labels.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

/// The location of the phrasebook, showing the collection [collectionId]
/// when given (`/phrasebook?collection=<id>`).
String phrasebookLocation({String? collectionId}) => Uri(
  path: AppRoutes.phrasebook,
  queryParameters: collectionId == null ? null : {'collection': collectionId},
).toString();

/// The translator's result in [state] as a phrase: the text it was made
/// for (the input may have been edited since) and the translation, in the
/// detected source language when it was detected; null without a
/// translation.
PhraseDraft? translationPhraseDraft(TranslateState state) {
  final draft = PhraseDraft(
    text: (state.resultInput ?? state.input).trim(),
    translation: state.output.trim(),
    sourceCode: phraseLanguageOf(
      state.source,
      detected: state.result?.detectedSource,
    ),
    targetCode: phraseLanguageOf(state.target),
    origin: PhraseOrigin.history,
  );
  return draft.isEmpty ? null : draft;
}

/// What [showCollectionChooser] chose: an existing collection ([id]) or a
/// new one to create with [newName].
class CollectionChoice {
  const new existing(String this.id) : newName = null;

  const new create(String this.newName) : id = null;

  final String? id;
  final String? newName;
}

/// "Add to phrasebook…": asks which of the user's collections [draft]
/// goes into (the last used one first; collections that have it already
/// are ticked; "New collection" makes one, with the draft's languages),
/// adds it ([PhrasebookRepository.addPhrase], which remembers the
/// collection) and says so in a snack bar with "Open". Does nothing
/// without a [PhrasebookRepository] above [context] or for an empty
/// draft.
Future<void> showAddToPhrasebook(
  BuildContext context,
  PhraseDraft draft,
) async {
  final repository = maybePhrasebookRepository(context);
  if (repository == null || draft.isEmpty) return;
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final router = GoRouter.maybeOf(context);
  final List<PhraseCollection> collections;
  final String? lastUsed;
  final Set<String> marked;
  try {
    collections = (await repository.collections())
        .where((c) => c.isEditable)
        .toList();
    lastUsed = await repository.lastCollectionId();
    marked = await repository.collectionsWith(draft);
  } on Object {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.phrasebookSaveFailed)));
    return;
  }
  if (!context.mounted) return;
  final choice = await showCollectionChooser(
    context,
    title: l10n.phrasebookAddTitle,
    collections: collections,
    lastUsedId: lastUsed,
    marked: marked,
    header: _DraftPreview(draft: draft),
  );
  if (choice == null) return;
  final (failure, added, collection) = await _addTo(repository, draft, choice);
  if (failure) {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.phrasebookSaveFailed)));
    return;
  }
  if (collection == null) return;
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          added
              ? l10n.phrasebookAddedTo(collection.name)
              : l10n.phrasebookAlreadyIn(collection.name),
        ),
        action: router == null
            ? null
            : SnackBarAction(
                label: l10n.phrasebookOpen,
                onPressed: () => unawaited(
                  router.push<void>(
                    phrasebookLocation(collectionId: collection.id),
                  ),
                ),
              ),
      ),
    );
}

/// Adds [draft] to the collection of [choice] (creating it first): whether
/// it failed, whether the phrase was added, and the collection.
Future<(bool, bool, PhraseCollection?)> _addTo(
  PhrasebookRepository repository,
  PhraseDraft draft,
  CollectionChoice choice,
) async {
  try {
    final collection = switch (choice) {
      CollectionChoice(:final String newName) =>
        await repository.createCollection(
          newName,
          sourceCode: draft.sourceCode,
          targetCode: draft.targetCode,
        ),
      CollectionChoice(:final id) => await repository.collection(id!),
    };
    if (collection == null) return (true, false, null);
    final addition = await repository.addPhrase(draft, collection.id);
    return (false, addition.added, collection);
  } on Object {
    return (true, false, null);
  }
}

/// A bottom sheet that picks one of [collections] (the user's): the one
/// [lastUsedId] first (saying so), the others in their order, those in
/// [marked] ticked ("Has this phrase") and those in [excluded] left out,
/// below "New collection", which asks for a name. Shows [header] (e.g.
/// the phrase) under the [title]. Resolves to the choice, or null when
/// dismissed.
Future<CollectionChoice?> showCollectionChooser(
  BuildContext context, {
  required String title,
  required List<PhraseCollection> collections,
  String? lastUsedId,
  Set<String> marked = const {},
  Set<String> excluded = const {},
  Widget? header,
}) => showModalBottomSheet<CollectionChoice>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => CollectionChooserSheet(
    title: title,
    collections: collections,
    lastUsedId: lastUsedId,
    marked: marked,
    excluded: excluded,
    header: header,
  ),
);

/// The list of [showCollectionChooser].
class CollectionChooserSheet extends StatelessWidget {
  const new({
    required this.title,
    required this.collections,
    this.lastUsedId,
    this.marked = const {},
    this.excluded = const {},
    this.header,
    super.key,
  });

  final String title;
  final List<PhraseCollection> collections;
  final String? lastUsedId;
  final Set<String> marked;
  final Set<String> excluded;
  final Widget? header;

  Future<void> _create(BuildContext context) async {
    final l10n = context.l10n;
    final name = await showCollectionNameDialog(
      context,
      title: l10n.phrasebookNewCollection,
      action: l10n.phrasebookCreate,
    );
    if (name == null || !context.mounted) return;
    Navigator.of(context).pop(CollectionChoice.create(name));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final shown = collections.where((c) => !excluded.contains(c.id)).toList();
    final last = shown.where((c) => c.id == lastUsedId).firstOrNull;
    final ordered = [?last, ...shown.where((c) => c.id != lastUsedId)];
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
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          ?header,
          ListTile(
            key: const Key('phrasebook_choose_new'),
            leading: const Icon(Icons.add_rounded),
            title: Text(l10n.phrasebookNewCollection),
            onTap: () => unawaited(_create(context)),
          ),
          if (ordered.isEmpty && excluded.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Text(
                l10n.phrasebookNoOtherCollections,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: palette.secondaryText,
                ),
              ),
            ),
          for (final collection in ordered)
            ListTile(
              key: ValueKey('phrasebook_choose_${collection.id}'),
              leading: const Icon(Icons.collections_bookmark_outlined),
              title: Text(collection.name),
              subtitle: Text(
                [
                  l10n.phrasebookPhraseCount(collection.length),
                  if (collection.id == lastUsedId) l10n.phrasebookLastUsed,
                  if (marked.contains(collection.id)) l10n.phrasebookHasPhrase,
                ].join(' · '),
              ),
              trailing: marked.contains(collection.id)
                  ? Icon(Icons.check_rounded, color: theme.colorScheme.primary)
                  : null,
              onTap: () =>
                  Navigator.of(context)
                      .pop(CollectionChoice.existing(collection.id)),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// The phrase being added, under the chooser's title.
class _DraftPreview extends StatelessWidget {
  const new({required this.draft});

  final PhraseDraft draft;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            draft.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textDirection: phrasebookTextDirection(
              draft.sourceCode,
              draft.text,
            ),
            style: theme.textTheme.bodyLarge,
          ),
          Text(
            draft.translation,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textDirection: phrasebookTextDirection(
              draft.targetCode,
              draft.translation,
            ),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          const Hairline(),
        ],
      ),
    );
  }
}

/// Asks for a collection's name (pre-filled with [initial]); resolves to
/// the trimmed name, or null when cancelled. [action] names the button
/// ("Create", "Rename"), which stays disabled while the name is empty.
Future<String?> showCollectionNameDialog(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      CollectionNameDialog(title: title, action: action, initial: initial),
);

/// The dialog of [showCollectionNameDialog].
class CollectionNameDialog extends StatefulWidget {
  const new({
    required this.title,
    required this.action,
    this.initial = '',
    super.key,
  });

  final String title;
  final String action;
  final String initial;

  /// Key of the name field.
  static const fieldKey = Key('phrasebook_collection_name');

  @override
  State<CollectionNameDialog> createState() => _CollectionNameDialogState();
}

class _CollectionNameDialogState extends State<CollectionNameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: CollectionNameDialog.fieldKey,
        controller: _name,
        autofocus: true,
        maxLength: 80,
        enableIMEPersonalizedLearning: imeLearningAllowed(context),
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: l10n.phrasebookCollectionName,
          hintText: l10n.phrasebookCollectionNameHint,
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          key: const Key('phrasebook_collection_name_save'),
          onPressed: _name.text.trim().isEmpty ? null : _submit,
          child: Text(widget.action),
        ),
      ],
    );
  }
}

/// "Add to phrasebook…" as a quiet action button (the row under a
/// translation, beside the heart): opens [showAddToPhrasebook] for
/// [draft]; disabled without one (an unfinished translation). Nothing
/// without a [PhrasebookRepository] above.
class AddToPhrasebookButton extends StatelessWidget {
  const new({required this.draft, super.key});

  final PhraseDraft? draft;

  @override
  Widget build(BuildContext context) {
    if (maybePhrasebookRepository(context) == null) {
      return const SizedBox.shrink();
    }
    final draft = this.draft;
    return XActionButton(
      key: const Key('phrasebook_add_button'),
      icon: Icons.bookmark_add_outlined,
      tooltip: context.l10n.phrasebookAdd,
      onPressed: draft == null || draft.isEmpty
          ? null
          : () {
              Haptics.light(context);
              unawaited(showAddToPhrasebook(context, draft));
            },
    );
  }
}
