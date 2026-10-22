import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

/// In-memory [DocumentFileService] for the save and share actions.
class _FakeFiles implements DocumentFileService {
  bool saveResult = true;
  bool canShare = true;
  Exception? saveError;
  Exception? shareError;
  final saved = <({String fileName, Uint8List bytes, String mimeType})>[];
  final shared = <({String fileName, Uint8List bytes, Rect? origin})>[];

  @override
  bool get canShareFiles => canShare;

  @override
  Future<bool> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    if (saveError != null) throw saveError!;
    saved.add((fileName: fileName, bytes: bytes, mimeType: mimeType));
    return saveResult;
  }

  @override
  Future<void> shareFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    Rect? origin,
  }) async {
    if (shareError != null) throw shareError!;
    shared.add((fileName: fileName, bytes: bytes, origin: origin));
  }

  @override
  Future<PickedFile?> pickFile({required List<String> extensions}) =>
      throw UnimplementedError();

  @override
  Future<void> copyText(String text) => throw UnimplementedError();

  @override
  Future<String?> pasteText() => throw UnimplementedError();
}

/// Records what it was asked to render and returns [png].
class _FakeRenderer implements OverlayImageRenderer {
  Uint8List png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
  Exception? error;
  final calls = <({List<String> translations, TextDirection direction})>[];

  @override
  Future<Uint8List> render(
    Uint8List image,
    TextLayout layout,
    List<String> translations, {
    required TextDirection direction,
    Locale? locale,
    TextStyle style = const TextStyle(),
    int maxSide = overlayExportMaxSide,
  }) async {
    calls.add((translations: translations, direction: direction));
    if (error != null) throw error!;
    return png;
  }
}

const _white = Color(0xFFFFFFFF);
const _yellow = Color(0xFFFFDC00);
const _navy = Color(0xFF001480);

const _layout = TextLayout(
  width: 400,
  height: 300,
  paragraphs: [
    TextParagraph(
      text: 'Öffnungszeiten',
      box: Rect.fromLTWH(20, 20, 300, 40),
      alignment: TextParagraphAlignment.left,
      background: _yellow,
      foreground: _navy,
    ),
    TextParagraph(
      text: 'Montag bis Freitag',
      box: Rect.fromLTWH(20, 100, 300, 80),
      lineCount: 2,
    ),
    TextParagraph(
      text: 'Kasse',
      box: Rect.fromLTWH(0, 260, 120, 40),
      alignment: TextParagraphAlignment.right,
    ),
  ],
);

const _translations = ['Opening hours', 'Monday to Friday', ''];

ImageTranslation _result({
  List<String> translations = _translations,
  TextLayout? layout,
}) => ImageTranslation(
  sourceText: (layout ?? _layout).text,
  translatedText: translations.join('\n\n'),
  layout: layout ?? _layout,
  translatedParagraphs: translations,
);

/// A PNG of [width] x [height] filled with [color].
Future<Uint8List> _png(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// Whether [a] and [b] differ by at most 3 in every channel.
bool _near(Color a, Color b) {
  final (x, y) = (a.toARGB32(), b.toARGB32());
  for (final shift in [24, 16, 8, 0]) {
    if (((x >> shift & 0xFF) - (y >> shift & 0xFF)).abs() > 3) return false;
  }
  return true;
}

Future<ui.Image> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  return (await codec.getNextFrame()).image;
}

Future<Color> _pixel(ui.Image image, int x, int y) async {
  final data = (await image.toByteData())!;
  final offset = (y * image.width + x) * 4;
  return Color.fromARGB(
    data.getUint8(offset + 3),
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
  );
}

