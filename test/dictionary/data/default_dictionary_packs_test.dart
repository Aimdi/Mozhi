import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/dictionary/data/default_dictionary_packs.dart';
import 'package:mozhi/dictionary/data/dictionary_catalog_data.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  test('the bundled catalogue parses', () {
    expect(
      bundledDictionaryCatalog().packs,
      DictionaryPackCatalog.parse(dictionaryCatalogJson).packs,
    );
    expect(bundledDictionaryCatalog('not json').isEmpty, isTrue);
  });

  test('defaultDictionaryPacks is shared', () {
    final packs = defaultDictionaryPacks();
    expect(identical(packs, defaultDictionaryPacks()), isTrue);
    expect(packs.isSupported, isTrue);
  });

  testWidgets('maybeDictionaryPacks reads the provided packs', (tester) async {
    final packs = DictionaryPacks(
      catalog: DictionaryPackCatalog(const []),
      storage: MemoryDictionaryPackStorage(),
    );
    DictionaryPacks? found;
    DictionaryPacks? missing;
    await tester.pumpWidget(
      Column(
        children: [
          Builder(
            builder: (context) {
              missing = maybeDictionaryPacks(context);
              return const SizedBox();
            },
          ),
          RepositoryProvider.value(
            value: packs,
            child: Builder(
              builder: (context) {
                found = maybeDictionaryPacks(context);
                return const SizedBox();
              },
            ),
          ),
        ],
      ),
    );
    expect(found, same(packs));
    expect(missing, isNull);
  });
}
