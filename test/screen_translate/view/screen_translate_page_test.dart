import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/screen_translate/screen_translate.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../image_translate/helpers/fake_ocr.dart';
import '../../image_translate/helpers/helpers.dart';
import '../helpers.dart';

TextParagraph _paragraph(String text, double top) =>
    TextParagraph(text: text, box: Rect.fromLTWH(20, top, 300, 60));

final _layout = TextLayout(
  width: 400,
  height: 800,
  paragraphs: [_paragraph('Ausgang', 40), _paragraph('Kasse', 400)],
);

void main() {
  setUpAll(registerImageTranslateFallbacks);

  late ImageTranslateHarness harness;
  late MockScreenTranslateHost host;
  late FakeOcrData data;
  late Completer<ScreenCapture> capture;
  late List<TranslationRequest> requests;
  late Stream<TranslationResult> Function(TranslationRequest) answer;

  setUp(() {
    harness = ImageTranslateHarness(
      translate: translateState(engines: const [deepl], source: german),
      settings: const AppSettings(),
    );
    host = mockScreenTranslateHost();
    when(host.capture).thenAnswer((_) => capture.future);
    data = FakeOcrData(installed: {'deu': 1}, text: 'Ausgang Kasse')
      ..layout = _layout;
    requests = [];
    answer = (_) => Stream.value(
      TranslationResult(
        engineId: deepl.id,
        engineName: deepl.name,
        text: 'Exit\n\nCash desk',
      ),
    );
    when(() => harness.repository.translate(any(), any())).thenAnswer((call) {
      final request = call.positionalArguments[1] as TranslationRequest;
      requests.add(request);
      return answer(request);
    });
  });

  // The completer is made in the test's fake async zone: one made in setUp
  // would complete outside it, after the test.
  Future<void> pump(WidgetTester tester, {AppLock? lock}) {
    capture = Completer<ScreenCapture>();
    return harness.pump(
      tester,
      ScreenTranslatePage(
        host: host,
        lock: lock,
        recognizer: data,
        encoder: harness.encoder,
      ),
      size: const Size(400, 800),
    );
  }

  Future<void> captured(WidgetTester tester, {bool blank = false}) async {
    capture.complete(
      ScreenCaptured(bytes: pngBytes, width: 400, height: 800, blank: blank),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('draws nothing while the screenshot is taken', (tester) async {
    await pump(tester);
    await tester.pump();

    expect(find.byKey(const Key('screen_translate_invisible')), findsOneWidget);
    expect(find.byType(Scaffold), findsNothing);
    expect(find.byType(Card), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(requests, isEmpty);
  });

  group('the screenshot', () {
    testWidgets('is read on the device and translated over it', (tester) async {
      await pump(tester);
      await captured(tester);

      expect(data.recognized, [
        ['deu'],
      ]);
      expect(requests.single.text, 'Ausgang\n\nKasse');
      expect(requests.single.target, french);
      expect(find.byKey(const Key('screen_translate_overlay')), findsOneWidget);
      expect(
        find.byKey(const Key('image_translate_overlay_paragraph_0')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('screen_translate_panel')), findsOneWidget);
      expect(
        find.byKey(const Key('screen_translate_hold_original')),
        findsOneWidget,
      );
      // Nothing was uploaded: only the recognised text went to the engine.
      verifyNever(
        () => harness.repository.translateImage(
          any(),
          any(),
          mimeType: any(named: 'mimeType'),
          source: any(named: 'source'),
          target: any(named: 'target'),
          options: any(named: 'options'),
        ),
      );
    });

    testWidgets('Open in Mozhi hands the recognised text to the app', (
      tester,
    ) async {
      await pump(tester);
      await captured(tester);

      await tester.tap(find.byKey(const Key('screen_translate_open_in_app')));
      await tester.pump();
      verify(() => host.openTextInApp('Ausgang\n\nKasse')).called(1);
    });

    testWidgets('copies the translation and shows both texts', (tester) async {
      final clipboard = FakeClipboard(tester);
      await pump(tester);
      await captured(tester);

      await tester.tap(find.byKey(const Key('screen_translate_copy')));
      await tester.pump();
      expect(clipboard.copied, 'Exit\n\nCash desk');

      await tester.tap(find.byKey(const Key('screen_translate_show_text')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('image_translate_overlay_sheet_original')),
        findsOneWidget,
      );
      expect(find.text('Ausgang\n\nKasse'), findsOneWidget);
      expect(find.text('Exit\n\nCash desk'), findsOneWidget);
    });

    testWidgets('holding Original shows the plain screenshot', (tester) async {
      await pump(tester);
      await captured(tester);

      final hold = tester.getCenter(
        find.byKey(const Key('screen_translate_hold_original')),
      );
      final gesture = await tester.startGesture(hold);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TranslatedImageOverlay>(
              find.byKey(const Key('screen_translate_overlay')),
            )
            .showOriginal,
        isTrue,
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('without a layout shows the screenshot and the actions', (
      tester,
    ) async {
      data.layout = null;
      await pump(tester);
      await captured(tester);

      expect(
        find.byKey(const Key('screen_translate_screenshot')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('screen_translate_overlay')), findsNothing);
      expect(
        find.byKey(const Key('screen_translate_hold_original')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('screen_translate_show_text')),
        findsOneWidget,
      );
    });

    testWidgets('a poorly read text offers the source language', (
      tester,
    ) async {
      when(() => harness.translate.state)
          .thenReturn(translateState(engines: const [deepl]));
      data.confidence = 20;
      await pump(tester);
      await captured(tester);

      await tester.tap(find.byKey(const Key('screen_translate_choose_source')));
      await tester.pumpAndSettle();
      expect(find.byType(ImageLanguagePickerSheet), findsOneWidget);
    });
  });

  group('waits for on-device recognition', () {
    testWidgets('until the engines are loaded', (tester) async {
      final engines = StreamController<TranslateState>();
      addTearDown(() => unawaited(engines.close()));
      const loading = TranslateState(enginesStatus: EnginesStatus.loading);
      whenListen(harness.translate, engines.stream, initialState: loading);
      await pump(tester);
      await captured(tester);
      expect(requests, isEmpty);
      expect(find.byKey(const Key('screen_translate_notice')), findsNothing);

      // Loading failed once (nothing to translate with yet), then worked.
      const failed = TranslateState(enginesStatus: EnginesStatus.failure);
      when(() => harness.translate.state).thenReturn(failed);
      engines.add(failed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('screen_translate_notice')), findsOneWidget);

      final ready = translateState(engines: const [deepl], source: german);
      when(() => harness.translate.state).thenReturn(ready);
      engines.add(ready);
      await tester.pumpAndSettle();
      expect(requests.single.text, 'Ausgang\n\nKasse');
    });

    testWidgets('and follows new providers', (tester) async {
      final settings = StreamController<AppSettings>();
      addTearDown(() => unawaited(settings.close()));
      whenListen(
        harness.settings,
        settings.stream,
        initialState: const AppSettings(),
      );
      await pump(tester);
      await captured(tester);
      settings.add(const AppSettings(providers: allProviders));
      await tester.pumpAndSettle();
      // Translated once, by the on-device method.
      expect(requests, hasLength(1));
    });

    testWidgets('and says when the device has none', (tester) async {
      data.isSupported = false;
      await pump(tester);
      await captured(tester);

      expect(find.byKey(const Key('screen_translate_notice')), findsOneWidget);
      expect(data.recognized, isEmpty);
      expect(requests, isEmpty);
      await tester.tap(find.byKey(const Key('screen_translate_notice_close')));
      verify(host.close).called(1);
    });

    testWidgets('switches to it from another method', (tester) async {
      when(() => harness.settings.state)
          .thenReturn(const AppSettings(providers: allProviders));
      when(() => harness.translate.state).thenReturn(
        translateState(engines: const [claude], engine: null, source: german),
      );
      final engines = StreamController<TranslateState>();
      addTearDown(() => unawaited(engines.close()));
      whenListen(
        harness.translate,
        engines.stream,
        initialState: translateState(
          engines: const [claude],
          engine: null,
          source: german,
        ),
      );
      await pump(tester);
      await captured(tester);
      // Only AI vision so far: never used for the screen.
      expect(requests, isEmpty);

      final ready = translateState(
        engines: const [claude, deepl],
        source: german,
      );
      when(() => harness.translate.state).thenReturn(ready);
      engines.add(ready);
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      verifyNever(
        () => harness.repository.translateImage(
          any(),
          any(),
          mimeType: any(named: 'mimeType'),
          source: any(named: 'source'),
          target: any(named: 'target'),
          options: any(named: 'options'),
        ),
      );
    });
  });

  for (final (code, expected) in [('de', 'German'), ('qaa', 'qaa')]) {
    testWidgets('names the detected language of the text ($code)', (
      tester,
    ) async {
      when(() => harness.translate.state)
          .thenReturn(translateState(engines: const [deepl]));
      answer = (_) => Stream.value(
        TranslationResult(
          engineId: deepl.id,
          engineName: deepl.name,
          text: 'Exit\n\nCash desk',
          detectedSource: code,
        ),
      );
      await pump(tester);
      await captured(tester);
      await tester.tap(find.byKey(const Key('screen_translate_show_text')));
      await tester.pumpAndSettle();
      expect(find.text('Ausgang\n\nKasse'), findsOneWidget);
      final source = tester
          .widget<TranslatedImageOverlay>(
            find.byKey(const Key('screen_translate_overlay')),
          )
          .source;
      expect((source.code, source.name), (code, expected));
    });
  }

  group('errors', () {
    testWidgets('the privacy settings ask first', (tester) async {
      const consent = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination(
          'mozhi.example',
          engine: 'deepl',
        ),
        engineId: 'mozhi:deepl',
        target: 'fr',
      );
      when(() => harness.repository.instances).thenReturn(const []);
      answer = (_) => Stream.error(consent);
      await pump(tester);
      await captured(tester);

      expect(find.byKey(const Key('screen_translate_consent')), findsOneWidget);
    });

    testWidgets('no text offers Retry', (tester) async {
      data
        ..text = ''
        ..layout = null;
      await pump(tester);
      await captured(tester);

      expect(find.text('No text was found in the image.'), findsOneWidget);
      data
        ..text = 'Ausgang Kasse'
        ..layout = _layout;
      await tester.tap(find.byKey(const Key('screen_translate_error_retry')));
      await tester.pumpAndSettle();
      expect(data.recognized, hasLength(2));
      expect(find.byKey(const Key('screen_translate_overlay')), findsOneWidget);
    });

    testWidgets('a missing offline language opens Mozhi to get it', (
      tester,
    ) async {
      answer = (_) => Stream.error(const OfflineModelMissingException(['fr']));
      await pump(tester);
      await captured(tester);

      await tester.tap(find.byKey(const Key('screen_translate_error_fix')));
      await tester.pump();
      verify(() => host.openLocationInApp('/settings/offline')).called(1);
    });

    testWidgets('an undetectable language asks for it', (tester) async {
      answer = (_) => Stream.error(const SourceLanguageRequiredException());
      await pump(tester);
      await captured(tester);

      expect(
        find.byKey(const Key('screen_translate_error_retry')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const Key('screen_translate_error_choose_source')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ImageLanguagePickerSheet), findsOneWidget);
    });

    testWidgets('missing recognition data is offered for download', (
      tester,
    ) async {
      data.installed = {};
      await pump(tester);
      await captured(tester);

      expect(
        find.byKey(const Key('image_translate_ocr_offer')),
        findsOneWidget,
      );
    });

    testWidgets('a cancelled translation can be started again', (tester) async {
      final gate = StreamController<TranslationResult>.broadcast();
      addTearDown(() => unawaited(gate.close()));
      answer = (_) => gate.stream;
      await pump(tester);
      capture.complete(
        ScreenCaptured(bytes: pngBytes, width: 400, height: 800),
      );
      final progress = find.byKey(const Key('image_translate_progress'));
      for (var i = 0; i < 10 && progress.evaluate().isEmpty; i++) {
        await tester.pump();
      }
      expect(progress, findsOneWidget);
      expect(requests, hasLength(1));

      await tester.tap(find.byKey(const Key('image_translate_cancel_button')));
      await tester.pumpAndSettle();
      answer = (_) => Stream.value(
        TranslationResult(
          engineId: deepl.id,
          engineName: deepl.name,
          text: 'Exit\n\nCash desk',
        ),
      );
      await tester.tap(find.byKey(const Key('screen_translate_retry')));
      await tester.pumpAndSettle();
      expect(requests, hasLength(2));
      expect(find.byKey(const Key('screen_translate_overlay')), findsOneWidget);
    });
  });

  group('the window', () {
    testWidgets('closes with the close button and with back', (tester) async {
      await pump(tester);
      await captured(tester);

      await tester.tap(find.byKey(const Key('screen_translate_close_button')));
      await tester.pump();
      verify(host.close).called(1);

      await tester.binding.handlePopRoute();
      await tester.pump();
      verify(host.close).called(1);
    });

    testWidgets('a declined consent closes it', (tester) async {
      await pump(tester);
      capture.complete(const ScreenCaptureDeclined());
      await tester.pumpAndSettle();
      verify(host.close).called(1);
    });

    testWidgets('a failed capture says so', (tester) async {
      await pump(tester);
      capture.complete(const ScreenCaptureFailed('projection'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('screen_translate_failed')), findsOneWidget);
      await tester.tap(find.byKey(const Key('screen_translate_close')));
      verify(host.close).called(1);
    });

    testWidgets('a black screenshot says why', (tester) async {
      await pump(tester);
      await captured(tester, blank: true);

      expect(find.byKey(const Key('screen_translate_blank')), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(data.recognized, isEmpty);
    });
  });

  group('the app lock', () {
    testWidgets('unlocks before anything is shown', (tester) async {
      final lock = FakeAppLock(locked: true)..gate = Completer<void>();
      await pump(tester, lock: lock);
      capture.complete(
        ScreenCaptured(bytes: pngBytes, width: 400, height: 800),
      );
      await tester.pump();
      await tester.pump();

      expect(lock.prompts, 1);
      expect(
        find.byKey(const Key('screen_translate_invisible')),
        findsOneWidget,
      );
      expect(find.byType(Image), findsNothing);
      expect(data.recognized, isEmpty);

      lock.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('screen_translate_overlay')), findsOneWidget);
    });

    testWidgets('a cancelled prompt leaves Unlock and Close', (tester) async {
      final lock = FakeAppLock(locked: true)..unlockResult = false;
      await pump(tester, lock: lock);
      await captured(tester);

      expect(find.byKey(const Key('screen_translate_locked')), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(data.recognized, isEmpty);

      lock.unlockResult = true;
      await tester.tap(find.byKey(const Key('screen_translate_unlock')));
      await tester.pumpAndSettle();
      expect(lock.prompts, 2);
      expect(find.byKey(const Key('screen_translate_overlay')), findsOneWidget);
    });
  });

  testWidgets('works in the dark theme at a large text size', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    capture = Completer<ScreenCapture>();
    await harness.pump(
      tester,
      ScreenTranslatePage(
        host: host,
        recognizer: data,
        encoder: harness.encoder,
      ),
      size: const Size(400, 800),
      themeMode: ThemeMode.dark,
    );
    await captured(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('screen_translate_panel')), findsOneWidget);
  });
}