void main() {
  setUpAll(registerImageTranslateFallbacks);

  group('fitOverlayText', () {
    test('uses the largest size up to the original line height', () {
      final painter = fitOverlayText(
        'Exit',
        const TextStyle(),
        const Size(300, 60),
        maxFontSize: 40,
        minFontSize: 8,
      );
      addTearDown(painter.dispose);
      expect((painter.text! as TextSpan).style!.fontSize, 40);
      expect(painter.width, 300);
    });

    test('shrinks long text to fit the box, wrapping it', () {
      const area = Size(200, 60);
      final painter = fitOverlayText(
        'Monday to Friday from nine in the morning to six in the evening',
        const TextStyle(),
        area,
        maxFontSize: 40,
        minFontSize: 4,
      );
      addTearDown(painter.dispose);
      final size = (painter.text! as TextSpan).style!.fontSize!;
      expect(size, lessThan(40));
      expect(size, greaterThan(4));
      expect(painter.height, lessThanOrEqualTo(area.height + 0.5));
      expect(painter.computeLineMetrics().length, greaterThan(1));
    });

    test('does not break a long word when a smaller size avoids it', () {
      final painter = fitOverlayText(
        'Donaudampfschifffahrtsgesellschaft',
        const TextStyle(),
        const Size(100, 200),
        maxFontSize: 40,
        minFontSize: 2,
      );
      addTearDown(painter.dispose);
      expect(painter.computeLineMetrics(), hasLength(1));
    });

    test('Chinese breaks anywhere and keeps a large size', () {
      final painter = fitOverlayText(
        '营业时间周一至周五',
        const TextStyle(),
        const Size(100, 200),
        maxFontSize: 30,
        minFontSize: 2,
        locale: const Locale('zh'),
      );
      addTearDown(painter.dispose);
      expect((painter.text! as TextSpan).style!.fontSize, greaterThan(15));
    });

    test('ends with an ellipsis when even the smallest size overflows', () {
      final painter = fitOverlayText(
        List.filled(200, 'word').join(' '),
        const TextStyle(),
        const Size(100, 20),
        maxFontSize: 20,
        minFontSize: 8,
      );
      addTearDown(painter.dispose);
      expect((painter.text! as TextSpan).style!.fontSize, 8);
      expect(painter.maxLines, 2);
      expect(painter.didExceedMaxLines, isTrue);
      expect(painter.height, lessThanOrEqualTo(20.5));
    });

    test('the smallest size can be the only one that fits', () {
      // "word" is 32 px wide at 8 px (test font), too wide above.
      final painter = fitOverlayText(
        'word',
        const TextStyle(),
        const Size(31.6, 100),
        maxFontSize: 8.3,
        minFontSize: 8,
      );
      addTearDown(painter.dispose);
      expect((painter.text! as TextSpan).style!.fontSize, 8);
      expect(painter.maxLines, isNull);
    });
  });

  group('colours', () {
    test('the original text colour is kept when it contrasts', () {
      expect(overlayTextColor(_yellow, _navy), _navy);
      expect(
        overlayTextColor(_white, const Color(0xFFEEEEEE)),
        const Color(0xFF000000),
      );
      expect(
        overlayTextColor(const Color(0xFF101010), null),
        const Color(0xFFFFFFFF),
      );
      expect(overlayTextColor(_white, _navy.withValues(alpha: 0.5)), _navy);
      expect(contrastRatio(_white, const Color(0xFF000000)), closeTo(21, 0.01));
      expect(contrastRatio(_white, _white), 1);
    });
  });

  group('layoutOverlay', () {
    test('covers each translated paragraph inside the image', () {
      final labels = layoutOverlay(
        _layout,
        _translations,
        direction: TextDirection.ltr,
      );
      addTearDown(() {
        for (final label in labels) {
          label.dispose();
        }
      });
      expect(labels.map((label) => label.index), [0, 1]);
      final first = labels.first;
      expect(first.original, 'Öffnungszeiten');
      expect(first.translation, 'Opening hours');
      expect(first.fill.contains(const Offset(20, 20)), isTrue);
      expect(first.fill.width, greaterThan(300));
      expect(first.background, _yellow);
      expect(first.foreground, _navy);
      expect(first.painter.textAlign, TextAlign.left);
      expect(first.blur, greaterThan(0));
      final second = labels[1];
      expect(second.background, overlayFallbackBackground);
      expect(second.foreground, const Color(0xFF000000));
      // Two lines of 40 px: at most 40 px type.
      expect(
        (second.painter.text! as TextSpan).style!.fontSize,
        lessThanOrEqualTo(40),
      );
      expect(second.painter.textAlign, TextAlign.start);

      final edge = layoutOverlay(
        _layout,
        const ['', '', 'Till'],
        direction: TextDirection.rtl,
        locale: const Locale('ar'),
      ).single;
      addTearDown(edge.dispose);
      // Clipped to the image.
      expect(edge.fill.left, 0);
      expect(edge.fill.bottom, 300);
      expect(edge.painter.textAlign, TextAlign.right);
      expect(edge.painter.textDirection, TextDirection.rtl);
    });

    test('centres a single line of unknown alignment', () {
      final labels = layoutOverlay(
        const TextLayout(
          width: 10,
          height: 10,
          paragraphs: [
            TextParagraph(
              text: 'Ausgang',
              box: Rect.fromLTWH(1, 1, 8, 4),
              alignment: TextParagraphAlignment.center,
            ),
            TextParagraph(text: 'Exit', box: Rect.fromLTWH(1, 5, 8, 4)),
          ],
        ),
        const ['Exit', 'Way out', 'ignored'],
        direction: TextDirection.ltr,
      );
      addTearDown(() {
        for (final label in labels) {
          label.dispose();
        }
      });
      expect(labels.map((label) => label.painter.textAlign), [
        TextAlign.center,
        TextAlign.center,
      ]);
    });

    test('paints the fill and the text on a canvas', () async {
      final label = layoutOverlay(
        _layout,
        _translations,
        direction: TextDirection.ltr,
      ).first;
      addTearDown(label.dispose);
      final recorder = ui.PictureRecorder();
      label.paint(Canvas(recorder));
      final image = await recorder.endRecording().toImage(400, 300);
      addTearDown(image.dispose);
      // The fill's colour inside the box, away from its blurred edge.
      final colour = await _pixel(image, 22, 22);
      expect(colour.toARGB32() & 0xFFFFFF, isNot(0));
    });
  });

  group('UiOverlayImageRenderer', () {
    testWidgets('renders the photo with the overlay at its resolution', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final photo = await _png(400, 300, const Color(0xFF336699));
        final png = await const UiOverlayImageRenderer().render(
          photo,
          _layout,
          _translations,
          direction: TextDirection.ltr,
          locale: const Locale('en'),
        );
        final image = await _decode(png);
        expect((image.width, image.height), (400, 300));
        // Inside the first paragraph's box: its background colour.
        final inside = await _pixel(image, 22, 25);
        expect(_near(inside, _yellow), isTrue, reason: '$inside');
        // Elsewhere: the photo.
        expect((await _pixel(image, 390, 10)).toARGB32(), 0xFF336699);
        image.dispose();

        // A larger photo than the layout scales the overlay; the long side
        // is capped.
        final large = await _png(800, 600, const Color(0xFF336699));
        final capped = await _decode(
          await const UiOverlayImageRenderer().render(
            large,
            _layout,
            _translations,
            direction: TextDirection.ltr,
            maxSide: 600,
          ),
        );
        expect((capped.width, capped.height), (600, 450));
        final scaled = await _pixel(capped, 34, 38);
        expect(_near(scaled, _yellow), isTrue, reason: '$scaled');
        capped.dispose();
      });
    });

    test('reports an image it cannot decode', () async {
      await expectLater(
        const UiOverlayImageRenderer().render(
          Uint8List.fromList([1, 2, 3]),
          _layout,
          _translations,
          direction: TextDirection.ltr,
        ),
        throwsA(
          const ImageTranslateException(ImageTranslateErrorKind.invalidImage),
        ),
      );
    });
  });

  group('TranslatedImageOverlay', () {
    late ImageTranslateHarness harness;

    setUp(() => harness = ImageTranslateHarness());

    Future<void> pump(
      WidgetTester tester, {
      bool showOriginal = false,
      TextLayout? layout,
      List<String> translations = _translations,
      bool reduceMotion = false,
    }) => harness.pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: reduceMotion),
            child: SizedBox(
              width: 400,
              height: 300,
              child: TranslatedImageOverlay(
                image: pngBytes,
                layout: layout ?? _layout,
                translations: translations,
                source: german,
                target: english,
                showOriginal: showOriginal,
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('each paragraph is a button read as its translation', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);
      final node = tester.getSemantics(
        find.byKey(const Key('image_translate_overlay_paragraph_0')),
      );
      expect(node.label, 'Opening hours');
      expect(node.hint, 'Öffnungszeiten');
      expect(node.flagsCollection.isButton, isTrue);
      expect(
        node.attributedLabel.attributes.single,
        isA<LocaleStringAttribute>().having(
          (a) => a.locale,
          'locale',
          const Locale('en'),
        ),
      );
      expect(
        find.byKey(const Key('image_translate_overlay_paragraph_2')),
        findsNothing,
      );
      expect(
        find.bySemanticsLabel('Photo with the translation over its text'),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('a tap shows the original and the translation to copy', (
      tester,
    ) async {
      final copied = <String>[];
      final previous = ClipboardService.instance;
      ClipboardService.instance = ClipboardService(
        isAndroid: false,
        setData: (data) async => copied.add(data.text!),
      );
      addTearDown(() => ClipboardService.instance = previous);
      await pump(tester);
      await tester.tap(
        find.byKey(const Key('image_translate_overlay_paragraph_1')),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('image_translate_overlay_sheet_original')),
          matching: find.text('Montag bis Freitag'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const Key('image_translate_overlay_sheet_translation'),
          ),
          matching: find.text('Monday to Friday'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Copy the original'));
      await tester.tap(find.byTooltip('Copy the translation'));
      await tester.pump();
      expect(copied, ['Montag bis Freitag', 'Monday to Friday']);
    });

    testWidgets('the sheet guesses the direction of undetected text', (
      tester,
    ) async {
      final harness = ImageTranslateHarness();
      await harness.pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showOverlayParagraph(
                context,
                original: 'مخرج',
                translation: 'Exit',
                source: Language.auto,
                target: english,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SelectableText>(
              find.ancestor(
                of: find.text('مخرج'),
                matching: find.byType(SelectableText),
              ),
            )
            .textDirection,
        TextDirection.rtl,
      );
      expect(
        tester
            .widget<SelectableText>(
              find.ancestor(
                of: find.text('Exit'),
                matching: find.byType(SelectableText),
              ),
            )
            .textDirection,
        TextDirection.ltr,
      );
    });

    testWidgets('screen readers open the sheet too', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);
      tester.semantics.tap(find.semantics.byLabel('Opening hours'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('image_translate_overlay_sheet_original')),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('fades out for the original, at once with reduced motion', (
      tester,
    ) async {
      await pump(tester, showOriginal: true);
      final layer = tester.widget<AnimatedOpacity>(
        find.byKey(const Key('image_translate_overlay_layer')),
      );
      expect(layer.opacity, 0);
      expect(layer.duration, TranslatedImageOverlay.fadeDuration);
      expect(find.bySemanticsLabel('Selected image'), findsOneWidget);

      await pump(tester, reduceMotion: true);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const Key('image_translate_overlay_layer')),
            )
            .duration,
        Duration.zero,
      );
    });

    testWidgets('lays out again only for a new translation', (tester) async {
      await pump(tester);
      final before = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const Key('image_translate_overlay_paragraph_0')),
          matching: find.byType(CustomPaint),
        ),
      );
      await pump(tester, showOriginal: true);
      final same = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const Key('image_translate_overlay_paragraph_0')),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(same.painter!.shouldRepaint(before.painter!), isFalse);
      await pump(tester, translations: const ['Hours', 'Days', 'Till']);
      final after = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const Key('image_translate_overlay_paragraph_0')),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(after.painter!.shouldRepaint(before.painter!), isTrue);
      expect(
        find.byKey(const Key('image_translate_overlay_paragraph_2')),
        findsOneWidget,
      );
    });
  });

  group('HoldToShowOriginalButton', () {
    testWidgets('shows the original while held', (tester) async {
      final changes = <bool>[];
      final harness = ImageTranslateHarness();
      await harness.pump(
        tester,
        Scaffold(
          body: Center(
            child: HoldToShowOriginalButton(
              showing: false,
              onChanged: changes.add,
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(HoldToShowOriginalButton)).height,
        greaterThanOrEqualTo(48),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(HoldToShowOriginalButton)),
      );
      expect(changes, [true]);
      await gesture.up();
      expect(changes, [true, false]);
      final cancelled = await tester.startGesture(
        tester.getCenter(find.byType(HoldToShowOriginalButton)),
      );
      await cancelled.cancel();
      expect(changes, [true, false, true, false]);
    });

    testWidgets('toggles for screen readers', (tester) async {
      final semantics = tester.ensureSemantics();
      final changes = <bool>[];
      final harness = ImageTranslateHarness();
      await harness.pump(
        tester,
        Scaffold(
          body: Center(
            child: HoldToShowOriginalButton(
              showing: true,
              onChanged: changes.add,
            ),
          ),
        ),
      );
      tester.semantics.tap(find.semantics.byLabel('Hold to see the original'));
      expect(changes, [false]);
      semantics.dispose();
    });
  });

  group('exportOverlayImage', () {
    late _FakeFiles files;
    late _FakeRenderer renderer;
    late ImageTranslateHarness harness;

    setUp(() {
      files = _FakeFiles();
      renderer = _FakeRenderer();
      OverlayExport.files = files;
      OverlayExport.renderer = renderer;
      addTearDown(() {
        OverlayExport.files = const PlatformDocumentFileService();
        OverlayExport.renderer = const UiOverlayImageRenderer();
      });
      harness = ImageTranslateHarness();
    });

    Future<BuildContext> pump(WidgetTester tester) async {
      late BuildContext captured;
      await harness.pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      return captured;
    }

    Future<void> export(
      WidgetTester tester,
      BuildContext context,
      OverlayExportAction action, {
      ImageTranslation? result,
      Language target = english,
    }) async {
      await exportOverlayImage(
        context,
        action: action,
        image: pngImage,
        result: result ?? _result(),
        target: target,
        origin: const Rect.fromLTWH(1, 2, 3, 4),
      );
      await tester.pump();
    }

    testWidgets('saves the rendered PNG', (tester) async {
      final context = await pump(tester);
      await export(tester, context, OverlayExportAction.save);
      expect(files.saved.single.fileName, OverlayExport.fileName);
      expect(files.saved.single.mimeType, 'image/png');
      expect(files.saved.single.bytes, renderer.png);
      expect(renderer.calls.single.translations, _translations);
      expect(renderer.calls.single.direction, TextDirection.ltr);
      expect(find.text('Image saved'), findsOneWidget);

      // A cancelled save dialog says nothing.
      files.saveResult = false;
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      await tester.pump();
      await export(tester, context, OverlayExportAction.save);
      expect(find.text('Image saved'), findsNothing);
    });

    testWidgets('shares the rendered PNG, right to left for Arabic', (
      tester,
    ) async {
      final context = await pump(tester);
      await export(
        tester,
        context,
        OverlayExportAction.share,
        target: const Language(code: 'ar', name: 'Arabic'),
      );
      expect(files.shared.single.bytes, renderer.png);
      expect(files.shared.single.origin, const Rect.fromLTWH(1, 2, 3, 4));
      expect(renderer.calls.single.direction, TextDirection.rtl);
    });

    testWidgets('says when sharing is not available', (tester) async {
      final context = await pump(tester);
      files.canShare = false;
      await export(tester, context, OverlayExportAction.share);
      expect(renderer.calls, isEmpty);
      expect(
        find.text('Sharing files isn’t available on this device.'),
        findsOneWidget,
      );

      files
        ..canShare = true
        ..shareError = const ShareUnsupportedException();
      await export(tester, context, OverlayExportAction.share);
      expect(
        find.text('Sharing files isn’t available on this device.'),
        findsOneWidget,
      );
    });

    testWidgets('reports failures', (tester) async {
      final context = await pump(tester);
      renderer.error = Exception('out of memory');
      await export(tester, context, OverlayExportAction.save);
      expect(files.saved, isEmpty);
      expect(
        find.text('The translated image couldn’t be created.'),
        findsOneWidget,
      );

      renderer.error = null;
      files.saveError = Exception('disk full');
      await tester.pump(const Duration(seconds: 10));
      await export(tester, context, OverlayExportAction.save);
      expect(
        find.text('The translated image couldn’t be created.'),
        findsOneWidget,
      );
    });

    testWidgets('does nothing without a layout', (tester) async {
      final context = await pump(tester);
      await export(
        tester,
        context,
        OverlayExportAction.save,
        result: const ImageTranslation(translatedText: 'x'),
      );
      expect(renderer.calls, isEmpty);
      expect(files.saved, isEmpty);
    });
  });

  group('on the image screen', () {
    late ImageTranslateHarness harness;
    late _FakeFiles files;
    late _FakeRenderer renderer;

    setUp(() {
      harness = ImageTranslateHarness();
      files = _FakeFiles();
      renderer = _FakeRenderer();
      OverlayExport.files = files;
      OverlayExport.renderer = renderer;
      addTearDown(() {
        OverlayExport.files = const PlatformDocumentFileService();
        OverlayExport.renderer = const UiOverlayImageRenderer();
      });
    });

    ImageTranslateState state({
      ImageResultMode mode = ImageResultMode.overlay,
      bool showOriginal = false,
      String? detected,
      Language source = german,
    }) => ImageTranslateState(
      status: ImageTranslateStatus.success,
      image: pngImage,
      methods: const [onDeviceMethod],
      method: onDeviceMethod,
      source: source,
      target: english,
      translateEngine: deepl,
      result: _result().copyWith(detectedSource: detected),
      resultMode: mode,
      showOriginal: showOriginal,
    );

    testWidgets('draws the translation over the photo by default', (
      tester,
    ) async {
      final cubit = mockImageCubit(state());
      when(() => cubit.setResultMode(any())).thenReturn(null);
      when(
        () => cubit.setShowOriginal(showOriginal: any(named: 'showOriginal')),
      ).thenReturn(null);
      await harness.pumpWithCubit(tester, cubit);
      expect(find.byKey(const Key('image_translate_overlay')), findsOneWidget);
      expect(
        find.byKey(const Key('image_translate_hold_original')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('image_translate_overlay_hint')),
        findsOneWidget,
      );
      // The texts are on the photo, not repeated below it.
      expect(
        find.byKey(const Key('image_translate_source_text')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('image_translate_translation')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('image_translate_share_button')),
        findsNothing,
      );

      await tester.tap(find.text('Text'));
      verify(() => cubit.setResultMode(ImageResultMode.text)).called(1);

      final gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(const Key('image_translate_hold_original')),
        ),
      );
      verify(() => cubit.setShowOriginal(showOriginal: true)).called(1);
      await gesture.up();
      verify(() => cubit.setShowOriginal(showOriginal: false)).called(1);
    });

    testWidgets('saves and shares the overlaid photo', (tester) async {
      final cubit = mockImageCubit(state());
      await harness.pumpWithCubit(tester, cubit);
      await tester.ensureVisible(
        find.byKey(const Key('image_translate_save_image_button')),
      );
      await tester.tap(
        find.byKey(const Key('image_translate_save_image_button')),
      );
      await tester.pumpAndSettle();
      expect(files.saved, hasLength(1));
      await tester.tap(
        find.byKey(const Key('image_translate_share_image_button')),
      );
      await tester.pumpAndSettle();
      expect(files.shared, hasLength(1));
      expect(files.shared.single.origin, isNotNull);
    });

    testWidgets('ignores a second press while rendering', (tester) async {
      final gate = Completer<void>();
      final slow = _GatedRenderer(gate.future);
      OverlayExport.renderer = slow;
      final cubit = mockImageCubit(state());
      await harness.pumpWithCubit(tester, cubit);
      final save = find.byKey(const Key('image_translate_save_image_button'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pump();
      await tester.tap(save);
      await tester.pump();
      expect(slow.calls, 1);
      gate.complete();
      await tester.pumpAndSettle();
      expect(files.saved, hasLength(1));
    });

    testWidgets('Text mode shows the plain photo and the texts', (
      tester,
    ) async {
      final cubit = mockImageCubit(state(mode: ImageResultMode.text));
      when(() => cubit.setResultMode(any())).thenReturn(null);
      await harness.pumpWithCubit(tester, cubit);
      expect(find.byKey(const Key('image_translate_overlay')), findsNothing);
      expect(
        find.byKey(const Key('image_translate_hold_original')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('image_translate_source_text')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('image_translate_share_button')),
        findsOneWidget,
      );
      await tester.tap(find.text('Overlay'));
      verify(() => cubit.setResultMode(ImageResultMode.overlay)).called(1);
    });

    testWidgets('reads the detected language for screen readers', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final cubit = mockImageCubit(
        state(source: Language.auto, detected: 'de'),
      );
      await harness.pumpWithCubit(tester, cubit);
      final node = tester.getSemantics(
        find.byKey(const Key('image_translate_overlay_paragraph_0')),
      );
      expect(
        node.attributedHint.attributes.single,
        isA<LocaleStringAttribute>().having(
          (a) => a.locale,
          'locale',
          const Locale('de'),
        ),
      );
      semantics.dispose();
    });

    testWidgets('a source the catalogue does not know is read as is', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final cubit = mockImageCubit(
        state(source: Language.auto, detected: 'qq'),
      );
      await harness.pumpWithCubit(tester, cubit);
      final node = tester.getSemantics(
        find.byKey(const Key('image_translate_overlay_paragraph_0')),
      );
      expect(
        (node.attributedHint.attributes.single as LocaleStringAttribute).locale,
        const Locale('qq'),
      );
      semantics.dispose();
    });

    testWidgets('the hold button hides while translating again', (
      tester,
    ) async {
      final cubit = mockImageCubit(
        state().copyWith(status: ImageTranslateStatus.working),
      );
      await harness.pumpWithCubit(tester, cubit);
      expect(
        find.byKey(const Key('image_translate_hold_original')),
        findsNothing,
      );
    });
  });
}

class _GatedRenderer implements OverlayImageRenderer {
  new(this.gate);

  final Future<void> gate;
  int calls = 0;

  @override
  Future<Uint8List> render(
    Uint8List image,
    TextLayout layout,
    List<String> translations, {
    required TextDirection direction,
    Locale? locale,
    TextStyle style = const TextStyle(),
    int maxSide = overlayExportMaxSide,
  }) async {
    calls++;
    await gate;
    return Uint8List(4);
  }
}
