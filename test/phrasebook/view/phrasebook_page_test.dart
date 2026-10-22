@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/history/view/widgets/phrasebook_export.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/phrasebook/view/phrasebook_page.dart';
import 'package:mozhi/phrasebook/widgets/add_to_phrasebook.dart';
import 'package:mozhi/phrasebook/widgets/csv_import_dialog.dart';
import 'package:mozhi/phrasebook/widgets/phrase_tile.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:share_plus/share_plus.dart';

import '../helpers.dart';
import '../pump.dart';
import '../starter_fixtures.dart';

class _FakeFiles implements DocumentFileService {
  PickedFile? picked;
  final saved = <(String, Uint8List)>[];

  @override
  bool get canShareFiles => true;

  @override
  Future<bool> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    saved.add((fileName, bytes));
    return true;
  }

  @override
  Future<void> shareFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    Rect? origin,
  }) async {}

  @override
  Future<void> copyText(String text) async {}

  @override
  Future<String?> pasteText() async => null;

  @override
  Future<PickedFile?> pickFile({required List<String> extensions}) async =>
      picked;
}

class _MockRepository extends Mock implements PhrasebookRepository;

const _hello = PhraseDraft(
  text: 'Hello',
  translation: 'Olá',
  sourceCode: 'en',
  targetCode: 'pt',
);
const _thanks = PhraseDraft(
  text: 'Thank you',
  translation: 'Obrigado',
  sourceCode: 'en',
  targetCode: 'pt',
);
const _bonjour = PhraseDraft(
  text: 'Bonjour',
  translation: 'Hello',
  sourceCode: 'fr',
  targetCode: 'en',
);

/// "English → Portuguese" as the app writes pairs (bidi-isolated).
String _pair(String source, String target) =>
    '\u2068$source\u2069 → \u2068$target\u2069';

