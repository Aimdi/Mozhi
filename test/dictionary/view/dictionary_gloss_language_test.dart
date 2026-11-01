import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/dictionary/dictionary.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';
import '../data/dictionary_pack_fixtures.dart';
import '../helpers/offline_dictionary_helpers.dart';

void main() {
  final bytes = spanishPack();

  DictionaryPacks packs(List<DictionaryPackInfo> catalog) => DictionaryPacks(
    catalog: DictionaryPackCatalog(catalog),
    storage: MemoryDictionaryPackStorage(),
  );

  group('dictionaryGlossLanguage', () {
    test("is the glossLanguage of the answer's pack", () {
      final es = packInfo('es', bytes);
      expect(dictionaryGlossLanguage(packs([es]), gatoAnswer), 'en');
      final french = DictionaryPackInfo(
        id: 'es-fr',
        language: 'es',
        name: 'Spanish',
        url: es.url,
        size: es.size,
        sha256: es.sha256,
        glossLanguage: 'fr',
      );
      expect(dictionaryGlossLanguage(packs([french]), gatoAnswer), 'fr');
    });

    test('is null without a pack or packs', () {
      expect(dictionaryGlossLanguage(null, gatoAnswer), isNull);
      expect(
        dictionaryGlossLanguage(packs([packInfo('de', bytes)]), gatoAnswer),
        isNull,
      );
    });
  });

  group(DictionaryAttributionLink, () {
    testWidgets('adds the language of the definitions', (tester) async {
      await tester.pumpApp(
        const Scaffold(
          body: DictionaryOfflineFooter(
            attribution: wiktionary,
            glossLanguage: 'en',
          ),
        ),
      );
      expect(
        find.text('From Wiktionary · CC BY-SA 4.0 · Definitions in English'),
        findsOneWidget,
      );
    });

    testWidgets('names it in the app language', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('de'),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DictionaryAttributionLink(
              attribution: wiktionary,
              glossLanguage: 'en',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Englisch'), findsOneWidget);
    });

    testWidgets('without it, only the source', (tester) async {
      await tester.pumpApp(
        const Scaffold(
          body: DictionaryAttributionLink(attribution: wiktionary),
        ),
      );
      expect(find.text('From Wiktionary · CC BY-SA 4.0'), findsOneWidget);
    });
  });
}
