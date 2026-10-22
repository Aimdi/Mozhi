import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/qr/qr_code.dart';
import 'package:mozhi/core/qr/qr_code_view.dart';

import '../../helpers/helpers.dart';

void main() {
  const data = 'http://192.168.1.23:48123/s/q2Xr9LmT0bWcZk4sY7uN1A';

  /// Renders [view] at a device pixel ratio of 1 and returns its pixels.
  Future<(ByteData, int)> render(
    WidgetTester tester,
    QrCodeView view, {
    ThemeData? theme,
  }) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpApp(
      Scaffold(
        body: Center(
          child: RepaintBoundary(key: key, child: view),
        ),
      ),
      theme: theme,
    );
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final result = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData();
      final width = image.width;
      image.dispose();
      return (bytes!, width);
    });
    return result!;
  }

  bool blackAt(ByteData bytes, int width, int x, int y) {
    final offset = (y * width + x) * 4;
    final (r, g, b, a) = (
      bytes.getUint8(offset),
      bytes.getUint8(offset + 1),
      bytes.getUint8(offset + 2),
      bytes.getUint8(offset + 3),
    );
    if (r == 0 && g == 0 && b == 0 && a == 255) return true;
    expect(
      (r, g, b, a),
      (255, 255, 255, 255),
      reason: 'pixel ($x, $y) is not crisp',
    );
    return false;
  }

  for (final (name, theme) in [
    ('light', ThemeData(useMaterial3: true)),
    ('dark', ThemeData(useMaterial3: true, brightness: Brightness.dark)),
  ]) {
    testWidgets('paints black modules on white in the $name theme', (
      tester,
    ) async {
      final code = QrCode.encode(data);
      // 33 modules + 8 of quiet zone: 4 pixels each, 4 left over.
      final (bytes, width) = await render(
        tester,
        const QrCodeView(data: data, semanticLabel: 'QR', size: 168),
        theme: theme,
      );

      expect(width, 168);
      const module = 4;
      const origin = 2 + 4 * module;
      for (var y = 0; y < code.size; y++) {
        for (var x = 0; x < code.size; x++) {
          for (final (dx, dy) in [(0, 0), (module - 1, module - 1)]) {
            expect(
              blackAt(
                bytes,
                width,
                origin + x * module + dx,
                origin + y * module + dy,
              ),
              code.isDark(x, y),
              reason: 'module ($x, $y)',
            );
          }
        }
      }
      // The quiet zone is white all around.
      for (var i = 0; i < 168; i += 3) {
        for (final (x, y) in [(i, 10), (i, 157), (10, i), (157, i)]) {
          expect(blackAt(bytes, width, x, y), isFalse, reason: '($x, $y)');
        }
      }
    });
  }

  testWidgets('has a semantic label', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpApp(
      const Center(
        child: QrCodeView(data: data, semanticLabel: 'QR code for the link'),
      ),
    );

    expect(
      tester.getSemantics(find.byType(QrCodeView)),
      matchesSemantics(label: 'QR code for the link', isImage: true),
    );
    expect(tester.getSize(find.byType(QrCodeView)), const Size.square(240));
    semantics.dispose();
  });

  testWidgets('repaints when the data changes', (tester) async {
    QrCodePainter painter() =>
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byType(QrCodeView),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as QrCodePainter;

    await tester.pumpApp(const QrCodeView(data: 'a', semanticLabel: 'QR'));
    final first = painter();
    await tester.pumpApp(const QrCodeView(data: 'a', semanticLabel: 'QR'));
    expect(painter().code, same(first.code));
    expect(painter().shouldRepaint(first), isFalse);

    await tester.pumpApp(
      const QrCodeView(
        data: 'a',
        semanticLabel: 'QR',
        errorCorrection: QrErrorCorrection.high,
      ),
    );
    expect(painter().code.errorCorrection, QrErrorCorrection.high);
    await tester.pumpApp(const QrCodeView(data: 'b', semanticLabel: 'QR'));
    expect(painter().shouldRepaint(first), isTrue);
  });

  testWidgets('falls back to low error correction for long text', (
    tester,
  ) async {
    await tester.pumpApp(QrCodeView(data: 'a' * 2500, semanticLabel: 'QR'));

    final painter =
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byType(QrCodeView),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as QrCodePainter;
    expect(painter.code.errorCorrection, QrErrorCorrection.low);
    expect(painter.code.version, 37);
  });

  testWidgets('draws at least one pixel per module', (tester) async {
    final (bytes, width) = await render(
      tester,
      const QrCodeView(data: data, semanticLabel: 'QR', size: 20),
    );

    expect(width, 20);
    // 41 modules do not fit 20 pixels: one pixel each, centred (module 17
    // of the symbol is in the middle, after 4 of quiet zone).
    final code = QrCode.encode(data);
    expect(blackAt(bytes, width, 10, 10), code.isDark(17, 17));
    expect(blackAt(bytes, width, 11, 10), code.isDark(18, 17));
  });
}
