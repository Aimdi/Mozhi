import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:mozhi/settings/models/model_source.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../dictionary/data/dictionary_pack_fixtures.dart';
import '../../helpers/helpers.dart';
import '../../image_translate/helpers/fake_ocr.dart';
import '../helpers.dart';

/// The web app on a server that hosts the folders in [hosted] only.
MirrorHostingProbe _browserProbe({Set<String> hosted = const {}}) =>
    MirrorHostingProbe(
      client: MockClient((request) async {
        final folder = request.url.pathSegments.reversed.elementAt(1);
        return hosted.contains(folder)
            ? http.Response('{"items": ["x"]}', 200)
            : http.Response('Not Found', 404);
      }),
      isWeb: true,
      appBase: () => Uri.parse('https://translate.example.org/'),
    );

void main() {
  late ModelSource source;
  late MirrorHostingProbe probe;

  setUp(() {
    source = ModelSource.current;
    probe = MirrorHostingProbe.instance;
    ModelSource.current = const ModelSource(kind: ModelSourceKind.thisServer);
  });

  tearDown(() {
    ModelSource.current = source;
    MirrorHostingProbe.instance = probe;
  });

  void useTallView(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Iterable<OfflineLanguageTile> tiles(WidgetTester tester) =>
      tester.widgetList<OfflineLanguageTile>(find.byType(OfflineLanguageTile));

  final banner = find.byKey(const Key('mirror_not_hosted'));

  group('Dictionaries', () {
    final spanish = spanishPack();
    final es = packInfo('es', spanish);

    Future<MockOfflineModelFilePicker> pumpPage(WidgetTester tester) async {
      useTallView(tester);
      final picker = stubOfflineModelFilePicker();
      when(() => picker.pickContents(onCopying: any(named: 'onCopying')))
          .thenAnswer((_) async => const []);
      await tester.pumpApp(
        DictionaryPacksPage(
          packs: DictionaryPacks(
            catalog: DictionaryPackCatalog([es]),
            storage: MemoryDictionaryPackStorage(),
            httpClient: MockClient((_) async => http.Response('', 404)),
          ),
          store: MemoryStore(),
          picker: picker,
        ),
      );
      await tester.pumpAndSettle();
      return picker;
    }

    testWidgets('a server without them: one banner, no downloads', (
      tester,
    ) async {
      MirrorHostingProbe.instance = _browserProbe(hosted: {'phrasebooks'});
      final picker = await pumpPage(tester);
      expect(banner, findsOneWidget);
      expect(
        find.text("This web server doesn't host the downloads"),
        findsOneWidget,
      );
      expect(tiles(tester).single.canDownload, isFalse);
      final download = tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(const Key('offline_download_pill')),
          matching: find.byType(FilledButton),
        ),
      );
      expect(download.onPressed, isNull);
      await tester.tap(find.byKey(const Key('mirror_not_hosted_import')));
      await tester.pumpAndSettle();
      verify(() => picker.pickContents(onCopying: any(named: 'onCopying')))
          .called(1);
    });

    testWidgets('a server with them: downloads as before', (tester) async {
      MirrorHostingProbe.instance = _browserProbe(hosted: {'dictionary'});
      await pumpPage(tester);
      expect(banner, findsNothing);
      expect(tiles(tester).single.canDownload, isTrue);
    });

    testWidgets('each pack says the language of its definitions', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(tiles(tester).single.note, 'Definitions in English');
      expect(find.text('Definitions in English'), findsOneWidget);
    });
  });

  group('Text recognition', () {
    Future<void> pumpPage(WidgetTester tester) async {
      useTallView(tester);
      await tester.pumpApp(
        OcrLanguagesPage(
          data: FakeOcrData(installed: {'deu': 1525436}),
          store: MemoryStore(),
          picker: stubOfflineModelFilePicker(paths: const []),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a server without the data: one banner, no downloads', (
      tester,
    ) async {
      MirrorHostingProbe.instance = _browserProbe();
      await pumpPage(tester);
      expect(banner, findsOneWidget);
      expect(tiles(tester).every((tile) => !tile.canDownload), isTrue);
      // Downloaded languages can still be deleted.
      expect(find.byKey(const Key('offline_downloaded_pill')), findsOneWidget);
      expect(find.byKey(const Key('mirror_not_hosted_import')), findsOneWidget);
    });

    testWidgets('outside a browser nothing changes', (tester) async {
      MirrorHostingProbe.instance = MirrorHostingProbe(
        client: MockClient((_) async => http.Response('', 404)),
        isWeb: false,
      );
      await pumpPage(tester);
      expect(banner, findsNothing);
      expect(tiles(tester).every((tile) => tile.canDownload), isTrue);
    });
  });

  group('Offline languages', () {
    testWidgets('a server without the models: one banner, no downloads', (
      tester,
    ) async {
      MirrorHostingProbe.instance = _browserProbe(hosted: {'tesseract'});
      useTallView(tester);
      await tester.pumpApp(
        OfflineModelsPage(
          translator: stubOfflineTranslator(),
          store: MemoryStore(),
        ),
      );
      await tester.pumpAndSettle();
      expect(banner, findsOneWidget);
      expect(tiles(tester), isNotEmpty);
      expect(tiles(tester).every((tile) => !tile.canDownload), isTrue);
    });

    testWidgets('an unavailable engine keeps its own banner only', (
      tester,
    ) async {
      MirrorHostingProbe.instance = _browserProbe();
      await tester.pumpApp(
        OfflineModelsPage(
          translator: const UnavailableOfflineTranslator(),
          store: MemoryStore(),
        ),
      );
      await tester.pumpAndSettle();
      expect(banner, findsNothing);
    });
  });
}
