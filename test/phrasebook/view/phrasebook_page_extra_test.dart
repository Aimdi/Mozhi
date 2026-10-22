import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/phrasebook/view/phrasebook_page.dart';
import 'package:mozhi/phrasebook/widgets/csv_import_dialog.dart';
import 'package:mozhi/phrasebook/widgets/phrase_tile.dart';
import 'package:mozhi/phrasebook/widgets/phrasebook_settings_tile.dart';

import '../helpers.dart';
import '../pump.dart';
import '../starter_fixtures.dart';

class _MockFiles extends Mock implements DocumentFileService;

const _hello = PhraseDraft(
  text: 'Hello',
  translation: 'Olá',
  sourceCode: 'en',
  targetCode: 'pt',
);

void main() {
  late _MockFiles files;

  setUp(() {
    files = _MockFiles();
    PhrasebookFiles.files = files;
  });

  tearDown(() => PhrasebookFiles.files = const PlatformDocumentFileService());

  testWidgets('a collection without phrases shows its own languages; the '
      'empty state goes to the translator', (tester) async {
    final repository = createPhrasebook();
    await repository.createCollection(
      'Pharmacy',
      sourceCode: 'en',
      targetCode: 'de',
    );
    final router = createRouter();
    await tester.pumpPhrasebook(
      const PhrasebookPage(),
      repository: repository,
      router: router,
    );
    await tester.pumpAndSettle();
    expect(find.text('\u2068English\u2069 → \u2068German\u2069 · No phrases'), findsOneWidget);
    await tester.tap(find.text('Pharmacy'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('phrasebook_translate')));
    verify(() => router.go('/translate')).called(1);
  });

  testWidgets('import errors are said', (tester) async {
    final repository = _ImportFailingRepository();
    when(() => files.pickFile(extensions: any(named: 'extensions')))
        .thenThrow(StateError('picker'));
    final collection = await repository.createCollection('Words');
    await tester.pumpPhrasebook(
      PhrasebookPage(initialCollectionId: collection.id),
      repository: repository,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('phrasebook_empty_import')));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't read this file."), findsOneWidget);

    // Cancelled: nothing.
    when(() => files.pickFile(extensions: any(named: 'extensions')))
        .thenAnswer((_) async => null);
    await tester.tap(find.byKey(const Key('phrasebook_empty_import')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phrasebook_import_dialog')), findsNothing);

    // Saving fails; an unknown language code reads as itself.
    when(() => files.pickFile(extensions: any(named: 'extensions'))).thenAnswer(
      (_) async => PickedFile(
        name: 'w.csv',
        bytes: Uint8List.fromList('a,b\n'.codeUnits),
      ),
    );
    await tester.tap(find.byKey(const Key('phrasebook_empty_import')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('phrasebook_import_from')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('phrasebook_import_confirm')));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't save your phrasebook"), findsOneWidget);
  });

  testWidgets('a starter phrasebook sorts by page order or A to Z; a note '
      'dialog can be cancelled; Copy phrase copies the phrase', (tester) async {
    final store = MemoryStore();
    await installStarterPack(store, starterPackBytes(starterPackJson()));
    final repository = createPhrasebook(
      favorites: FakeFavorites([favoriteEntry('1')]),
      starter: StarterPhrasebooks(
        catalog: StarterPhrasebookCatalog(const <StarterPhrasebookInfo>[]),
        store: store,
      ),
    );
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    await tester.pumpPhrasebook(
      const PhrasebookPage(initialCollectionId: 'starter:pt'),
      repository: repository,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('phrasebook_sort')));
    await tester.pumpAndSettle();
    expect(find.text('Page order'), findsOneWidget);
    await tester.tap(find.text('A to Z'));
    await tester.pumpAndSettle();
    // No sections A to Z.
    expect(find.text('Basics'), findsNothing);

    final tile = find.ancestor(
      of: find.text('Hello.'),
      matching: find.byType(PhraseTile),
    );
    await tester.tap(
      find.descendant(of: tile, matching: find.byTooltip('Phrase actions')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy phrase'));
    await tester.pumpAndSettle();
    expect(copied, contains('Hello.'));

    // Favorites: a note, cancelled.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Phrase actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phrasebook_note_field')), findsNothing);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  testWidgets('the settings row opens the phrasebook', (tester) async {
    final router = createRouter();
    await tester.pumpPhrasebook(
      const Scaffold(body: PhrasebookSettingsTile()),
      router: router,
    );
    expect(find.text('Phrasebook'), findsOneWidget);
    await tester.tap(find.byType(PhrasebookSettingsTile));
    verify(() => router.push<void>('/phrasebook', extra: any(named: 'extra')))
        .called(1);
    expect(PhrasebookSettingsTile.anchor, 'phrasebook');
  });

  test('value classes compare by value', () {
    final now = DateTime(2026);
    final phrase = _hello.toPhrase('p:1', now);
    expect(
      PhraseAddition(phrase: phrase, added: true),
      PhraseAddition(phrase: phrase, added: true),
    );
    expect(
      PhraseRemoval(
        phrase: phrase,
        collectionId: 'c:1',
        index: 0,
        deleted: true,
      ),
      PhraseRemoval(
        phrase: phrase,
        collectionId: 'c:1',
        index: 0,
        deleted: true,
      ),
    );
    final collection = PhraseCollection(
      id: 'c:1',
      name: 'x',
      phraseIds: const [],
      createdAt: now,
      updatedAt: now,
    );
    expect(
      CollectionDeletion(collection: collection, index: 0, phrases: const []),
      CollectionDeletion(collection: collection, index: 0, phrases: const []),
    );
    expect(
      StarterPhrasebookCatalog(const <StarterPhrasebookInfo>[]),
      StarterPhrasebookCatalog(const <StarterPhrasebookInfo>[]),
    );
    final json = starterPackJson();
    expect(
      StarterPhrasebook.fromJson(json, installedAt: now),
      StarterPhrasebook.fromJson(json, installedAt: now),
    );
    // The default stores and ids.
    final defaults = PhrasebookRepository();
    expect(defaults.store, isA<PreferencesStore>());
    expect(
      StarterPhrasebooks(catalog: StarterPhrasebookCatalog(const [])).store,
      isA<PreferencesStore>(),
    );
  });

  test('ids are random and distinct by default', () async {
    final repository = PhrasebookRepository(
      store: MemoryStore(),
      keyStore: MemoryStore(),
    );
    final a = await repository.createCollection('A');
    final b = await repository.createCollection('B');
    expect(a.id, isNot(b.id));
    expect(a.id, startsWith('c:'));
  });
}

/// A phrasebook whose imports fail.
class _ImportFailingRepository extends PhrasebookRepository {
  new() : super(store: MemoryStore(), keyStore: MemoryStore());

  @override
  Future<int> importPhrases(String collectionId, List<PhraseDraft> drafts) =>
      Future.error(StateError('full'));
}
