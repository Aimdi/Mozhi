import 'dart:async';
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
  new({
    this.access = CameraAccess.granted,
    List<Object?>? frameSteps,
    this.startError,
    this.startGate,
  }) : _frameSteps = List.of(frameSteps ?? const []);

  CameraAccess access;
  final List<Object?> _frameSteps;
  Error? startError;
  Completer<void>? startGate;
  int startCalls = 0;
  int stopCalls = 0;
  int accessCalls = 0;

  bool get stopped => stopCalls > 0;

  @override
  bool get isSupported => true;

  @override
  Future<CameraAccess> requestAccess() async {
    accessCalls++;
    return access;
  }

  @override
  Future<LivePreview> start() async {
    startCalls++;
    if (startGate != null) {
      await startGate!.future;
    }
    final error = startError;
    if (error != null) throw error;
    return const LivePreview(
      textureId: 1,
      previewSize: Size(320, 320),
      rotation: 0,
      hasTorch: true,
      maxZoom: 2,
    );
  }

  @override
  Future<CameraFrame?> nextFrame() async {
    if (_frameSteps.isEmpty) return null;
    final next = _frameSteps.removeAt(0);
    if (next is Exception) throw next;
    if (next is Error) throw next;
    return next as CameraFrame?;
  }

  @override
  Future<void> setTorch({required bool on}) async {}

  @override
  Future<void> setZoom(double ratio) async {}

  @override
  Future<PickedImage?> takePicture() async => null;

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

void main() {
  final sampleCode = PairingCode(
    address: const [192, 168, 1, 42],
    port: 41234,
    secret: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
  );

  testWidgets('scans a valid pairing QR code and pops with its text', (
    tester,
  ) async {
    final camera = _FakeCamera(frameSteps: [_renderQrFrame(sampleCode.link)]);
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
    expect(result, sampleCode.text);
    expect(camera.stopped, isTrue);
  });

  testWidgets(
    'shows permission guidance and retry button when camera access is denied',
    (tester) async {
      final camera = _FakeCamera(
        access: CameraAccess.denied,
        frameSteps: [_renderQrFrame(sampleCode.link)],
      );
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
      expect(find.byIcon(Icons.no_photography_outlined), findsOneWidget);
      expect(find.byKey(const Key('pairing_qr_retry')), findsOneWidget);

      // Granting permission and tapping Retry starts scanning and pops.
      camera.access = CameraAccess.granted;
      await tester.tap(find.byKey(const Key('pairing_qr_retry')));
      await tester.pumpAndSettle();
      expect(result, sampleCode.text);
    },
  );

  testWidgets('re-checks permission and restarts camera on app resume', (
    tester,
  ) async {
    final camera = _FakeCamera(
      access: CameraAccess.blocked,
      frameSteps: [_renderQrFrame(sampleCode.link)],
    );
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
    expect(camera.accessCalls, 1);

    // User switches to Android Settings (paused), grants permission, and
    // returns.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    final stopsAfterPause = camera.stopCalls;
    expect(stopsAfterPause, greaterThanOrEqualTo(1));

    camera.access = CameraAccess.granted;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(result, sampleCode.text);
  });

  testWidgets('shows distinct camera error message when start fails', (
    tester,
  ) async {
    final camera = _FakeCamera(startError: StateError('camera busy'));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PairingQrScannerPage(controller: camera, decodeInline: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pairing_qr_camera_error')), findsOneWidget);
    expect(
      find.text(
        "Couldn't start the camera. You can still type or paste the code.",
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('pairing_qr_error_retry')), findsOneWidget);
  });

  testWidgets(
    'stops camera if popped while camera.start() is still in flight',
    (tester) async {
      final gate = Completer<void>();
      final camera = _FakeCamera(startGate: gate);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => PairingQrScannerPage(
                      controller: camera,
                      decodeInline: true,
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump();
      expect(camera.startCalls, 1);

      // Pop while start() has not yet resolved.
      await tester.pageBack();
      await tester.pumpAndSettle();
      final stopsAtDispose = camera.stopCalls;

      // Now start() resolves — must call stop() again to avoid leaking session.
      gate.complete();
      await tester.pump();
      expect(camera.stopCalls, greaterThan(stopsAtDispose));
    },
  );

  testWidgets(
    'recovers from transient frame errors and shows banner for non-pairing QR',
    (tester) async {
      final camera = _FakeCamera(
        frameSteps: [
          null,
          StateError('transient frame drop'),
          _renderQrFrame('https://example.org/not-a-pairing-code'),
          _renderQrFrame(sampleCode.link),
        ],
      );
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
      // Advance past the two transient failures (100ms + 200ms) and decode
      // the non-pairing QR frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.byKey(const Key('pairing_qr_not_pairing_banner')),
        findsOneWidget,
      );

      // Advance past the 120ms scan interval to decode the valid pairing QR.
      await tester.pumpAndSettle();
      expect(result, sampleCode.text);
    },
  );
}
