import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/image_translate.dart';

TextParagraph _paragraph(String text, {double top = 0, int lines = 1}) =>
    TextParagraph(
      text: text,
      box: Rect.fromLTWH(10, top, 200, 30.0 * lines),
      lineCount: lines,
    );

void main() {
  group('TextParagraph.joinLines', () {
    test('joins wrapped lines into running text', () {
      expect(
        TextParagraph.joinLines(['Bitte klingeln Sie', ' an der Tür ', '']),
        'Bitte klingeln Sie an der Tür',
      );
      expect(TextParagraph.joinLines(const []), isEmpty);
    });

    test('joins a word hyphenated at the line end', () {
      expect(
        TextParagraph.joinLines(['Die Öffnungs-', 'zeiten gelten']),
        'Die Öffnungszeiten gelten',
      );
      // A capital after the hyphen is a compound ("Nord-Süd"): kept.
      expect(TextParagraph.joinLines(['Nord-', 'Süd-Bahn']), 'Nord- Süd-Bahn');
    });

    test('joins Chinese, Japanese and Thai lines without a space', () {
      expect(TextParagraph.joinLines(['营业时间', '周一至周五']), '营业时间周一至周五');
      expect(TextParagraph.joinLines(['出口は', 'こちら']), '出口はこちら');
      expect(TextParagraph.joinLines(['ทาง', 'ออก']), 'ทางออก');
      expect(TextParagraph.joinLines(['出口', 'Exit']), '出口 Exit');
    });

    test('keeps the break after a sentence and before a list item', () {
      expect(
        TextParagraph.joinLines(['Geöffnet:', 'Mo–Fr 9–18 Uhr.', 'Sa zu']),
        'Geöffnet:\nMo–Fr 9–18 Uhr.\nSa zu',
      );
      expect(
        TextParagraph.joinLines(['Zutaten', '• Mehl', '- Zucker', '2) Salz']),
        'Zutaten\n• Mehl\n- Zucker\n2) Salz',
      );
      expect(TextParagraph.joinLines(['»Halt!«', 'Weiter']), '»Halt!«\nWeiter');
    });
  });

  group('TextParagraph', () {
    test('has a line pitch, a copy with another text and value equality', () {
      const paragraph = TextParagraph(
        text: 'Ausgang',
        box: Rect.fromLTWH(0, 0, 100, 60),
        lineCount: 2,
        alignment: TextParagraphAlignment.center,
        isRightToLeft: true,
        background: Color(0xFFFFFFFF),
        foreground: Color(0xFF000000),
        confidence: 90,
      );
      expect(paragraph.linePitch, 30);
      expect(
        const TextParagraph(
          text: 'x',
          box: Rect.fromLTWH(0, 0, 1, 12),
          lineCount: 0,
        ).linePitch,
        12,
      );
      final copy = paragraph.withText('Exit');
      expect(copy.text, 'Exit');
      expect(copy.withText('Ausgang'), paragraph);
      expect(copy.withText('Ausgang').hashCode, paragraph.hashCode);
      expect(copy, isNot(paragraph));
      expect(paragraph.toString(), contains('Ausgang'));
    });
  });

  group('TextLayout', () {
    final layout = TextLayout(
      width: 400,
      height: 300,
      paragraphs: [
        _paragraph('Öffnungszeiten'),
        _paragraph('Montag bis Freitag von 9 bis 18 Uhr', top: 40, lines: 2),
        _paragraph('Kasse', top: 120),
      ],
    );

    test('joins its paragraphs with blank lines', () {
      expect(
        layout.text,
        'Öffnungszeiten\n\nMontag bis Freitag von 9 bis 18 Uhr\n\nKasse',
      );
      expect(layout.isEmpty, isFalse);
      expect(
        const TextLayout(width: 1, height: 1, paragraphs: []).isEmpty,
        isTrue,
      );
      expect(layout.toString(), 'TextLayout(400x300, 3 paragraphs)');
    });

    test('splits text back at blank lines', () {
      expect(TextLayout.splitParagraphs('a\n\nb\n \n\n c \n\n\n'), [
        'a',
        'b',
        'c',
      ]);
      expect(TextLayout.splitParagraphs('one\ntwo'), ['one\ntwo']);
      expect(TextLayout.splitParagraphs('  '), isEmpty);
    });

    test('takes edited text with as many paragraphs', () {
      final edited = layout.withText('Öffnungszeit\n\nMo bis Fr\n\nKassa')!;
      expect(edited.paragraphs.map((p) => p.text), [
        'Öffnungszeit',
        'Mo bis Fr',
        'Kassa',
      ]);
      expect(edited.paragraphs[1].box, layout.paragraphs[1].box);
      expect(layout.withText('Öffnungszeiten\n\nKasse'), isNull);
      expect(layout.withText(''), isNull);
      expect(edited, isNot(layout));
      expect(layout.withText(layout.text), layout);
      expect(layout.withText(layout.text).hashCode, layout.hashCode);
    });

    group('alignTranslation', () {
      test('maps parts one to one when the count survived', () {
        expect(
          layout.alignTranslation(
            'Opening hours\n\nMonday to Friday from 9 to 6\n\nCash desk\n',
          ),
          ['Opening hours', 'Monday to Friday from 9 to 6', 'Cash desk'],
        );
      });

      test('spreads merged paragraphs by their lines or sentences', () {
        expect(
          layout.alignTranslation(
            'Opening hours\nMonday to Friday from 9 to 6\nCash desk',
          ),
          ['Opening hours', 'Monday to Friday from 9 to 6', 'Cash desk'],
        );
        expect(
          layout.alignTranslation(
            'Opening hours. Monday to Friday from 9 to 6. Cash desk.',
          ),
          ['Opening hours.', 'Monday to Friday from 9 to 6.', 'Cash desk.'],
        );
      });

      test('merges split paragraphs', () {
        expect(
          layout.alignTranslation(
            'Opening hours\n\nMonday to Friday\n\nfrom 9 to 6\n\nCash desk',
          ),
          ['Opening hours', 'Monday to Friday from 9 to 6', 'Cash desk'],
        );
      });

      test('leaves paragraphs without a part empty', () {
        final aligned = layout.alignTranslation('Everything at once');
        expect(aligned, hasLength(3));
        expect(aligned.where((part) => part.isNotEmpty), [
          'Everything at once',
        ]);
      });

      test('one paragraph takes the whole translation', () {
        final single = TextLayout(
          width: 1,
          height: 1,
          paragraphs: [_paragraph('Ausgang')],
        );
        expect(single.alignTranslation('Exit\n\nWay out'), ['Exit\nWay out']);
        expect(
          const TextLayout(
            width: 1,
            height: 1,
            paragraphs: [],
          ).alignTranslation('x'),
          isEmpty,
        );
      });
    });
  });

  group('ImageTranslation overlay', () {
    final layout = TextLayout(
      width: 10,
      height: 10,
      paragraphs: [_paragraph('Ausgang'), _paragraph('Kasse', top: 40)],
    );

    test('needs a layout with a translation per paragraph', () {
      expect(const ImageTranslation().hasOverlay, isFalse);
      expect(ImageTranslation(layout: layout).hasOverlay, isFalse);
      expect(
        ImageTranslation(
          layout: layout,
          translatedParagraphs: const ['', ''],
        ).hasOverlay,
        isFalse,
      );
      final translated = ImageTranslation(
        layout: layout,
        translatedParagraphs: const ['Exit', ''],
      );
      expect(translated.hasOverlay, isTrue);
      expect(
        ImageTranslation(
          layout: layout,
          translatedParagraphs: const ['Exit'],
        ).hasOverlay,
        isFalse,
      );
      expect(
        ImageTranslation(
          translatedImage: Uint8List(1),
          layout: layout,
          translatedParagraphs: const ['Exit', 'Till'],
        ).hasOverlay,
        isFalse,
      );
    });

    test('copies and compares the layout and the paragraphs', () {
      final translation = ImageTranslation(sourceText: 'x', layout: layout);
      final copy = translation.copyWith(
        translatedParagraphs: const ['Exit', 'Till'],
      );
      expect(copy.layout, layout);
      expect(copy.translatedParagraphs, ['Exit', 'Till']);
      expect(copy.copyWith(isComplete: false).translatedParagraphs, [
        'Exit',
        'Till',
      ]);
      expect(copy, isNot(translation));
      expect(
        copy,
        ImageTranslation(
          sourceText: 'x',
          layout: layout,
          translatedParagraphs: const ['Exit', 'Till'],
        ),
      );
      expect(
        copy.hashCode,
        ImageTranslation(
          sourceText: 'x',
          layout: layout,
          translatedParagraphs: const ['Exit', 'Till'],
        ).hashCode,
      );
    });
  });

  test('TextWithConfidence compares the layout too', () {
    final layout = TextLayout(
      width: 1,
      height: 1,
      paragraphs: [_paragraph('a')],
    );
    expect(
      TextWithConfidence('a', layout: layout),
      TextWithConfidence('a', layout: layout),
    );
    expect(
      TextWithConfidence('a', layout: layout).hashCode,
      TextWithConfidence('a', layout: layout).hashCode,
    );
    expect(
      const TextWithConfidence('a'),
      isNot(TextWithConfidence('a', layout: layout)),
    );
  });
}
