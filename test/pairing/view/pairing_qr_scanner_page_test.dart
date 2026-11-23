import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/qr/qr_code.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';
import 'package:mozhi/pairing/protocol/pairing_code.dart';
import 'package:mozhi/pairing/view/pairing_qr_scanner_page.dart';

CameraFrame _renderQrFrame(String data, {int scale = 6, int margin = 24}) {
  final qr = QrCode.encode(data);
  final size = qr.size * scale + margin * 2;
  final pixels = Uint8List(size * size)..fillRange(0, size * size, 255);
  for (var y = 0; y < qr.size; y++) {
    for (var x = 0; x < qr.size; x++) {
      if (!qr.isDark(x, y)) continue;
      for (var dy = 0; dy < scale; dy++) {
        for (var dx = 0; dx < scale; dx++) {
          final py = margin + y * scale + dy;
          final px = margin + x * scale + dx;
          pixels[py * size + px] = 0;
        }
      }
    }
  }
  return CameraFrame(
    pixels: pixels,
    width: size,
    height: size,
    bytesPerRow: size,
    rotationDegrees: 0,
    timestamp: Duration.zero,
  );
}

final class _FakeCamera implements LiveCameraController {
  new({this.access = CameraAccess.granted, List<CameraFrame>? frames})
    : _frames = List.of(frames ?? const []);

  final CameraAccess access;
  final List<CameraFrame> _frames;
  bool stopped = false;

  @override
  bool get isSupported => true;

  @override
  Future<CameraAccess> requestAccess() async => access;

  @override
  Future<LivePreview> start() async => const LivePreview(
    textureId: 1,
    previewSize: Size(320, 320),
    rotation: 0,
    hasTorch: true,
    maxZoom: 2,
  );

  @override
  Future<CameraFrame?> nextFrame() async =>
      _frames.isEmpty ? null : _frames.removeAt(0);

  @override
  Future<void> setTorch({required bool on}) async {}

  @override
  Future<void> setZoom(double ratio) async {}

  @override
  Future<PickedImage?> takePicture() async => null;

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

void main() {
  testWidgets('scans a valid pairing QR code and pops with its text', (
    tester,
  ) async {
    final code = PairingCode(
      address: const [192, 168, 1, 42],
      port: 41234,
      secret: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
    );
    final camera = _FakeCamera(frames: [_renderQrFrame(code.link)]);
    String? result;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) => PairingQrScannerPage(
                      controller: camera,
                      decodeInline: true,
                    ),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(result, code.text);
    expect(camera.stopped, isTrue);
  });

  testWidgets('shows permission guidance when camera access is denied', (
    tester,
  ) async {
    final camera = _FakeCamera(access: CameraAccess.denied);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PairingQrScannerPage(controller: camera, decodeInline: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.no_photography_outlined), findsOneWidget);
  });
}
