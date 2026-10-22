import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/dictionary/widgets/dictionary_attribution.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../dictionary/data/dictionary_pack_fixtures.dart';
import '../../helpers/helpers.dart';
import '../helpers.dart';

void main() {
  late Uint8List spanish;
  late Uint8List english;
  late DictionaryPackInfo es;
  late DictionaryPackInfo en;
  late MemoryDictionaryPackStorage storage;
  late MemoryStore store;
  late bool metered;
  late http.Response Function() respond;

  setUp(() {
    spanish = spanishPack();
    english = englishPack();
    es = packInfo('es', spanish);
    en = packInfo('en', english, name: 'English');
    storage = MemoryDictionaryPackStorage();
    store = MemoryStore();
    metered = false;
    respond = () => http.Response.bytes(spanish, 200);
  });

  DictionaryPacks packs({
    List<DictionaryPackInfo>? catalog,
    DictionaryPackStorage? storage_,
  }) => DictionaryPacks(
    catalog: DictionaryPackCatalog(catalog ?? [es, en]),
    storage: storage_ ?? storage,
    httpClient: MockClient((_) async => respond()),
    isMeteredConnection: () async => metered,
  );

  /// Lets a download finish: the response stream's timeout runs outside
  /// the test's fake time.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpPage(
    WidgetTester tester,
    DictionaryPacks dictionaries,
  ) async {
    tester.view
      ..physicalSize = const Size(800, 2000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      DictionaryPacksPage(packs: dictionaries, store: store),
    );
    await tester.pumpAndSettle();
  }

  group('DictionaryPacksPage', () {
    testWidgets('lists the dictionaries with what is downloaded', (
      tester,
    ) async {
      storage.put(storedPack(es), spanish);
      await pumpPage(tester, packs());
      expect(find.text('Dictionaries'), findsOneWidget);
      expect(find.text('1 language downloaded'), findsOneWidget);
      expect(find.byKey(const ValueKey('dictionary-pack-es')), findsOneWidget);
      expect(find.byKey(const ValueKey('dictionary-pack-en')), findsOneWidget);
      expect(find.text('Downloaded'), findsWidgets);
      expect(find.text('Available to download'), findsOneWidget);
      expect(
        find.textContaining('Wiktionary data by its contributors'),
        findsWidgets,
      );
    });

    testWidgets('downloads a dictionary', (tester) async {
      await pumpPage(tester, packs());
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('dictionary-pack-es')),
          matching: find.byKey(const Key('offline_download_pill')),
        ),
      );
      await settle(tester);
      expect(await storage.list(), [storedPack(es)]);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('asks before a download over mobile data', (tester) async {
      metered = true;
      await pumpPage(tester, packs());
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('dictionary-pack-es')),
          matching: find.byKey(const Key('offline_download_pill')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MeteredDownloadDialog), findsOneWidget);
      await tester.tap(find.byType(FilledButton).last);
      await settle(tester);
      expect(await storage.list(), [storedPack(es)]);
    });

    testWidgets('a declined metered download does nothing', (tester) async {
      metered = true;
      await pumpPage(tester, packs());
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('dictionary-pack-es')),
          matching: find.byKey(const Key('offline_download_pill')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await storage.list(), isEmpty);
    });

    testWidgets('a failed download offers a retry', (tester) async {
      respond = () => http.Response('down', 503);
      await pumpPage(tester, packs());
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('dictionary-pack-es')),
          matching: find.byKey(const Key('offline_download_pill')),
        ),
      );
      await settle(tester);
      expect(find.text('Retry'), findsOneWidget);
      respond = () => http.Response.bytes(spanish, 200);
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(await storage.list(), [storedPack(es)]);
    });

    testWidgets('deletes a dictionary after asking', (tester) async {
      storage.put(storedPack(es), spanish);
      await pumpPage(tester, packs());
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('dictionary-pack-es')),
          matching: find.byKey(const Key('offline_downloaded_pill')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DeleteOfflineLanguageDialog), findsOneWidget);
      expect(
        find.textContaining('Words in Spanish will be looked up'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(await storage.list(), isEmpty);
    });

    testWidgets('searches', (tester) async {
      await pumpPage(tester, packs());
      await tester.enterText(find.byType(SearchBar), 'span');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dictionary-pack-en')), findsNothing);
      await tester.enterText(find.byType(SearchBar), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No languages match “zzz”'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dictionary-pack-en')), findsOneWidget);
    });

    testWidgets('no dictionaries yet', (tester) async {
      await pumpPage(tester, packs(catalog: const []));
      expect(find.byKey(const Key('dictionary_packs_empty')), findsOneWidget);
      expect(find.text('No dictionaries available yet'), findsOneWidget);
      expect(find.byType(SearchBar), findsNothing);
    });

    testWidgets('a browser without storage says so', (tester) async {
      await pumpPage(
        tester,
        packs(storage_: MemoryDictionaryPackStorage(isSupported: false)),
      );
      expect(
        find.byKey(const Key('dictionary_packs_unavailable')),
        findsOneWidget,
      );
    });

    testWidgets('shows where the data comes from', (tester) async {
      await pumpPage(tester, packs());
      await tester.tap(find.byKey(const Key('dictionary_packs_about')));
      await tester.pumpAndSettle();
      expect(find.byType(DictionaryAttributionDialog), findsOneWidget);
      expect(find.text('From Wiktionary · CC BY-SA 4.0'), findsOneWidget);
      expect(
        find.byKey(const Key('dictionary_attribution_source')),
        findsOneWidget,
      );
    });

    testWidgets('a failed load offers a retry', (tester) async {
      final broken = _BrokenStorage();
      await pumpPage(tester, packs(storage_: broken));
      expect(find.text('Retry'), findsOneWidget);
      broken.broken = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dictionary-pack-es')), findsOneWidget);
    });
  });

  group('DictionaryPacksEntry', () {
    testWidgets('opens the dictionaries from the offline languages', (
      tester,
    ) async {
      storage.put(storedPack(es), spanish);
      final dictionaries = packs();
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpApp(
        RepositoryProvider<DictionaryPacks>.value(
          value: dictionaries,
          child: OfflineModelsPage(
            translator: stubOfflineTranslator(),
            store: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('offline_dictionaries')), findsOneWidget);
      expect(
        find.text('Look up words without a network · 1 dictionary downloaded'),
        findsOneWidget,
      );
      respond = () => http.Response.bytes(english, 200);
      await tester.runAsync(() => dictionaries.install(en));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Look up words without a network · 2 dictionaries downloaded',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('offline_dictionaries')));
      await tester.pumpAndSettle();
      expect(find.byType(DictionaryPacksPage), findsOneWidget);
    });

    testWidgets("is left out without the app's dictionaries", (tester) async {
      await tester.pumpApp(
        OfflineModelsPage(translator: stubOfflineTranslator(), store: store),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('offline_dictionaries')), findsNothing);
    });

    testWidgets('a failing count shows none', (tester) async {
      await tester.pumpApp(
        Scaffold(
          body: DictionaryPacksEntry(packs: packs(storage_: _BrokenStorage())),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Look up words without a network · no dictionaries downloaded',
        ),
        findsOneWidget,
      );
    });
  });
}

class _BrokenStorage extends MemoryDictionaryPackStorage {
  bool broken = true;

  @override
  Future<List<StoredDictionaryPack>> list() async {
    if (broken) throw StateError('unreadable');
    return await super.list();
  }
}
