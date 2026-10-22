import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../dictionary/data/dictionary_pack_fixtures.dart';
import '../../helpers/helpers.dart';
import '../helpers/helpers.dart';
import 'output_stubs.dart';

/// "gato" into English without definitions (DeepL has none).
const _gato = TranslationResult(
  engineId: 'mozhi:google',
  engineName: 'Google',
  text: 'cat',
  detectedSource: 'es',
);

void main() {
  setUpAll(registerOutputFallbacks);

  late MemoryDictionaryPackStorage storage;
  late DictionaryPacks packs;
  late DictionaryPackInfo es;

  setUp(() {
    final bytes = spanishPack();
    es = packInfo('es', bytes);
    storage = MemoryDictionaryPackStorage()..put(storedPack(es), bytes);
    packs = DictionaryPacks(
      catalog: DictionaryPackCatalog([es]),
      storage: storage,
    );
  });

  Future<TranslateHarness> pump(
    WidgetTester tester, {
    String input = 'gato',
    TranslationResult result = _gato,
  }) async {
    final state = translatedState(engine: google, input: input, result: result);
    final harness = TranslateHarness(state: state);
    stubOutputExtras(harness);
    await harness.pump(
      tester,
      child: RepositoryProvider<DictionaryPacks>.value(
        value: packs,
        child: ShortQueryPanel(state: state),
      ),
    );
    await tester.pump();
    return harness;
  }

  group('ShortQueryPanel with offline dictionaries', () {
    testWidgets('shows their definitions when the engine has none', (
      tester,
    ) async {
      await pump(tester);
      expect(
        find.byKey(const Key('translate_short_offline_definitions')),
        findsOneWidget,
      );
      expect(find.text('Definitions'), findsOneWidget);
      expect(find.textContaining('cat', findRichText: true), findsWidgets);
      expect(find.text('El gato duerme.'), findsOneWidget);
      expect(find.text('From Wiktionary · CC BY-SA 4.0'), findsOneWidget);
    });

    testWidgets("an inflected form shows its lemma's senses", (tester) async {
      await pump(tester, input: 'gatos');
      expect(
        find.byKey(const ValueKey('translate_short_offline_sense:0')),
        findsOneWidget,
      );
    });

    testWidgets('nothing for a word the dictionaries lack', (tester) async {
      await pump(tester, input: 'perro');
      expect(find.text('Definitions'), findsNothing);
      expect(find.text('From Wiktionary · CC BY-SA 4.0'), findsNothing);
    });

    testWidgets("the engine's definitions come first", (tester) async {
      await pump(
        tester,
        result: const TranslationResult(
          engineId: 'mozhi:google',
          engineName: 'Google',
          text: 'cat',
          detectedSource: 'es',
          wordChoices: [WordChoice(word: 'gato', definition: 'a feline')],
        ),
      );
      expect(
        find.byKey(const Key('translate_short_offline_definitions')),
        findsNothing,
      );
      expect(find.text('a feline'), findsOneWidget);
    });

    testWidgets('looks up again when a dictionary is installed', (
      tester,
    ) async {
      await storage.delete('es');
      await pump(tester);
      expect(find.text('El gato duerme.'), findsNothing);
      storage.put(storedPack(es), spanishPack());
      // Any change of the dictionaries (here: deleting one that is not
      // there) makes the panel look the word up again.
      await packs.delete('xx');
      await tester.pump();
      await tester.pump();
      expect(find.text('El gato duerme.'), findsOneWidget);
    });
  });

  group('OfflineDefinitions', () {
    testWidgets('looks up again for a new word and survives failures', (
      tester,
    ) async {
      Widget panel(String word, DictionaryPacks dictionary) => Scaffold(
        body: OfflineDefinitions(
          dictionary: dictionary,
          word: word,
          language: 'es',
          target: 'en',
          heading: const Text('Definitions'),
        ),
      );
      await tester.pumpApp(panel('gato', packs));
      await tester.pump();
      expect(find.text('El gato duerme.'), findsOneWidget);
      await tester.pumpApp(panel('perro', packs));
      await tester.pump();
      expect(find.text('El gato duerme.'), findsNothing);
      final failing = DictionaryPacks(
        catalog: DictionaryPackCatalog(const []),
        storage: _FailingStorage(),
      );
      await tester.pumpApp(panel('gato', failing));
      await tester.pump();
      expect(find.text('Definitions'), findsNothing);
    });
  });
}

class _FailingStorage extends MemoryDictionaryPackStorage {
  @override
  Future<List<StoredDictionaryPack>> list() async =>
      throw StateError('unreadable');
}
