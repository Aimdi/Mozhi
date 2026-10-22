// TEMPORARY (W3-C): visual check of the overlay with the real engine.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:tesseract_ocr/src/engine/ffi/isolate_engine.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

const _out =
    '/tmp/claude-0/-home-user-Mozhi/071da89e-592f-547c-b32a-54fb03071e39/scratchpad/w3c';

void main() {
  testWidgets('visual', (tester) async {
    await tester.runAsync(() async {
      final font = File(
        '/root/.pub-cache/hosted/pub.dev/provider-6.1.5+1/extension/devtools/build/assets/packages/devtools_app_shared/fonts/Roboto/Roboto-Regular.ttf',
      ).readAsBytesSync();
      await (FontLoader(
        'Roboto',
      )..addFont(Future.value(ByteData.sublistView(font)))).load();
      const width = 900;
      const height = 700;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawRect(
          const Rect.fromLTWH(0, 0, 900, 700),
          Paint()
            ..shader = ui.Gradient.linear(Offset.zero, const Offset(900, 700), [
              const Color(0xFF8D6E63),
              const Color(0xFF5D4037),
            ]),
        )
        ..drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(60, 50, 780, 300),
            const Radius.circular(20),
          ),
          Paint()..color = const Color(0xFF1B5E20),
        )
        ..drawRect(
          const Rect.fromLTWH(60, 400, 780, 260),
          Paint()..color = const Color(0xFFFFF8E1),
        );
      void text(String value, Offset at, double size, Color color) {
        final painter = TextPainter(
          text: TextSpan(
            text: value,
            style: TextStyle(
              fontFamily: 'Roboto',
              fontSize: size,
              color: color,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 740);
        painter.paint(canvas, at);
      }

      text('EXIT', const Offset(100, 80), 72, Colors.white);
      text(
        'Please keep this door closed at all times',
        const Offset(100, 200),
        34,
        Colors.white,
      );
      text('Opening hours', const Offset(100, 430), 44, Colors.black87);
      text(
        'Monday to Friday from 9 am to 6 pm. Closed on Sundays and holidays.',
        const Offset(100, 510),
        30,
        const Color(0xFFB71C1C),
      );
      final photo = await recorder.endRecording().toImage(width, height);
      final rgba = (await photo.toByteData())!.buffer.asUint8List();
      final png = (await photo.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      Directory(_out).createSync(recursive: true);
      File('$_out/photo.png').writeAsBytesSync(png);

      final engine = IsolateTesseractEngine(
        libraryPath: File(
          'packages/tesseract_ocr/build/native/linux/libmozhi_tesseract.so',
        ).absolute.path,
      );
      final result = await engine.recognize(
        OcrImage(rgba, width: width, height: height),
        dataPath: Directory('packages/tesseract_ocr/build/test_tessdata')
            .absolute
            .path,
        languages: const ['eng'],
        layout: true,
      );
      await engine.dispose();
      final layout = TesseractTextRecognitionService.textLayoutOf(
        result.layout,
      )!;
      final report = StringBuffer();
      for (final p in layout.paragraphs) {
        report.writeln(
          '${p.box} lines=${p.lineCount} align=${p.alignment} '
          'bg=${p.background} fg=${p.foreground} conf=${p.confidence}: '
          '${p.text}',
        );
      }
      final translations = [
        for (final p in layout.paragraphs)
          switch (p.text) {
            'EXIT' => 'AUSGANG',
            final t when t.startsWith('Please') =>
              'Bitte halten Sie diese Tür jederzeit geschlossen',
            'Opening hours' => 'Öffnungszeiten',
            _ =>
              'Montag bis Freitag von 9 bis 18 Uhr. An Sonn- und Feiertagen '
                  'geschlossen.',
          },
      ];
      final overlaid = await const UiOverlayImageRenderer().render(
        png,
        layout,
        translations,
        direction: TextDirection.ltr,
        locale: const Locale('de'),
        style: const TextStyle(
          fontFamily: 'Roboto',
          fontWeight: FontWeight.w500,
        ),
      );
      File('$_out/overlay.png').writeAsBytesSync(overlaid);
      File('$_out/layout.txt').writeAsStringSync('$report');
    });
  });
}
