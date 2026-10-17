import 'dart:async';

import 'package:bergamot_translator/bergamot_translator.dart'
    show MeteredConnectionException;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart'
    show TessdataDownloadException;
import 'package:translation_repository/translation_repository.dart';

import '../../offline/helpers.dart';
import '../helpers/fake_ocr.dart';
import '../helpers/helpers.dart';

void main() {
  late FakeOcrData data;
  late MemoryStore store;
  late List<String> copied;
  late int installed;

  setUp(() {
    data = FakeOcrData();
    store = MemoryStore();
    installed = 0;
    copied = [];
    final previous = ClipboardService.instance;
    addTearDown(() => ClipboardService.instance = previous);
    ClipboardService.instance = ClipboardService(
      isAndroid: false,
      setData: (data) async => copied.add(data.text!),
    );
  });

  Future<void> pump(
    WidgetTester tester, {
    OcrDataMissingException missing = const OcrDataMissingException(deuOcr),
    PrivacyMode privacyMode = PrivacyMode.offlineFirst,
    MockOfflineModelFilePicker? picker,
  }) async {
    final harness = ImageTranslateHarness(
      settings: AppSettings(privacyMode: privacyMode),
    );
    await harness.pump(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: OcrLanguageOffer(
            missing: missing,
            data: data,
            store: store,
            picker: picker ?? stubOfflineModelFilePicker(paths: const []),
            onInstalled: () => installed++,
          ),
        ),
      ),
    );
  }

  Finder download() => find.byKey(const Key('image_translate_ocr_download'));
  Finder import() => find.byKey(const Key('image_translate_ocr_import'));

  testWidgets('offers the download with its size, then reads', (tester) async {
    await pump(tester);
    expect(find.text('German text recognition isn’t on this device'), findsOne);
    expect(
      find.text('Download German text recognition (1.5 MB)'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('image_translate_ocr_copy_link')),
      findsNothing,
    );
    expect(data.downloads, isEmpty);

    await tester.tap(download());
    await tester.pumpAndSettle();
    expect(data.downloads, [(code: 'deu', wifiOnly: true)]);
    expect(installed, 1);
  });

  testWidgets('shows download progress', (tester) async {
    data
      ..progressSteps = const [0.42]
      ..downloadGate = Completer<void>();
    await pump(tester);
    await tester.tap(download());
    await tester.pump();
    expect(find.text('Downloading German… 42%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    data.downloadGate!.complete();
    await tester.pumpAndSettle();
    expect(installed, 1);
  });

  testWidgets('asks before downloading over a metered network', (tester) async {
    data.downloadError = const MeteredConnectionException();
    await pump(tester);
    await tester.tap(download());
    await tester.pumpAndSettle();
    expect(find.text('Download over mobile data?'), findsOneWidget);

    data.downloadError = null;
    await tester.tap(find.text('Download anyway'));
    await tester.pumpAndSettle();
    expect(data.downloads.last, (code: 'deu', wifiOnly: false));
    expect(installed, 1);
  });

  testWidgets('a declined metered download changes nothing', (tester) async {
    data.downloadError = const MeteredConnectionException();
    await pump(tester);
    await tester.tap(download());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(data.downloads, hasLength(1));
    expect(installed, 0);
  });

  testWidgets('explains download failures', (tester) async {
    data.downloadError = const TessdataDownloadException(
      'deu',
      'HTTP 503',
      statusCode: 503,
    );
    await pump(tester);
    await tester.tap(download());
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Couldn’t download German: the server answered with error 503.',
      ),
      findsOneWidget,
    );
    expect(installed, 0);
  });

  testWidgets('imports from files and explains what did not match', (
    tester,
  ) async {
    data.importReport = const OcrImportReport(unmatchedFiles: ['photo.jpg']);
    await pump(
      tester,
      picker: stubOfflineModelFilePicker(paths: const ['/picked/photo.jpg']),
    );
    await tester.tap(import());
    await tester.pumpAndSettle();
    expect(find.text('None of the files is deu.traineddata.'), findsOneWidget);

    data.importReport = const OcrImportReport(damaged: ['deu']);
    await tester.tap(import());
    await tester.pumpAndSettle();
    expect(
      find.text(
        'deu.traineddata is damaged (checksum mismatch). Download it again.',
      ),
      findsOneWidget,
    );

    data.importReport = const OcrImportReport(failed: ['deu']);
    await tester.tap(import());
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t import the files'), findsOneWidget);

    data.importReport = const OcrImportReport(installed: ['deu']);
    await tester.tap(import());
    await tester.pumpAndSettle();
    expect(installed, 1);
  });

  testWidgets('in Offline only, puts the import first', (tester) async {
    await pump(tester, privacyMode: PrivacyMode.offlineOnly);
    expect(
      find.textContaining('Offline only is on. To keep Mozhi offline'),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('Import from files'),
        matching: find.byType(FilledButton),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('Download German text recognition (1.5 MB)'),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a guess asks for the language and copies the link', (
    tester,
  ) async {
    await pump(tester, missing: OcrDataMissingException(engOcr, guessed: true));
    expect(find.text('Which language is the text in?'), findsOneWidget);
    expect(
      find.textContaining('choose the language of the text above'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('image_translate_ocr_copy_link')));
    await tester.pumpAndSettle();
    expect(copied, ['https://example.org/eng.traineddata']);
    expect(find.text('Copied to clipboard'), findsOneWidget);
  });

  testWidgets('meets tap target guidelines', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, missing: OcrDataMissingException(engOcr));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });

  group('ImageTranslateErrorView', () {
    testWidgets('shows the offer for missing recognition data', (tester) async {
      var retried = 0;
      await ImageTranslateHarness().pump(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: ImageTranslateErrorView(
              error: const OcrDataMissingException(deuOcr),
              textRecognitionData: data,
              onRetry: () => retried++,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('image_translate_ocr_offer')), findsOne);
      expect(
        find.byKey(const Key('image_translate_retry_button')),
        findsNothing,
      );
      await tester.tap(download());
      await tester.pumpAndSettle();
      expect(retried, 1);
    });

    testWidgets('explains unsupported languages', (tester) async {
      await ImageTranslateHarness().pump(
        tester,
        const Scaffold(
          body: ImageTranslateErrorView(
            error: ImageTranslateException(
              ImageTranslateErrorKind.recognitionLanguageUnsupported,
            ),
          ),
        ),
      );
      expect(
        find.textContaining('can’t read this language yet'),
        findsOneWidget,
      );
    });
  });
}
