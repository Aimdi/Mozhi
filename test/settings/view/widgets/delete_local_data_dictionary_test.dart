import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../../dictionary/data/dictionary_pack_fixtures.dart';
import '../helpers.dart';

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(const AppSettings());
  });

  late MockHistoryCubit history;
  late MockSettingsCubit settings;

  setUp(() {
    history = createHistoryCubit();
    when(history.deleteAll).thenAnswer((_) async {});
    when(() => history.search(any())).thenReturn(null);
    settings = createSettingsCubit();
  });

  test('deletes the offline dictionaries', () async {
    final spanish = spanishPack();
    final english = englishPack();
    final es = packInfo('es', spanish);
    final en = packInfo('en', english, name: 'English');
    final packs = DictionaryPacks(
      catalog: DictionaryPackCatalog([es, en]),
      storage: MemoryDictionaryPackStorage(),
      httpClient: MockClient(
        (request) async => switch (request.url.pathSegments.last) {
          'es.mzd' => http.Response.bytes(spanish, 200),
          _ => http.Response.bytes(english, 200),
        },
      ),
    );
    addTearDown(packs.close);
    await packs.install(es);
    await packs.install(en);
    expect(await packs.installed(), hasLength(2));

    await LocalDataEraser(
      history: history,
      settings: settings,
      dictionaryPacks: packs,
    ).erase();

    expect(await packs.installed(), isEmpty);
  });
}
