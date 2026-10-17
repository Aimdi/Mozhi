import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

const _english = Language(code: 'en', name: 'English');
const _french = Language(code: 'fr', name: 'French');
const _german = Language(code: 'de', name: 'German');

HistoryEntry _entry(
  String id, {
  String engineId = 'mozhi:google',
  Language source = _english,
  Language target = _french,
  String? detectedSource,
  bool isFavorite = false,
}) => HistoryEntry(
  id: id,
  text: 'text $id',
  translation: 'translation $id',
  source: source,
  target: target,
  engineId: engineId,
  engineName: engineId,
  createdAt: DateTime(2026),
  detectedSource: detectedSource,
  isFavorite: isFavorite,
);

AiProviderConfig _provider(
  String id,
  String baseUrl, {
  MtService service = MtService.llm,
}) => AiProviderConfig(
  id: id,
  name: id,
  provider: LlmProvider.openAiCompatible,
  baseUrl: baseUrl,
  model: 'm',
  service: service,
);

void main() {
  group('historyDestinationOf', () {
    final providers = [
      _provider('cloud', 'https://api.openai.com/v1'),
      _provider('ollama', 'http://localhost:11434'),
      _provider('deepl', '', service: MtService.deepl),
      _provider('deepl-proxy', 'http://10.0.0.2', service: MtService.deepl),
      _provider('libre', '', service: MtService.libreTranslate),
      _provider(
        'libre-public',
        'https://libretranslate.com',
        service: MtService.libreTranslate,
      ),
      _provider(
        'libre-home',
        'http://192.168.1.20:5000',
        service: MtService.libreTranslate,
      ),
    ];

    HistoryDestination? of(String id, {List<MozhiInstance>? instances}) =>
        historyDestinationOf(
          id,
          providers: providers,
          instances: instances ?? const [],
        );

    test('the offline engine stays on the device', () {
      expect(of(TranslationEngine.offlineId), HistoryDestination.onDevice);
      expect(of('offline:bergamot'), HistoryDestination.onDevice);
      expect(of('offline'), HistoryDestination.onDevice);
    });

    test('Mozhi engines go to the preferred instance', () {
      expect(of('mozhi:google'), HistoryDestination.publicServer);
      expect(
        of(
          'mozhi:google',
          instances: const [MozhiInstance(url: 'https://mozhi.example.com')],
        ),
        HistoryDestination.publicServer,
      );
      expect(
        of(
          'mozhi:deepl',
          instances: const [
            MozhiInstance(url: 'http://192.168.1.2:3000'),
            MozhiInstance(url: 'https://mozhi.example.com'),
          ],
        ),
        HistoryDestination.selfHosted,
      );
      expect(
        of(
          'mozhi:google',
          instances: const [MozhiInstance(url: 'http://abc.onion')],
        ),
        HistoryDestination.selfHosted,
      );
    });

    test('AI providers are cloud services unless they run locally', () {
      expect(of('ai:cloud'), HistoryDestination.cloud);
      expect(of('ai:ollama'), HistoryDestination.selfHosted);
      // A provider that was deleted since.
      expect(of('ai:gone'), HistoryDestination.cloud);
    });

    test('DeepL is a cloud service, LibreTranslate public or own', () {
      expect(of('mt:deepl'), HistoryDestination.cloud);
      expect(of('mt:deepl-proxy'), HistoryDestination.cloud);
      expect(of('mt:libre'), HistoryDestination.publicServer);
      expect(of('mt:libre-public'), HistoryDestination.publicServer);
      expect(of('mt:libre-home'), HistoryDestination.selfHosted);
      expect(of('mt:gone'), HistoryDestination.cloud);
    });

    test('other ids have no destination', () {
      expect(of(''), isNull);
      expect(of('ai:'), isNull);
      expect(of('something'), isNull);
    });
  });

  group(HistoryPair, () {
    test('uses the detected language of an automatic source', () {
      final detected = _entry('1', source: Language.auto, detectedSource: 'fr');
      expect(
        HistoryPair.of(detected),
        const HistoryPair(source: _french, target: _french),
      );
      expect(HistoryPair.of(detected).source.name, 'French');
    });

    test('keeps an undetected automatic source', () {
      final entry = _entry('1', source: Language.auto);
      expect(HistoryPair.of(entry).source, Language.auto);
      final empty = _entry('2', source: Language.auto, detectedSource: '');
      expect(HistoryPair.of(empty).source, Language.auto);
    });

    test('names unknown detected codes by their code', () {
      final entry = _entry('1', source: Language.auto, detectedSource: 'xx');
      expect(HistoryPair.of(entry).source.code, 'xx');
    });

    test('matches entries of the same languages', () {
      const pair = HistoryPair(source: _english, target: _french);
      expect(pair.matches(_entry('1')), isTrue);
      expect(
        pair.matches(_entry('2', source: Language.auto, detectedSource: 'en')),
        isTrue,
      );
      expect(pair.matches(_entry('3', target: _german)), isFalse);
    });
  });

  group('HistoryState filters', () {
    final englishFrench = _entry('1');
    final englishGerman = _entry('2', target: _german, engineId: 'ai:cloud');
    final detected = _entry(
      '3',
      source: Language.auto,
      detectedSource: 'en',
      engineId: TranslationEngine.offlineId,
      isFavorite: true,
    );
    final entries = [englishFrench, englishGerman, detected];

    test('filter by language pair', () {
      final state = HistoryState(
        entries: entries,
        pair: const HistoryPair(source: _english, target: _french),
      );
      expect(state.hasFilters, isTrue);
      expect(state.visible, [englishFrench, detected]);
    });

    test('filter by destination', () {
      final state = HistoryState(
        entries: entries,
        destination: HistoryDestination.cloud,
      );
      expect(state.visible, [englishGerman]);
      expect(state.visibleWith((_) => HistoryDestination.cloud), entries);
      expect(
        state.copyWith(destination: () => HistoryDestination.onDevice).visible,
        [detected],
      );
    });

    test('combines the filters with the favourites and the search', () {
      final state = HistoryState(
        entries: entries,
        pair: const HistoryPair(source: _english, target: _french),
        destination: HistoryDestination.onDevice,
        favoritesOnly: true,
        query: 'text',
      );
      expect(state.visible, [detected]);
      expect(state.copyWith(query: 'nothing').visible, isEmpty);
    });

    test('lists the pairs, most used first', () {
      final state = HistoryState(entries: entries);
      expect(state.pairs, [
        (const HistoryPair(source: _english, target: _french), 2),
        (const HistoryPair(source: _english, target: _german), 1),
      ]);
      expect(const HistoryState().pairs, isEmpty);
    });

    test('lists the destinations in a fixed order', () {
      final state = HistoryState(entries: entries);
      expect(state.destinationsWith(historyDestinationOf), [
        HistoryDestination.onDevice,
        HistoryDestination.publicServer,
        HistoryDestination.cloud,
      ]);
      expect(state.destinationsWith((_) => null), isEmpty);
    });

    test('copyWith sets and clears the filters', () {
      const pair = HistoryPair(source: _english, target: _french);
      final state = const HistoryState().copyWith(
        pair: () => pair,
        destination: () => HistoryDestination.cloud,
      );
      expect(
        state,
        const HistoryState(pair: pair, destination: HistoryDestination.cloud),
      );
      expect(state.copyWith(), state);
      expect(
        state.copyWith(pair: () => null, destination: () => null),
        const HistoryState(),
      );
      expect(const HistoryState().hasFilters, isFalse);
    });
  });
}
