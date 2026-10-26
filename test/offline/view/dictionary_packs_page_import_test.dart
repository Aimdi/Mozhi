import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/offline/data/picked_import_file.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:mozhi/platform/free_space.dart';
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
  late MockOfflineModelFilePicker picker;

  setUp(() {
    spanish = spanishPack();
    english = englishPack();
    es = packInfo('es', spanish);
    en = packInfo('en', english, name: 'English');
    storage = MemoryDictionaryPackStorage();
    picker = stubOfflineModelFilePicker();
  });

  Future<void> pumpPage(WidgetTester tester, {FreeSpace? freeSpace}) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      DictionaryPacksPage(
        packs: DictionaryPacks(
          catalog: DictionaryPackCatalog([es, en]),
          storage: storage,
          httpClient: MockClient((_) async => http.Response('', 500)),
          freeSpace: freeSpace,
        ),
        store: MemoryStore(),
        picker: picker,
      ),
    );
    await tester.pumpAndSettle();
  }

  void picks(List<PickedImportFile> files) =>
      when(() => picker.pickContents(onCopying: any(named: 'onCopying')))
          .thenAnswer((_) async => files);

  /// Runs the import (its storage writes run outside the fake time).
  Future<void> importFiles(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('dictionary_packs_import')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('imports from files and says what it did', (tester) async {
    final damaged = Uint8List.fromList(english)..[20] ^= 0xff;
    picks([
      PickedImportFile.bytes('es.mzd', spanish),
      PickedImportFile.bytes('en.mzd', damaged),
      PickedImportFile.bytes('notes.txt', Uint8List(3)),
    ]);
    await pumpPage(tester);
    expect(find.text('Import from files'), findsOneWidget);
    expect(
      find.text(
        'Install dictionary packs (.mzd files) you downloaded by hand. '
        'Mozhi doesn’t go online for this.',
      ),
      findsOneWidget,
    );

    await importFiles(tester);

    expect(find.text('Dictionaries imported'), findsOneWidget);
    expect(find.textContaining('Installed'), findsOneWidget);
    expect(find.textContaining('Spanish'), findsWidgets);
    expect(
      find.textContaining('is damaged or of another version'),
      findsOneWidget,
    );
    expect(find.text('en.mzd'), findsOneWidget);
    expect(find.text('1 file didn’t match any dictionary'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('1 language downloaded'), findsOneWidget);
  });

  testWidgets('says when nothing was installed, or it was there', (
    tester,
  ) async {
    storage.put(storedPack(es), spanish);
    picks([PickedImportFile.bytes('es.mzd', spanish)]);
    await pumpPage(tester);

    await importFiles(tester);

    expect(find.text('Nothing was installed'), findsOneWidget);
    expect(find.textContaining('was already installed'), findsOneWidget);
  });

  testWidgets('a pack without room fails with the sizes', (tester) async {
    picks([PickedImportFile.bytes('es.mzd', spanish)]);
    await pumpPage(
      tester,
      freeSpace: FreeSpace(isWeb: true, browser: () async => 10),
    );

    await importFiles(tester);

    expect(find.text('Nothing was installed'), findsOneWidget);
    expect(find.textContaining('Not enough'), findsOneWidget);
  });

  testWidgets('a failed import says so', (tester) async {
    when(() => picker.pickContents(onCopying: any(named: 'onCopying')))
        .thenThrow(StateError('picker'));
    await pumpPage(tester);

    await importFiles(tester);

    expect(find.text('Couldn’t import the files'), findsOneWidget);
  });
}
