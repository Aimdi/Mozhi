import 'package:bergamot_translator/bergamot_translator.dart'
    show MeteredConnectionException;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart'
    show TessdataDownloadException;

import '../../helpers/helpers.dart';
import '../../image_translate/helpers/fake_ocr.dart';
import '../helpers.dart';

void main() {
  late FakeOcrData data;
  late MemoryStore store;

  setUp(() {
    data = FakeOcrData(installed: {'deu': 1525436});
    store = MemoryStore();
  });

  void useTallView(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    MockOfflineModelFilePicker? picker,
  }) async {
    useTallView(tester);
    await tester.pumpApp(
      OcrLanguagesPage(
        data: data,
        store: store,
        picker: picker ?? stubOfflineModelFilePicker(paths: const []),
      ),
    );
    await tester.pumpAndSettle();
  }

  OfflineLanguageTile tile(WidgetTester tester, String name) => tester
      .widgetList<OfflineLanguageTile>(find.byType(OfflineLanguageTile))
      .firstWhere((tile) => tile.language.name == name);

  testWidgets('lists installed and available languages', (tester) async {
    await pumpPage(tester);
    expect(find.text('Text recognition'), findsOneWidget);
    expect(find.text('1 language downloaded'), findsOneWidget);
    expect(find.text('1.5 MB used on this device'), findsOneWidget);
    expect(find.textContaining('with Tesseract'), findsOneWidget);
    expect(find.textContaining('raw.githubusercontent.com'), findsOneWidget);
    final names = tester
        .widgetList<OfflineLanguageTile>(find.byType(OfflineLanguageTile))
        .map((tile) => tile.language.name)
        .toList();
    expect(names, [
      'German',
      'Chinese (Simplified)',
      'English',
      'French',
      'Japanese',
    ]);
    expect(tile(tester, 'German').downloaded, isTrue);
    expect(tile(tester, 'French').downloadSize, fraOcr.downloadSize);
  });

  testWidgets('downloads a language and says so', (tester) async {
    await pumpPage(tester);
    tile(tester, 'French').onDownload();
    await tester.pumpAndSettle();
    expect(data.downloads, [(code: 'fra', wifiOnly: true)]);
    expect(find.text('French is ready for offline use'), findsOneWidget);
    expect(find.text('2 languages downloaded'), findsOneWidget);
  });

  testWidgets('asks before a download over a metered network', (tester) async {
    data.downloadError = const MeteredConnectionException();
    await pumpPage(tester);
    tile(tester, 'French').onDownload();
    await tester.pumpAndSettle();
    expect(find.text('Download over mobile data?'), findsOneWidget);
    data.downloadError = null;
    await tester.tap(find.text('Download anyway'));
    await tester.pumpAndSettle();
    expect(data.downloads.last, (code: 'fra', wifiOnly: false));
  });

  testWidgets('a failed download offers a retry', (tester) async {
    data.downloadError = const TessdataDownloadException('fra', 'reset');
    await pumpPage(tester);
    tile(tester, 'French').onDownload();
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Couldn’t download French. Check your connection and try again.',
      ),
      findsOneWidget,
    );
    data.downloadError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(data.installed, contains('fra'));
  });

  testWidgets('deletes after asking', (tester) async {
    await pumpPage(tester);
    tile(tester, 'German').onDelete();
    await tester.pumpAndSettle();
    expect(find.text('Delete German?'), findsOneWidget);
    expect(
      find.text(
        'Text in German can’t be read on this device until you download '
        'it again.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(data.deleted, ['deu']);
    expect(find.text('German deleted'), findsOneWidget);
  });

  testWidgets('shows the file to download by hand', (tester) async {
    final copied = <String>[];
    final previous = ClipboardService.instance;
    addTearDown(() => ClipboardService.instance = previous);
    ClipboardService.instance = ClipboardService(
      isAndroid: false,
      setData: (data) async => copied.add(data.text!),
    );
    await pumpPage(tester);
    tile(tester, 'English').onShowFiles!();
    await tester.pumpAndSettle();
    expect(find.text('Files for English'), findsOneWidget);
    expect(find.text('eng.traineddata'), findsOneWidget);
    expect(find.text('4.0 MB'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy link to eng.traineddata'));
    await tester.pumpAndSettle();
    expect(copied, ['https://example.org/eng.traineddata']);
    expect(find.byTooltip('Copied to clipboard'), findsOneWidget);
  });

  testWidgets('imports files and summarises the import', (tester) async {
    data.importReport = const OcrImportReport(
      installed: ['fra'],
      alreadyInstalled: ['deu'],
      damaged: ['jpn'],
      failed: ['eng'],
      unmatchedFiles: ['a.jpg', 'b.jpg'],
    );
    await pumpPage(
      tester,
      picker: stubOfflineModelFilePicker(paths: const ['/picked/x']),
    );
    await tester.tap(find.byKey(const Key('offline_ocr_import')));
    await tester.pumpAndSettle();
    expect(find.text('Text recognition data imported'), findsOneWidget);
    for (final line in [
      'Installed French',
      'German was already installed',
      'The file for Japanese is damaged (checksum mismatch)',
      'Couldn’t install English',
      "2 files aren't text recognition data".replaceAll("'", '’'),
    ]) {
      expect(find.text(line), findsOneWidget, reason: line);
    }
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Text recognition data imported'), findsNothing);
  });

  testWidgets('says when an import installed nothing', (tester) async {
    data.importError = Exception('unreadable');
    await pumpPage(
      tester,
      picker: stubOfflineModelFilePicker(paths: const ['/picked/x']),
    );
    await tester.tap(find.byKey(const Key('offline_ocr_import')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing was installed'), findsOneWidget);
    expect(find.text('Couldn’t import the files'), findsOneWidget);
  });

  testWidgets('searches and toggles Wi-Fi only', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(SearchBar), 'jap');
    await tester.pumpAndSettle();
    expect(find.byType(OfflineLanguageTile), findsOneWidget);
    await tester.enterText(find.byType(SearchBar), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No languages match “zzz”'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(find.byType(OfflineLanguageTile), findsNWidgets(5));

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(store.values[OfflineModelsCubit.wifiOnlyKey], 'false');
  });

  testWidgets('explains a device that cannot recognise text', (tester) async {
    data.isSupported = false;
    await pumpPage(tester);
    expect(
      find.text('This device can’t run on-device text recognition'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('offline_ocr_import')), findsNothing);
  });

  testWidgets('shows a retry when loading fails', (tester) async {
    data.languagesError = Exception('no assets');
    await pumpPage(tester);
    expect(
      find.text('Couldn’t check which languages are downloaded'),
      findsOneWidget,
    );
    data.languagesError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(OfflineLanguageTile), findsNWidgets(5));
  });

  testWidgets('language rows are at least 48 dp high', (tester) async {
    // (No tap target guideline test: Material's SearchBar reports a 24 dp
    // field without a label on its outer node, as on the offline
    // languages page.)
    await pumpPage(tester);
    for (final tile in tester.widgetList<OfflineLanguageTile>(
      find.byType(OfflineLanguageTile),
    )) {
      expect(
        tester.getSize(find.byWidget(tile)).height,
        greaterThanOrEqualTo(48),
      );
    }
  });

  group('the offline languages page', () {
    testWidgets('links to text recognition when it runs here', (tester) async {
      useTallView(tester);
      await tester.pumpApp(
        OfflineModelsPage(
          translator: stubOfflineTranslator(),
          store: store,
          textRecognition: data,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Read text in photos on this device · 1 language downloaded'),
        findsOneWidget,
      );
      data.installElsewhere('fra');
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Read text in photos on this device · 2 languages downloaded',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('offline_ocr')));
      await tester.pumpAndSettle();
      expect(find.byType(OcrLanguagesPage), findsOneWidget);
      expect(find.text('2 languages downloaded'), findsWidgets);
    });

    testWidgets('hides the link where recognition cannot run', (tester) async {
      data.isSupported = false;
      useTallView(tester);
      await tester.pumpApp(
        OfflineModelsPage(
          translator: stubOfflineTranslator(),
          store: store,
          textRecognition: data,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('offline_ocr')), findsNothing);
    });

    testWidgets('keeps the count unknown when reading it fails', (
      tester,
    ) async {
      data.installedError = Exception('io');
      useTallView(tester);
      await tester.pumpApp(
        OfflineModelsPage(
          translator: stubOfflineTranslator(),
          store: store,
          textRecognition: data,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Read text in photos on this device · no languages downloaded',
        ),
        findsOneWidget,
      );
    });
  });

  test('ocrImportSummaryLines names every outcome', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      ocrImportSummaryLines(
        l10n,
        const OcrImportReport(unmatchedFiles: ['x']),
        (code) => code,
      ),
      ['1 file isn’t text recognition data'],
    );
  });
}
