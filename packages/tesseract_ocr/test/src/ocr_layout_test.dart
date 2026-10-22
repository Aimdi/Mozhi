import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tesseract_ocr/src/engine/ffi/native_engine.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

/// What `mozhi_tesseract_recognize_layout` returns for two paragraphs (the
/// second right-to-left, without colours or words).
const _json = r'''
{"text":"Opening hours\nMonday\n\nمخرج\n","confidence":91,
 "width":640,"height":300,
 "blocks":[
  {"box":[26,30,316,109],"confidence":96,"orientation":0,"vertical":false,
   "deskew":-1.5,
   "paragraphs":[
    {"box":[26,30,316,109],"confidence":96,"ltr":true,"align":"left",
     "background":16777215,"foreground":1644825,
     "lines":[
      {"box":[26,30,272,63],"confidence":97,"baseline":[26,56,272,60],
       "text":"Opening hours",
       "words":[{"box":[26,30,165,63],"confidence":96,"text":"Opening"},
                {"box":[181,30,272,56],"confidence":97,"text":"hours"}]},
      {"box":[27,76,157,109],"confidence":95,"text":"Monday","words":[]}]}]},
  {"box":[400,200,500,240],"confidence":80,"orientation":90,"vertical":true,
   "deskew":0.0,
   "paragraphs":[
    {"box":[400,200,500,240],"confidence":80,"ltr":false,"align":"middle",
     "lines":[{"box":[400,200,500,240],"confidence":80,"text":"مخرج"}]}]}]}
''';

void main() {
  group('OcrLayout', () {
    test('parses the engine JSON', () {
      final result = NativeTesseractEngine.parseLayoutResult(_json);
      expect(result.text, 'Opening hours\nMonday\n\nمخرج');
      expect(result.meanConfidence, 91);
      final layout = result.layout!;
      expect((layout.width, layout.height), (640, 300));
      expect(layout.isEmpty, isFalse);
      expect(layout.blocks, hasLength(2));

      final block = layout.blocks.first;
      expect(block.box, const OcrBox(26, 30, 316, 109));
      expect(block.box.width, 290);
      expect(block.box.height, 79);
      expect(block.confidence, 96);
      expect(block.orientation, 0);
      expect(block.isVertical, isFalse);
      expect(block.deskewAngle, -1.5);

      final paragraph = layout.paragraphs.first;
      expect(paragraph.text, 'Opening hours\nMonday');
      expect(paragraph.isLeftToRight, isTrue);
      expect(paragraph.alignment, OcrAlignment.left);
      expect(paragraph.background, 0xFFFFFF);
      expect(paragraph.foreground, 0x191919);
      final line = paragraph.lines.first;
      expect(line.baseline, (x1: 26, y1: 56, x2: 272, y2: 60));
      expect(line.angle, closeTo(0.93, 0.01));
      expect(line.words.map((word) => word.text), ['Opening', 'hours']);
      expect(line.words.first.confidence, 96);
      expect(paragraph.lines.last.angle, 0);

      final rtl = layout.paragraphs.last;
      expect(rtl.isLeftToRight, isFalse);
      expect(rtl.alignment, OcrAlignment.unknown);
      expect(rtl.background, isNull);
      expect(rtl.foreground, isNull);
      expect(rtl.lines.single.words, isEmpty);
      expect(layout.blocks.last.orientation, 90);
      expect(layout.blocks.last.isVertical, isTrue);
    });

    test('compares by value', () {
      final a = NativeTesseractEngine.parseLayoutResult(_json);
      final b = NativeTesseractEngine.parseLayoutResult(_json);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.layout!.blocks.first.hashCode, b.layout!.blocks.first.hashCode);
      expect(
        a.layout!.paragraphs.first.lines.first.words.first.hashCode,
        b.layout!.paragraphs.first.lines.first.words.first.hashCode,
      );
      expect(a.toString(), 'OcrResult(26 chars, 91%, 2 paragraphs)');
      expect(a.layout.toString(), 'OcrLayout(640x300, 2 blocks, 2 paragraphs)');
      expect(
        a.layout!.blocks.first.toString(),
        'OcrBlock(1 paragraphs, OcrBox(26, 30, 316, 109))',
      );
      expect(
        a.layout!.paragraphs.first.toString(),
        'OcrParagraph(2 lines, OcrBox(26, 30, 316, 109))',
      );
      expect(
        a.layout!.paragraphs.first.lines.first.toString(),
        'OcrLine(Opening hours, OcrBox(26, 30, 272, 63), 97%)',
      );
      expect(
        a.layout!.paragraphs.first.lines.first.words.first.toString(),
        'OcrWord(Opening, OcrBox(26, 30, 165, 63), 96%)',
      );

      final other = jsonDecode(_json) as Map<String, Object?>;
      (other['blocks']! as List).removeLast();
      final fewer = NativeTesseractEngine.parseLayoutResult(jsonEncode(other));
      expect(fewer, isNot(a));
      expect(fewer.layout!.blocks.first, a.layout!.blocks.first);
      expect(const OcrBox(0, 0, 1, 1), isNot(const OcrBox(0, 0, 1, 2)));
    });

    test('an empty page has no paragraphs', () {
      final result = NativeTesseractEngine.parseLayoutResult(
        '{"text":"","confidence":0,"width":64,"height":32,"blocks":[]}',
      );
      expect(result.text, isEmpty);
      expect(result.layout!.isEmpty, isTrue);
      expect(result.layout!.paragraphs, isEmpty);
      expect(
        const OcrLayout(
          width: 1,
          height: 1,
          blocks: [OcrBlock(box: OcrBox(0, 0, 1, 1), paragraphs: [])],
        ).isEmpty,
        isTrue,
      );
    });

    test('rejects anything else', () {
      const badBaseline =
          '{"text":"","blocks":[{"box":[0,0,1,1],"paragraphs":[{"box":[0,0,1,1],'
          '"lines":[{"box":[0,0,1,1],"text":"a","baseline":[1]}]}]}]}';
      for (final json in [
        'not json',
        '[]',
        '{"confidence":1}',
        '{"text":"","blocks":[{"box":[1,2,3]}]}',
        badBaseline,
      ]) {
        expect(
          () => NativeTesseractEngine.parseLayoutResult(json),
          throwsA(isA<TesseractEngineException>()),
          reason: json,
        );
      }
    });
  });
}
