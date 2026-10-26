import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/models/text_layout.dart';
import 'package:mozhi/image_translate/widgets/overlay_painting.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live_camera/cubit/live_camera_cubit.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';
import 'package:mozhi/live_camera/models/live_block.dart';
import 'package:mozhi/live_camera/widgets/live_camera_labels.dart';
import 'package:mozhi/live_camera/widgets/live_camera_preview.dart';
import 'package:mozhi/live_camera/widgets/live_overlay.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';
import '../helpers/live_camera_fakes.dart';

const _frame = Size(360, 640);

List<OverlayLabel> _labels(String translation) => layoutOverlay(
  TextLayout(
    width: 360,
    height: 640,
    paragraphs: [paragraph('Exit', box: const Rect.fromLTWH(20, 40, 120, 30))],
  ),
  [translation],
  direction: TextDirection.ltr,
);

void main() {
  group('coverRect', () {
    test('fills the box, centred, cutting the overflow', () {
      expect(
        coverRect(const Size(720, 1280), const Size(400, 800)),
        const Rect.fromLTWH(-25, 0, 450, 800),
      );
      expect(
        coverRect(const Size(1280, 720), const Size(400, 800)),
        const Rect.fromLTWH(-511.1111111111111, 0, 1422.2222222222222, 800),
      );
      expect(
        coverRect(Size.zero, const Size(400, 800)),
        const Rect.fromLTWH(0, 0, 400, 800),
      );
    });
  });

  group('LiveOverlayPainter', () {
    test('paints labels and outlines in preview coordinates', () {
      final labels = _labels('Ausgang');
      final painter = LiveOverlayPainter(
        labels: labels,
        reading: const [Rect.fromLTWH(10, 300, 100, 20)],
        frameSize: _frame,
        previewRect: const Rect.fromLTWH(-25, 0, 450, 800),
        hintOf: (original) => 'Original: $original',
        direction: TextDirection.ltr,
      );
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(400, 800));
      recorder.endRecording().dispose();

      final nodes = painter.semanticsBuilder(const Size(400, 800));
      expect(nodes.single.properties.label, 'Ausgang');
      expect(nodes.single.properties.hint, 'Original: Exit');
      // Scaled by 450 / 360, moved by the preview's offset and cut to
      // what shows.
      final fill = labels.single.fill;
      expect(nodes.single.rect.top, closeTo(fill.top * 1.25, 1e-9));
      expect(nodes.single.rect.right, closeTo(-25 + fill.right * 1.25, 1e-9));
      expect(nodes.single.rect.left, closeTo(0, 1e-9));
      expect(painter.shouldRepaint(painter), isFalse);
      expect(painter.shouldRebuildSemantics(painter), isFalse);
      for (final label in labels) {
        label.dispose();
      }
    });

    test('leaves out of reach what is cut off', () {
      final labels = _labels('Ausgang');
      final painter = LiveOverlayPainter(
        labels: labels,
        reading: const [],
        frameSize: _frame,
        previewRect: const Rect.fromLTWH(-1000, 0, 450, 800),
        hintOf: (original) => original,
        direction: TextDirection.ltr,
      );
      expect(painter.semanticsBuilder(const Size(400, 800)), isEmpty);
      final moved = LiveOverlayPainter(
        labels: labels,
        reading: const [],
        frameSize: _frame,
        previewRect: const Rect.fromLTWH(0, 0, 450, 800),
        hintOf: (original) => original,
        direction: TextDirection.ltr,
      );
      expect(moved.shouldRepaint(painter), isTrue);
      for (final label in labels) {
        label.dispose();
      }
    });
  });

  group('LiveOverlay', () {
    final block = LiveBlock(
      id: 1,
      paragraph: paragraph('Exit', box: const Rect.fromLTWH(20, 40, 120, 30)),
    );

    Future<LiveOverlayPainter?> pump(
      WidgetTester tester, {
      required List<LiveBlock> blocks,
      Size? frameSize = _frame,
      Language target = german,
    }) async {
      await tester.pumpApp(
        LiveOverlay(
          blocks: blocks,
          frameSize: frameSize,
          previewRect: const Rect.fromLTWH(0, 0, 360, 640),
          target: target,
        ),
      );
      final paint = find.byKey(const Key('live_camera_overlay'));
      if (paint.evaluate().isEmpty) return null;
      return tester.widget<CustomPaint>(paint).painter! as LiveOverlayPainter;
    }

    testWidgets('lays a label out once and reuses it', (tester) async {
      final translated = block.translated('Ausgang');
      final first = await pump(tester, blocks: [translated]);
      final again = await pump(tester, blocks: [translated]);
      expect(again!.labels.single, same(first!.labels.single));

      final changed = await pump(
        tester,
        blocks: [translated.copyWith(translation: () => 'Notausgang')],
      );
      expect(changed!.labels.single.translation, 'Notausgang');

      final gone = await pump(tester, blocks: const []);
      expect(gone!.labels, isEmpty);
    });

    testWidgets('a block being read is an outline', (tester) async {
      final painter = await pump(tester, blocks: [block]);
      expect(painter!.labels, isEmpty);
      expect(painter.reading, [block.box]);
    });

    testWidgets('right to left for an Arabic target', (tester) async {
      final painter = await pump(
        tester,
        blocks: [block.translated('مخرج')],
        target: const Language(code: 'ar', name: 'Arabic'),
      );
      expect(painter!.direction, TextDirection.rtl);
    });

    testWidgets('nothing without a frame', (tester) async {
      expect(await pump(tester, blocks: [block], frameSize: null), isNull);
    });
  });

  group('labels', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    LiveCameraState state(
      LiveCameraStatus status, {
      LivePauseReason? pauseReason,
      DeviceStrain? strain,
      LiveCameraErrorKind? cameraError,
    }) => LiveCameraState(
      source: english,
      target: german,
      engine: TranslationEngine.offline(),
      status: status,
      pauseReason: pauseReason,
      strain: strain,
      cameraError: cameraError,
    );

    test('the status line', () {
      expect(
        liveCameraStatusText(l10n, state(LiveCameraStatus.initial)),
        'Starting the camera…',
      );
      expect(
        liveCameraStatusText(l10n, state(LiveCameraStatus.running)),
        'Translating live with Offline (on-device)',
      );
      expect(
        liveCameraStatusText(
          l10n,
          state(LiveCameraStatus.running, strain: DeviceStrain.batterySaver),
        ),
        'Reading less often to save battery',
      );
      expect(
        liveCameraStatusText(
          l10n,
          state(LiveCameraStatus.paused, pauseReason: LivePauseReason.heat),
        ),
        startsWith('Paused: the phone is too hot'),
      );
      expect(
        liveCameraStatusText(l10n, state(LiveCameraStatus.paused)),
        'Paused',
      );
      expect(
        liveCameraStatusText(l10n, state(LiveCameraStatus.frozen)),
        'Taking the photo…',
      );
      expect(
        liveCameraStatusText(l10n, state(LiveCameraStatus.denied)),
        l10n.liveCameraPermissionDenied,
      );
      expect(
        liveCameraStatusText(l10n, state(LiveCameraStatus.blocked)),
        l10n.liveCameraBlockedBody,
      );
      expect(
        liveCameraStatusText(l10n, state(LiveCameraStatus.unsupported)),
        l10n.liveCameraUnsupported,
      );
      expect(
        liveCameraStatusText(
          l10n,
          state(
            LiveCameraStatus.failed,
            cameraError: LiveCameraErrorKind.noCamera,
          ),
        ),
        l10n.liveCameraErrorNoCamera,
      );
    });

    test('camera errors', () {
      expect(
        {
          for (final kind in [...LiveCameraErrorKind.values, null])
            liveCameraErrorText(l10n, kind),
        },
        {
          l10n.liveCameraErrorNoCamera,
          l10n.liveCameraErrorInUse,
          l10n.liveCameraErrorDisabled,
          l10n.liveCameraErrorStalled,
          l10n.liveCameraPermissionDenied,
          l10n.liveCameraErrorFailed,
        },
      );
    });

    test('engine errors', () {
      expect(
        liveCameraTranslationErrorText(l10n, Exception('x')),
        startsWith('Couldn’t translate: '),
      );
    });

    test('zoom', () {
      expect(liveCameraZoomLabel(1), '1');
      expect(liveCameraZoomLabel(2.5), '2.5');
      expect(liveCameraZoomLabel(1.04), '1');
      expect(nextLiveCameraZoom(1, min: 1, max: 8), 2);
      expect(nextLiveCameraZoom(2, min: 1, max: 8), 4);
      expect(nextLiveCameraZoom(4, min: 1, max: 5), 1);
      expect(nextLiveCameraZoom(1, min: 1, max: 1.5), 1);
      expect(nextLiveCameraZoom(1.5, min: 1.5, max: 3), 2);
    });
  });

  test('LiveCameraState lists its translated blocks', () {
    final block = LiveBlock(id: 1, paragraph: paragraph('Exit'));
    final state = LiveCameraState(
      source: english,
      target: german,
      engine: TranslationEngine.offline(),
      blocks: [block, block.copyWith(seen: 2).translated('Ausgang')],
    );
    expect(state.translatedBlocks.single.translation, 'Ausgang');
    expect(state.isLive, isFalse);
    expect(state.copyWith(), state);
  });
}
