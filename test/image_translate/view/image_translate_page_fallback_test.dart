import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

// The flows that keep image translation working when Mozhi's relay to
// Google Translate does not: on-device recognition as the way out of a
// failed upload, the language of the text when it cannot be detected, the
// remembered method and a photo recovered after Android ended the app.
void main() {
  setUpAll(registerImageTranslateFallbacks);

  late ImageTranslateHarness harness;
  late AppLocalizations l10n;

  setUp(() {
    harness = ImageTranslateHarness();
    l10n = lookupAppLocalizations(const Locale('en'));
    LostImageRecovery.reset();
  });

  tearDown(LostImageRecovery.reset);

  void stubImage(Future<ImageTranslationResult> Function() answer) => when(
    () => harness.repository.translateImage(
      any(),
      any(),
      mimeType: any(named: 'mimeType'),
      source: any(named: 'source'),
      target: any(named: 'target'),
      options: any(named: 'options'),
    ),
  ).thenAnswer((_) => answer());

  void stubText(Stream<TranslationResult> Function() answer) =>
      when(() => harness.repository.translate(any(), any()))
          .thenAnswer((_) => answer());

  TranslationResult translated(String text) =>
      TranslationResult(engineId: deepl.id, engineName: deepl.name, text: text);

  Future<void> pumpWithStore(WidgetTester tester, KeyValueStore store) =>
      harness.pump(
        tester,
        RepositoryProvider<KeyValueStore>.value(
          value: store,
          child: ImageTranslatePage(
            picker: harness.picker,
            encoder: harness.encoder,
            recognizer: harness.recognizer,
          ),
        ),
      );

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  bool selected(WidgetTester tester, ImageTranslateMethod method) => tester
      .widget<ChoiceChip>(
        find.byKey(Key('image_translate_method_${method.id}')),
      )
      .selected;

  group('on-device recognition', () {
    testWidgets('comes first and is recommended', (tester) async {
      harness.recognizer.isSupported = true;
      await harness.pumpPage(tester);
      expect(selected(tester, onDeviceMethod), isTrue);
      expect(
        find.text(l10n.imageTranslateMethodOnDeviceRecommended),
        findsWidgets,
      );
      final chips = [
        for (final method in [onDeviceMethod, claudeMethod, mozhiMethod])
          tester.getTopLeft(
            find.byKey(Key('image_translate_method_${method.id}')),
          ),
      ];
      // Left to right (or wrapped below).
      expect(chips[0].dx < chips[1].dx || chips[0].dy < chips[1].dy, isTrue);
      expect(chips[1].dx < chips[2].dx || chips[1].dy < chips[2].dy, isTrue);
    });

    testWidgets('takes over when Google Translate sends nothing back', (
      tester,
    ) async {
      harness.recognizer
        ..isSupported = true
        ..text = 'Hola mundo';
      harness.picker.image = jpegImage;
      stubImage(() async => const ImageTranslationResult());
      stubText(() => Stream.value(translated('Bonjour le monde')));
      await pumpWithStore(tester, MemoryStore());

      await tapVisible(
        tester,
        find.byKey(Key('image_translate_method_${mozhiMethod.id}')),
      );
      await tapVisible(
        tester,
        find.byKey(const Key('image_translate_gallery_button')),
      );
      await tapVisible(
        tester,
        find.byKey(const Key('image_translate_translate_button')),
      );
      expect(find.text(l10n.imageTranslateErrorServiceRefused), findsOne);
      expect(find.byKey(const Key('translate_error_details')), findsNothing);

      await tapVisible(
        tester,
        find.byKey(const Key('image_translate_use_on_device')),
      );
      expect(find.byKey(const Key('image_translate_error')), findsNothing);
      expect(selected(tester, onDeviceMethod), isTrue);
      expect(harness.recognizer.sources, [Language.auto]);
      expect(find.text('Bonjour le monde'), findsOneWidget);
    });

    testWidgets('is not offered when the device cannot read images', (
      tester,
    ) async {
      harness.picker.image = jpegImage;
      stubImage(() async => const ImageTranslationResult());
      await harness.pumpPage(tester);
      await tapVisible(
        tester,
        find.byKey(Key('image_translate_method_${mozhiMethod.id}')),
      );
      await tapVisible(
        tester,
        find.byKey(const Key('image_translate_gallery_button')),
      );
      await tapVisible(
        tester,
        find.byKey(const Key('image_translate_translate_button')),
      );
      expect(find.text(l10n.imageTranslateErrorServiceRefused), findsOne);
      expect(
        find.byKey(const Key('image_translate_use_on_device')),
        findsNothing,
      );
    });

    testWidgets('asks for the language when it cannot be detected', (
      tester,
    ) async {
      harness.recognizer
        ..isSupported = true
        ..text = 'Ja';
      harness.picker.image = jpegImage;
      stubText(() => Stream.error(const SourceLanguageRequiredException()));
      await harness.pumpPage(tester);
      await tapVisible(
        tester,
        find.byKey(const Key('image_translate_gallery_button')),
      );
      expect(
        find.text(l10n.translateErrorSourceLanguageRequired),
        findsOneWidget,
      );

      stubText(() => Stream.value(translated('Oui')));
      await tapVisible(
        tester,
        find.byKey(const Key('image_translate_choose_source')),
      );
      await tester.tap(find.byKey(const Key('image_language_de')));
      await tester.pumpAndSettle();
      expect(harness.recognizer.sources, [Language.auto, german]);
      expect(find.text('Oui'), findsOneWidget);
    });
  });

  group('remembered method', () {
    testWidgets('is selected again', (tester) async {
      await pumpWithStore(
        tester,
        MemoryStore({ImageTranslateCubit.methodKey: mozhiMethod.id}),
      );
      await tester.pumpAndSettle();
      expect(selected(tester, mozhiMethod), isTrue);
    });

    testWidgets('is the one the user picked', (tester) async {
      final store = MemoryStore();
      await pumpWithStore(tester, store);
      await tapVisible(
        tester,
        find.byKey(Key('image_translate_method_${mozhiMethod.id}')),
      );
      expect(store.values[ImageTranslateCubit.methodKey], mozhiMethod.id);
    });
  });

  group('photo recovered after Android ended the app', () {
    testWidgets('from start-up is shown right away', (tester) async {
      await LostImageRecovery.recover(
        picker: FakeImagePickerService()..lost = jpegImage,
      );
      await harness.pumpPage(tester, initialSource: ImagePickSource.camera);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('image_translate_viewer')), findsOneWidget);
      // Uploading methods still wait for Translate.
      expect(
        find.byKey(const Key('image_translate_translate_button')),
        findsOneWidget,
      );
      // The camera is not opened again, and the photo is used once.
      expect(harness.picker.picks, isEmpty);
      expect(LostImageRecovery.take(), isNull);
    });

    testWidgets('from start-up keeps the remembered method', (tester) async {
      await LostImageRecovery.recover(
        picker: FakeImagePickerService()..lost = jpegImage,
      );
      await pumpWithStore(
        tester,
        MemoryStore({ImageTranslateCubit.methodKey: mozhiMethod.id}),
      );
      await tester.pumpAndSettle();
      expect(selected(tester, mozhiMethod), isTrue);
      expect(find.byKey(const Key('image_translate_viewer')), findsOneWidget);
    });

    testWidgets("from the picker's lost data when the page opens", (
      tester,
    ) async {
      harness.picker.lost = jpegImage;
      await harness.pumpPage(tester);
      await tester.pumpAndSettle();
      expect(harness.picker.lostRetrievals, 1);
      expect(find.byKey(const Key('image_translate_viewer')), findsOneWidget);
    });

    testWidgets('a requested picker opens instead', (tester) async {
      harness.picker.image = pngImage;
      await harness.pumpPage(tester, initialSource: ImagePickSource.gallery);
      await tester.pumpAndSettle();
      expect(harness.picker.picks, [ImagePickSource.gallery]);
      expect(harness.picker.lostRetrievals, 0);
    });
  });
}