void main() {
  // Made in the test's own (fake async) zone on first use: a repository
  // made in setUp would complete its futures in the real zone, which a
  // widget test never runs while it pumps.
  FakeFavorites? currentFavorites;
  PhrasebookRepository? currentRepository;
  StarterPhrasebooks? starter;
  late _FakeFiles files;

  FakeFavorites favoritesOf() =>
      currentFavorites ??= FakeFavorites([favoriteEntry('1')]);
  PhrasebookRepository repositoryOf() => currentRepository ??= createPhrasebook(
    favorites: favoritesOf(),
    starter: starter,
  );

  setUpAll(() {
    registerFallbackValue(Uri());
    registerFallbackValue(ShareParams(text: ''));
  });

  setUp(() {
    currentFavorites = null;
    currentRepository = null;
    starter = null;
    files = _FakeFiles();
    PhrasebookExport.files = files;
    PhrasebookFiles.files = files;
  });

  tearDown(() {
    PhrasebookExport.files = const PlatformDocumentFileService();
    PhrasebookFiles.files = const PlatformDocumentFileService();
  });

  Future<void> pump(
    WidgetTester tester, {
    String? collection,
    Size size = const Size(420, 900),
    PhrasebookRepository? phrasebook,
    MockGoRouter? router,
  }) async {
    await tester.pumpPhrasebook(
      PhrasebookPage(initialCollectionId: collection),
      repository: phrasebook ?? repositoryOf(),
      size: size,
      router: router,
    );
    await tester.pumpAndSettle();
  }

  Future<PhraseCollection> lisbon() async {
    final collection = await repositoryOf().createCollection('Lisbon');
    await repositoryOf().addPhrase(_hello, collection.id);
    await repositoryOf().addPhrase(_thanks, collection.id);
    await repositoryOf().addPhrase(_bonjour, collection.id);
    return collection;
  }

  group('collections', () {
    testWidgets('lists Favorites and says how to make collections', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Phrasebook'), findsOneWidget);
      expect(find.text('Favorites'), findsOneWidget);
      expect(
        find.text('${_pair('English', 'Portuguese')} · 1 phrase'),
        findsOneWidget,
      );
      expect(find.text('Make your own phrasebooks'), findsOneWidget);
      // No starter phrasebooks without them.
      expect(find.text('Get starter phrasebooks'), findsNothing);
    });

    testWidgets('a new collection opens; Back returns to the list', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(
        find.byKey(const Key('phrasebook_empty_new_collection')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(CollectionNameDialog.fieldKey), 'Work');
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      // Its empty state, with the ways forward.
      expect(find.text('No phrases yet'), findsOneWidget);
      expect(find.byKey(const Key('phrasebook_translate')), findsOneWidget);
      expect(find.byKey(const Key('phrasebook_empty_import')), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Work'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Your collections'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);

      // The system back gesture too.
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      expect(find.text('No phrases yet'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Your collections'), findsOneWidget);
    });

    testWidgets('the app bar makes a collection too', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(PhrasebookView.newCollectionKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(CollectionNameDialog.fieldKey),
        'Pharmacy',
      );
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Pharmacy'), findsOneWidget);
      // Cancelling makes none.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PhrasebookView.newCollectionKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await repositoryOf().collections(), hasLength(2));
    });

    testWidgets('renames, moves and deletes from the row menu, with Undo', (
      tester,
    ) async {
      final a = await repositoryOf().createCollection('A');
      final b = await repositoryOf().createCollection('B');
      await repositoryOf().addPhrase(_hello, a.id);
      await pump(tester);
      // B first (the newest).
      expect(
        tester.getTopLeft(find.text('B')).dy,
        lessThan(tester.getTopLeft(find.text('A')).dy),
      );
      await tester.tap(find.byTooltip('Collection actions').first);
      await tester.pumpAndSettle();
      expect(find.text('Move up'), findsNothing);
      await tester.tap(find.text('Move down'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('A')).dy,
        lessThan(tester.getTopLeft(find.text('B')).dy),
      );
      await tester.tap(find.byTooltip('Collection actions').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move up'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('B')).dy,
        lessThan(tester.getTopLeft(find.text('A')).dy),
      );

      await tester.tap(find.byTooltip('Collection actions').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(CollectionNameDialog.fieldKey),
        'Lisboa',
      );
      await tester.pump();
      await tester.tap(find.text('Rename').last);
      await tester.pumpAndSettle();
      expect(find.text('Lisboa'), findsOneWidget);

      await tester.tap(find.byTooltip('Collection actions').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete collection'));
      await tester.pumpAndSettle();
      expect(find.text('Deleted “Lisboa”'), findsOneWidget);
      expect(find.text('Lisboa'), findsNothing);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('Lisboa'), findsOneWidget);
      expect(await repositoryOf().phrases(collectionId: a.id), hasLength(1));
      expect(b.id, isNotEmpty);
    });

    testWidgets('opened on a collection by its link', (tester) async {
      final collection = await lisbon();
      await pump(tester, collection: collection.id);
      expect(find.widgetWithText(AppBar, 'Lisbon'), findsOneWidget);
      expect(find.text('Thank you'), findsOneWidget);
    });

    testWidgets('a page opened on its own goes back to the first tab', (
      tester,
    ) async {
      final router = createRouter();
      await pump(tester, router: router);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      verify(() => router.go('/translate')).called(1);
    });
  });

  group('phrases', () {
    testWidgets('newest first, searched, filtered by pair and sorted', (
      tester,
    ) async {
      final collection = await lisbon();
      await pump(tester, collection: collection.id);
      double y(String text) => tester.getTopLeft(find.text(text).first).dy;
      // ("Hello" is also Bonjour's translation: Olá is Hello's row.)
      expect(y('Bonjour'), lessThan(y('Thank you')));
      expect(y('Thank you'), lessThan(y('Olá')));

      await tester.tap(find.byKey(const Key('phrasebook_sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A to Z'));
      await tester.pumpAndSettle();
      expect(y('Bonjour'), lessThan(y('Olá')));
      expect(y('Olá'), lessThan(y('Thank you')));

      // Two pairs: chips.
      final french = find.widgetWithText(
        ChoiceChip,
        _pair('French', 'English'),
      );
      await tester.ensureVisible(french);
      await tester.pumpAndSettle();
      await tester.tap(french);
      await tester.pumpAndSettle();
      expect(find.text('Thank you'), findsNothing);
      expect(find.text('Bonjour'), findsOneWidget);
      final all = find.widgetWithText(ChoiceChip, 'All');
      await tester.ensureVisible(all);
      await tester.pumpAndSettle();
      await tester.tap(all);
      await tester.pumpAndSettle();
      expect(find.text('Thank you'), findsOneWidget);

      await tester.enterText(
        find.byKey(PhrasebookView.searchFieldKey),
        'obrig',
      );
      await tester.pumpAndSettle();
      expect(find.text('Thank you'), findsOneWidget);
      expect(find.text('Bonjour'), findsNothing);
      await tester.enterText(find.byKey(PhrasebookView.searchFieldKey), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No matches'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Bonjour'), findsOneWidget);
      await tester.enterText(find.byKey(PhrasebookView.searchFieldKey), 'x');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Bonjour'), findsOneWidget);
    });

    testWidgets('notes, copy to and move to another collection', (
      tester,
    ) async {
      final collection = await lisbon();
      final porto = await repositoryOf().createCollection('Porto');
      await pump(tester, collection: collection.id);

      Future<void> menu(String phrase, String item) async {
        final tile = find.ancestor(
          of: find.text(phrase),
          matching: find.byType(PhraseTile),
        );
        await tester.tap(
          find.descendant(of: tile, matching: find.byTooltip('Phrase actions')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(item));
        await tester.pumpAndSettle();
      }

      await menu('Thank you', 'Add note');
      await tester.enterText(
        find.byKey(const Key('phrasebook_note_field')),
        'obrigada for women',
      );
      await tester.tap(find.byKey(const Key('phrasebook_note_save')));
      await tester.pumpAndSettle();
      expect(find.text('obrigada for women'), findsOneWidget);

      await menu('Thank you', 'Copy to collection…');
      await tester.tap(find.text('Porto'));
      await tester.pumpAndSettle();
      expect(find.text('Copied to Porto'), findsOneWidget);
      expect(
        await repositoryOf().phrases(collectionId: porto.id),
        hasLength(1),
      );
      // Again: it is there already.
      await menu('Thank you', 'Copy to collection…');
      await tester.tap(find.text('Porto'));
      await tester.pumpAndSettle();
      expect(find.text('Already in Porto'), findsOneWidget);

      await menu('Olá', 'Move to collection…');
      await tester.tap(find.byKey(const Key('phrasebook_choose_new')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(CollectionNameDialog.fieldKey), 'Faro');
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('Moved to Faro'), findsOneWidget);
      expect(find.text('Olá'), findsNothing);
      final faro = (await repositoryOf().collections()).firstWhere(
        (c) => c.name == 'Faro',
      );
      expect(faro.sourceCode, 'en');
      expect(
        (await repositoryOf().phrases(collectionId: faro.id)).single.text,
        'Hello',
      );
    });

    testWidgets('removes with Undo, shares and shows full screen', (
      tester,
    ) async {
      final shared = <ShareParams>[];
      PhrasebookShare.share = (params) async => shared.add(params);
      addTearDown(() => PhrasebookShare.share = (_) async {});
      final collection = await lisbon();
      await pump(tester, collection: collection.id);
      final tile = find.ancestor(
        of: find.text('Thank you'),
        matching: find.byType(PhraseTile),
      );
      Future<void> menu(String item) async {
        await tester.tap(
          find.descendant(of: tile, matching: find.byTooltip('Phrase actions')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(item));
        await tester.pumpAndSettle();
      }

      await menu('Share');
      expect(shared.single.text, 'Thank you\nObrigado');

      await tester.tap(
        find.descendant(of: tile, matching: find.byTooltip('Show full screen')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Obrigado'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await menu('Remove from collection');
      expect(find.text('Phrase removed'), findsOneWidget);
      expect(find.text('Thank you'), findsNothing);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('Thank you'), findsOneWidget);
    });

    testWidgets('Favorites: taken out un-stars, Undo stars again', (
      tester,
    ) async {
      await pump(tester, collection: PhraseCollection.favoritesId);
      expect(find.text('text 1'), findsOneWidget);
      await tester.tap(find.byTooltip('Phrase actions'));
      await tester.pumpAndSettle();
      // No move out of the history.
      expect(find.text('Move to collection…'), findsNothing);
      await tester.tap(find.text('Remove from favorites'));
      await tester.pumpAndSettle();
      expect(favoritesOf().removed, ['1']);
      expect(find.text('No favorites yet'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('text 1'), findsOneWidget);
    });

    testWidgets('exports a collection as CSV', (tester) async {
      final collection = await lisbon();
      await pump(tester, collection: collection.id);
      await tester.tap(find.byKey(PhrasebookView.collectionMenuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export as CSV'));
      await tester.pumpAndSettle();
      expect(find.text('Export 3 phrases'), findsOneWidget);
      await tester.tap(find.text('Save as CSV'));
      await tester.pumpAndSettle();
      expect(find.text('Saved 3 phrases'), findsOneWidget);
      final (name, bytes) = files.saved.single;
      expect(name, 'mozhi-Lisbon.csv');
      expect(utf8.decode(bytes.skip(3).toList()), contains('Hello,Olá,'));
    });

    testWidgets('imports a CSV file into the collection', (tester) async {
      final collection = await repositoryOf().createCollection('Imported');
      files.picked = PickedFile(
        name: 'words.csv',
        bytes: Uint8List.fromList(
          utf8.encode('Front,Back\nGood night,Boa noite\nBeer,Cerveja\n'),
        ),
      );
      await pump(tester, collection: collection.id);
      await tester.tap(find.byKey(const Key('phrasebook_empty_import')));
      await tester.pumpAndSettle();
      expect(find.text('words.csv · 3 rows'), findsOneWidget);
      // The header was recognised.
      expect(find.text('Good night  →  Boa noite'), findsOneWidget);
      await tester.tap(find.byKey(const Key('phrasebook_import_confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Imported 2 phrases'), findsOneWidget);
      expect(find.text('Boa noite'), findsOneWidget);
      final imported = await repositoryOf().collection(collection.id);
      // The import's languages: English → unknown (none chosen).
      expect(imported!.sourceCode, 'en');
      expect(imported.targetCode, Phrase.unknownLanguage);

      // An empty file.
      files.picked = PickedFile(name: 'empty.csv', bytes: Uint8List(0));
      await tester.tap(find.byKey(PhrasebookView.collectionMenuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import CSV'));
      await tester.pumpAndSettle();
      expect(find.text('This file has no rows to import.'), findsOneWidget);
    });
  });

  group('starter phrasebooks', () {
    late MemoryStore store;

    setUp(() async {
      store = MemoryStore();
      await installStarterPack(store, starterPackBytes(starterPackJson()));
      starter = StarterPhrasebooks(
        catalog: StarterPhrasebookCatalog(const <StarterPhrasebookInfo>[]),
        store: store,
      );
    });

    testWidgets('are read-only collections with their credit', (tester) async {
      final opened = <Uri>[];
      LinkLauncher.launcher = (uri) async {
        opened.add(uri);
        return true;
      };
      await repositoryOf().createCollection('Mine');
      await pump(tester);
      expect(find.text('Starter phrasebooks'), findsOneWidget);
      expect(find.text('Get starter phrasebooks'), findsOneWidget);
      await tester.tap(find.text('Portuguese'));
      await tester.pumpAndSettle();
      // Sections in the page's order, pronunciations shown.
      expect(find.text('Basics'), findsOneWidget);
      expect(find.text('Eating'), findsOneWidget);
      expect(find.text('oh-LAH'), findsOneWidget);
      expect(
        find.text(
          "Starter phrasebooks can't be changed: copy phrases "
          'into your own collections.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('phrasebook_starter_credit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('phrasebook_starter_about')), findsOneWidget);
      expect(find.text('Revision 1234, read on 2026-10-22'), findsOneWidget);
      await tester.tap(find.text('Authors'));
      await tester.tap(find.text('Source'));
      await tester.tap(find.text('License'));
      expect(opened.map((u) => u.host).toSet(), {
        'en.wikivoyage.org',
        'creativecommons.org',
      });
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      final tile = find.ancestor(
        of: find.text('Hello.'),
        matching: find.byType(PhraseTile),
      );
      await tester.tap(
        find.descendant(of: tile, matching: find.byTooltip('Phrase actions')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Add note'), findsNothing);
      expect(find.text('Remove from collection'), findsNothing);
      await tester.tap(find.text('Copy to collection…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();
      expect(find.text('Copied to Mine'), findsOneWidget);

      // Delete it (uninstall).
      await tester.tap(find.byKey(PhrasebookView.collectionMenuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About this phrasebook'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PhrasebookView.collectionMenuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete starter phrasebook'));
      await tester.pumpAndSettle();
      expect(find.text('Portuguese'), findsNothing);
      expect(await starter!.installed(), isEmpty);
    });

    testWidgets('the starter sheet says when none are available yet', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('phrasebook_starter_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('phrasebook_starter_empty')), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Get starter phrasebooks'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('phrasebook_starter_empty')), findsOneWidget);
    });
  });

  group('wide screens', () {
    testWidgets('show the collections beside the phrases', (tester) async {
      final collection = await lisbon();
      await pump(tester, size: const Size(1200, 900));
      expect(find.byKey(const Key('phrasebook_panes')), findsOneWidget);
      expect(
        find.text('Choose a collection to see its phrases.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Lisbon'));
      await tester.pumpAndSettle();
      // The name heads the pane; the list stays.
      expect(find.text('Lisbon'), findsNWidgets(2));
      expect(find.text('Thank you'), findsOneWidget);
      expect(find.text('Your collections'), findsOneWidget);
      await tester.tap(find.byKey(PhrasebookView.collectionMenuKey));
      await tester.pumpAndSettle();
      expect(find.text('Import CSV'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(collection.id, isNotEmpty);
    });
  });

  group('errors', () {
    testWidgets('an unreadable phrasebook can be set aside', (tester) async {
      final store = MemoryStore();
      final keys = MemoryStore();
      final original = PhrasebookRepository(store: store, keyStore: keys);
      await original.createCollection('Secret');
      keys.values.clear();
      final unreadable = PhrasebookRepository(store: store, keyStore: keys);
      await pump(tester, phrasebook: unreadable);
      expect(find.text("Your phrasebook can't be read"), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text("Your phrasebook can't be read"), findsOneWidget);
      await tester.tap(find.byKey(const Key('phrasebook_start_over')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('phrasebook_start_over')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('phrasebook_start_over_confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Make your own phrasebooks'), findsOneWidget);
      expect(
        store.values[PhrasebookRepository.unreadableStorageKey],
        isNotNull,
      );
    });

    testWidgets('a failing store offers Retry, and saving says so', (
      tester,
    ) async {
      final failing = _MockRepository();
      when(() => failing.changes).thenAnswer((_) => const Stream.empty());
      when(failing.collections).thenThrow(StateError('storage'));
      when(() => failing.starter).thenReturn(null);
      await pump(tester, phrasebook: failing);
      expect(find.text("Couldn't open your phrasebook"), findsOneWidget);

      final now = DateTime(2026);
      when(failing.collections).thenAnswer(
        (_) async => [
          PhraseCollection(
            id: PhraseCollection.favoritesId,
            name: '',
            phraseIds: const [],
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );
      when(failing.phrases).thenAnswer((_) async => const []);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Make your own phrasebooks'), findsOneWidget);

      when(() => failing.createCollection(any())).thenThrow(StateError('full'));
      await tester.tap(find.byKey(PhrasebookView.newCollectionKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(CollectionNameDialog.fieldKey), 'X');
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't save your phrasebook"), findsOneWidget);
    });
  });
}
