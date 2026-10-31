import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/settings/models/model_source.dart';

import '../../helpers/helpers.dart';

void main() {
  const english = OfflineLanguage(code: 'en', name: 'English');
  final data = OcrLanguage(
    code: 'eng',
    appCode: 'en',
    downloadSize: 4 * 1024 * 1024,
    url: Uri.parse('https://github.test/tessdata_fast/raw/eng.traineddata'),
  );
  const mirror = ModelSource(
    kind: ModelSourceKind.custom,
    customUrl: 'https://mirror.example/models/',
  );
  const mirrorLink = 'https://mirror.example/models/tesseract/eng.traineddata';

  late List<String> copied;

  setUp(() {
    copied = [];
    final previous = ClipboardService.instance;
    addTearDown(() => ClipboardService.instance = previous);
    ClipboardService.instance = ClipboardService(
      isAndroid: false,
      setData: (data) async => copied.add(data.text!),
    );
  });

  Future<void> show(WidgetTester tester, OcrManualFileSheet sheet) =>
      tester.pumpApp(Scaffold(body: sheet));

  group('OcrManualFileSheet', () {
    testWidgets('copies the publisher link without a mirror', (tester) async {
      await show(
        tester,
        OcrManualFileSheet(
          language: english,
          data: data,
          source: ModelSource.defaultHosts,
        ),
      );
      expect(find.text('Files for English'), findsOneWidget);
      expect(find.text('eng.traineddata'), findsOneWidget);
      expect(find.text('4.0 MB'), findsOneWidget);
      expect(
        find.byKey(const Key('offline_ocr_manual_publisher')),
        findsNothing,
      );

      await tester.tap(find.byTooltip('Copy link to eng.traineddata'));
      await tester.pump();
      expect(copied, ['${data.url}']);
      expect(find.byTooltip('Copied to clipboard'), findsOneWidget);
    });

    testWidgets('offers the mirror first, the publisher as a fallback', (
      tester,
    ) async {
      final sheet = OcrManualFileSheet(
        language: english,
        data: data,
        source: mirror,
      );
      expect(sheet.mirrorUrl, Uri.parse(mirrorLink));
      await show(tester, sheet);
      expect(find.textContaining('mirror.example'), findsOneWidget);

      await tester.tap(find.byTooltip('Copy link to eng.traineddata'));
      await tester.pump();
      expect(copied, [mirrorLink]);

      await tester.tap(
        find.byTooltip('Copy the publisher’s link to eng.traineddata'),
      );
      await tester.pump();
      expect(copied.last, '${data.url}');
      expect(find.byTooltip('Copy link to eng.traineddata'), findsOneWidget);
    });

    testWidgets('a file without a known link has the mirror only', (
      tester,
    ) async {
      await show(
        tester,
        const OcrManualFileSheet(
          language: english,
          data: OcrLanguage(code: 'eng', appCode: 'en', downloadSize: 1),
          source: mirror,
        ),
      );
      expect(
        find.byKey(const Key('offline_ocr_manual_publisher')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Copy link to eng.traineddata'));
      await tester.pump();
      expect(copied, [mirrorLink]);
    });

    testWidgets('without any link nothing can be copied', (tester) async {
      await show(
        tester,
        const OcrManualFileSheet(
          language: english,
          data: OcrLanguage(code: 'eng', appCode: 'en', downloadSize: 1),
          source: ModelSource.defaultHosts,
        ),
      );
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets("uses the settings' model source by default", (tester) async {
      final previous = ModelSource.current;
      addTearDown(() => ModelSource.current = previous);
      ModelSource.current = mirror;
      expect(
        OcrManualFileSheet(language: english, data: data).mirrorUrl,
        Uri.parse(mirrorLink),
      );
    });
  });
}
