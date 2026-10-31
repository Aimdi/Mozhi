import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/offline.dart';

import '../helpers.dart';

/// Details of an engine with Azerbaijani (into it only) and Old Norse
/// (`non`, from it only) besides the languages that go both ways.
class _OneWayDetails extends FakeOfflineModelDetails
    implements OfflineLanguageDirections {
  new() : super(sizes: {...testDownloadSizes, 'az': 2000, 'non': 3000});

  /// The codes of every storage request.
  final storageCodes = <Set<String>>[];

  @override
  Map<String, OfflineLanguageDirection> get oneWayLanguages => const {
    'az': OfflineLanguageDirection.intoOnly,
    'non': OfflineLanguageDirection.fromOnly,
  };

  @override
  Future<OfflineStorage> storage(Iterable<String> codes) {
    storageCodes.add(codes.toSet());
    return super.storage(codes);
  }
}

OfflineLanguage _describe(String code) => OfflineLanguage(
  code: code,
  name: switch (code) {
    'az' => 'Azerbaijani',
    'de' => 'German',
    'non' => 'Old Norse',
    _ => code,
  },
);

void main() {
  late MockOfflineTranslator translator;
  late _OneWayDetails details;

  setUp(() {
    translator = stubOfflineTranslator();
    details = _OneWayDetails();
  });

  OfflineModelsCubit build() => OfflineModelsCubit(
    translator: translator,
    store: MemoryStore(),
    details: details,
    describe: _describe,
  );

  OfflineLanguage? languageOf(OfflineModelsCubit cubit, String code) {
    for (final language in cubit.state.languages) {
      if (language.code == code) return language;
    }
    return null;
  }

  group('OfflineModelsCubit with languages that go one way only', () {
    test('lists them with their direction and size', () async {
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.load();

      expect(
        languageOf(cubit, 'az')?.direction,
        OfflineLanguageDirection.intoOnly,
      );
      expect(
        languageOf(cubit, 'non')?.direction,
        OfflineLanguageDirection.fromOnly,
      );
      expect(languageOf(cubit, 'de')?.direction, OfflineLanguageDirection.both);
      expect(cubit.state.downloadSizeOf('az'), 2000);
      // The storage covers them too.
      expect(details.storageCodes.single, containsAll(['az', 'non', 'de']));
    });

    test('search finds them', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();

      cubit.search('azer');

      expect(cubit.state.visible.map((l) => l.code), ['az']);
    });

    test('downloads, counts and deletes them like the others', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();
      when(translator.downloadedLanguages)
          .thenAnswer((_) async => {'en', 'de', 'az'});

      await cubit.download('az');

      expect(details.downloads, [('az', true)]);
      expect(cubit.state.isDownloaded('az'), isTrue);
      // English is built in.
      expect(cubit.state.downloadedCount, 2);
      expect(cubit.state.outcome?.language.name, 'Azerbaijani');
      expect(cubit.state.outcome?.succeeded, isTrue);
      expect(details.storageCodes.last, contains('az'));

      when(translator.downloadedLanguages)
          .thenAnswer((_) async => {'en', 'de'});
      await cubit.delete('az');

      verify(() => translator.deleteLanguage('az')).called(1);
      expect(cubit.state.isDownloaded('az'), isFalse);
      expect(
        cubit.state.outcome?.language.direction,
        OfflineLanguageDirection.intoOnly,
      );
    });

    test('engines that do not tell list both-way languages only', () async {
      final cubit = OfflineModelsCubit(
        translator: translator,
        store: MemoryStore(),
        details: FakeOfflineModelDetails(),
        describe: _describe,
      );
      addTearDown(cubit.close);

      await cubit.load();

      expect(
        cubit.state.languages.map((l) => l.code),
        unorderedEquals(testOfflineLanguages),
      );
    });
  });

  group(OfflineLanguage, () {
    test('withDirection keeps the names', () {
      const german = OfflineLanguage(
        code: 'de',
        name: 'German',
        nativeName: 'Deutsch',
      );

      final into = german.withDirection(OfflineLanguageDirection.intoOnly);

      expect(into.code, 'de');
      expect(into.name, 'German');
      expect(into.nativeName, 'Deutsch');
      expect(into.direction, OfflineLanguageDirection.intoOnly);
      expect(into, isNot(german));
    });
  });
}
