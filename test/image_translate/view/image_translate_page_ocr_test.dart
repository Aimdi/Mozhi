import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_ocr.dart';
import '../helpers/helpers.dart';

// The page with the default build's recognizer (downloadable language
// data): a photo in a language without data shows the download offer,
// and once downloaded it is read and translated.
void main() {
  setUpAll(registerImageTranslateFallbacks);

  testWidgets('offers missing data inline, then reads the photo', (
    tester,
  ) async {
    final harness = ImageTranslateHarness(
      translate: translateState(engines: const [deepl], source: german),
      settings: const AppSettings(),
    );
    final data = FakeOcrData(text: 'Ausgang');
    harness.picker.image = pngImage;
    when(() => harness.repository.translate(any(), any())).thenAnswer(
      (_) => Stream.value(
        TranslationResult(
          engineId: deepl.id,
          engineName: deepl.name,
          text: 'Exit',
        ),
      ),
    );
    await harness.pump(
      tester,
      RepositoryProvider<KeyValueStore>.value(
        value: MemoryStore(),
        child: ImageTranslatePage(
          picker: harness.picker,
          encoder: harness.encoder,
          recognizer: data,
        ),
      ),
    );
    expect(find.text('On-device text recognition'), findsWidgets);

    await tester.tap(find.byKey(const Key('image_translate_gallery_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('image_translate_ocr_offer')), findsOneWidget);
    expect(data.downloads, isEmpty);
    await tester.ensureVisible(
      find.byKey(const Key('image_translate_ocr_download')),
    );
    await tester.tap(find.byKey(const Key('image_translate_ocr_download')));
    await tester.pumpAndSettle();

    expect(data.downloads, [(code: 'deu', wifiOnly: true)]);
    expect(data.recognized, [
      ['deu'],
    ]);
    expect(find.byKey(const Key('image_translate_ocr_offer')), findsNothing);
    expect(find.text('Exit'), findsOneWidget);
  });
}
