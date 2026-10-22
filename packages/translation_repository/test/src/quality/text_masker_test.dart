import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group(TextMasker, () {
    group('find', () {
      test('returns the spans of every non-empty match', () {
        expect(TextMasker.find('a1b22', RegExp(r'\d*')), const [
          ProtectedSpan(1, 2),
          ProtectedSpan(3, 5),
        ]);
      });

      test('formatSpans finds tags, entities, URLs, e-mails, placeholders', () {
        const text =
            r'<b>Hi</b> {name}, see https://x.com &amp; a@b.de %s {{n}} ${v}';
        final values = [
          for (final span in TextMasker.formatSpans(text))
            text.substring(span.start, span.end),
        ];
        expect(values, [
          '<b>',
          '</b>',
          '{name}',
          'https://x.com',
          '&amp;',
          'a@b.de',
          '%s',
          '{{n}}',
          r'${v}',
        ]);
        expect(TextMasker.formatSpans(''), isEmpty);
      });

      test('formatSpans leaves percentages and ICU messages alone', () {
        expect(TextMasker.formatSpans('100% done, 50%off'), isEmpty);
        expect(TextMasker.formatSpans('{count, plural, one{# item}}'), isEmpty);
      });
    });

    group('merge', () {
      test('sorts, drops empty spans and joins overlaps', () {
        expect(
          TextMasker.merge(const [
            ProtectedSpan(5, 8),
            ProtectedSpan(0, 3),
            ProtectedSpan(2, 4),
            ProtectedSpan(9, 9),
          ]),
          const [ProtectedSpan(0, 4), ProtectedSpan(5, 8)],
        );
      });

      test('keeps a span personal when an overlapping one is', () {
        expect(
          TextMasker.merge(const [
            ProtectedSpan(0, 10),
            ProtectedSpan(4, 6, kind: ProtectedKind.personal),
          ]),
          const [ProtectedSpan(0, 10, kind: ProtectedKind.personal)],
        );
      });
    });

    group('mask', () {
      test('replaces spans by numbered tokens', () {
        final masked = TextMasker.mask('Mail a@b.de or see <b>x</b>', const [
          ProtectedSpan(5, 11, kind: ProtectedKind.personal),
          ProtectedSpan(19, 22),
          ProtectedSpan(23, 27),
        ]);
        expect(masked.text, 'Mail ⟨1⟩ or see ⟨2⟩x⟨3⟩');
        expect(masked.values, ['a@b.de', '<b>', '</b>']);
        expect(masked.count, 3);
        expect(masked.personalCount, 1);
        expect(masked.formatCount, 2);
        expect(masked.isEmpty, isFalse);
        expect(masked.original, 'Mail a@b.de or see <b>x</b>');
      });

      test('gives identical values of a kind one token', () {
        const text = 'a@b.de, a@b.de';
        final masked = TextMasker.mask(text, [
          ...TextMasker.find(
            text,
            RegExp('a@b.de'),
            kind: ProtectedKind.personal,
          ),
        ]);
        expect(masked.text, '⟨1⟩, ⟨1⟩');
        expect(masked.personalCount, 1);
      });

      test('numbers above the tokens the text already has', () {
        const text = 'Keep ⟨3⟩ and <x i="7"/>, mask {name}';
        final masked = TextMasker.mask(text, const [ProtectedSpan(30, 36)]);
        expect(masked.first, 8);
        expect(masked.text, 'Keep ⟨3⟩ and <x i="7"/>, mask ⟨8⟩');
        expect(masked.restore('⟨3⟩ ⟨8⟩').text, '⟨3⟩ {name}');
        expect(masked.valueOf(7), isNull);
        expect(masked.valueOf(9), isNull);
      });

      test('numbers past 9999 are restored', () {
        const text = 'Ref ⟨9999⟩: mail bob@example.com';
        final masked = TextMasker.mask(text, PersonalData.find(text));
        expect(masked.text, 'Ref ⟨9999⟩: mail ⟨10000⟩');
        final restored = masked.restore('Réf ⟨9999⟩ : écrire à ⟨10000⟩');
        expect(restored.text, 'Réf ⟨9999⟩ : écrire à bob@example.com');
        expect(restored.isComplete, isTrue);
        expect(restored.lostPersonalData, isFalse);
        final xml = TextMasker.mask(text, const [
          ProtectedSpan(17, 32, kind: ProtectedKind.personal),
        ], style: MaskStyle.xml);
        expect(xml.text, 'Ref ⟨9999⟩: mail <x i="10000"/>');
        expect(
          xml.restore('Ref ⟨9999⟩: <x i="10000"></x>').text,
          'Ref ⟨9999⟩: bob@example.com',
        );
      });

      test('take free low numbers when the text uses the highest', () {
        const text = 'Ref ⟨999999⟩ and ⟨1⟩: mail bob@example.com, eve@x.org';
        final masked = TextMasker.mask(text, PersonalData.find(text));
        expect(TextMasker.maxTokenNumber, 999999);
        expect(masked.first, 2);
        expect(masked.text, 'Ref ⟨999999⟩ and ⟨1⟩: mail ⟨2⟩, ⟨3⟩');
        final restored = masked.restore(masked.text);
        expect(restored.text, text);
        expect(restored.isComplete, isTrue);
        // Seven digits are no token.
        expect(
          TextMasker.mask('⟨1234567⟩ x', const [ProtectedSpan(10, 11)]).text,
          '⟨1234567⟩ ⟨1⟩',
        );
      });

      test('without spans leaves the text alone', () {
        final masked = TextMasker.mask('plain', const []);
        expect(masked.text, 'plain');
        expect(masked.isEmpty, isTrue);
        final restored = masked.restore('⟨1⟩ out');
        expect(restored.text, '⟨1⟩ out');
        expect(restored.isComplete, isTrue);
      });

      test('xml escapes the text between the tokens', () {
        final masked = TextMasker.mask('A & B <c> {x}', const [
          ProtectedSpan(10, 13),
        ], style: MaskStyle.xml);
        expect(masked.text, 'A &amp; B &lt;c&gt; <x i="1"/>');
        expect(
          TextMasker.mask('a<b', const [], style: MaskStyle.xml).text,
          'a&lt;b',
        );
      });
    });

    group('restore', () {
      final masked = TextMasker.mask('Write a@b.de or c@d.de, {name}', const [
        ProtectedSpan(6, 12, kind: ProtectedKind.personal),
        ProtectedSpan(16, 22, kind: ProtectedKind.personal),
        ProtectedSpan(24, 30),
      ]);

      test('puts every token back', () {
        final restored = masked.restore('Schreib ⟨1⟩ oder ⟨2⟩, ⟨3⟩');
        expect(restored.text, 'Schreib a@b.de oder c@d.de, {name}');
        expect(restored.isComplete, isTrue);
        expect(restored.lostPersonalData, isFalse);
      });

      test('restores tokens the engine moved or repeated', () {
        final restored = masked.restore('⟨3⟩: ⟨2⟩ ⟨1⟩ ⟨1⟩');
        expect(restored.text, '{name}: c@d.de a@b.de a@b.de');
        expect(restored.isComplete, isTrue);
      });

      test('tolerates spaces and CJK angle brackets', () {
        expect(masked.restore('〈 1 〉 ⟨2 ⟩ ⟨ 3⟩').text, 'a@b.de c@d.de {name}');
      });

      test('reports missing tokens', () {
        final restored = masked.restore('⟨1⟩ ⟨3⟩');
        expect(restored.missing, {1});
        expect(restored.isComplete, isFalse);
        expect(restored.lostPersonalData, isTrue);
        final format = masked.restore('⟨1⟩ ⟨2⟩');
        expect(format.missing, {2});
        expect(format.lostPersonalData, isFalse);
      });

      test('never rescans a restored value', () {
        final tricky = TextMasker.mask('x ⟨2⟩ y', const [ProtectedSpan(2, 5)]);
        // The text's own ⟨2⟩ is masked as token 3; its value looks like a
        // token but is put back as it is.
        expect(tricky.text, 'x ⟨3⟩ y');
        expect(tricky.restore('⟨3⟩').text, '⟨2⟩');
      });

      test('leaves unknown token numbers alone', () {
        expect(
          masked.restore('⟨9⟩ ⟨1⟩ ⟨2⟩ ⟨3⟩').text,
          '⟨9⟩ a@b.de c@d.de {name}',
        );
      });

      test('xml: puts tokens back and unescapes in one pass', () {
        final xml = TextMasker.mask('A & B {x} &amp;', const [
          ProtectedSpan(6, 9),
          ProtectedSpan(10, 15),
        ], style: MaskStyle.xml);
        expect(xml.text, 'A &amp; B <x i="1"/> <x i="2"/>');
        final restored = xml.restore(
          "&lt;A&gt; &amp; B <x i='1'></x> <x  i = \"2\" /> &quot;&apos;"
          ' &#65;&#x42;&#xD800;&#99999999;',
        );
        expect(restored.text, '<A> & B {x} &amp; "\' AB&#xD800;&#99999999;');
        expect(restored.isComplete, isTrue);
        expect(xml.restore('A B').missing, {0, 1});
      });
    });
  });

  group(ProtectedSpan, () {
    test('has value equality and a readable toString', () {
      expect(const ProtectedSpan(1, 2), const ProtectedSpan(1, 2));
      expect(
        const ProtectedSpan(1, 2).hashCode,
        const ProtectedSpan(1, 2).hashCode,
      );
      expect(
        const ProtectedSpan(1, 2),
        isNot(const ProtectedSpan(1, 2, kind: ProtectedKind.personal)),
      );
      expect(
        const ProtectedSpan(1, 2, kind: ProtectedKind.personal).isPersonal,
        isTrue,
      );
      expect(
        const ProtectedSpan(1, 2).toString(),
        'ProtectedSpan(1-2, format)',
      );
    });

    group('glossary spans', () {
      const term = ProtectedSpan(
        4,
        8,
        kind: ProtectedKind.glossary,
        replacement: 'house',
      );

      test('are dropped where they overlap other spans', () {
        expect(
          TextMasker.merge(const [
            ProtectedSpan(0, 6),
            ProtectedSpan(4, 9, kind: ProtectedKind.glossary, replacement: 'x'),
          ]),
          const [ProtectedSpan(0, 6)],
        );
        expect(
          TextMasker.merge(const [
            term,
            ProtectedSpan(6, 12, kind: ProtectedKind.personal),
          ]),
          const [ProtectedSpan(6, 12, kind: ProtectedKind.personal)],
        );
        expect(
          TextMasker.merge(const [
            term,
            ProtectedSpan(5, 7, kind: ProtectedKind.glossary, replacement: 'y'),
          ]),
          const [term],
        );
      });

      test('are masked and restored as their rendering', () {
        const text = 'Ein Haus, ein Hauses';
        final masked = TextMasker.mask(text, const [
          term,
          ProtectedSpan(
            14,
            20,
            kind: ProtectedKind.glossary,
            replacement: 'house',
          ),
        ]);
        expect(masked.text, 'Ein ⟨1⟩, ein ⟨1⟩');
        expect(masked.values, ['house']);
        expect(masked.originals, ['Haus']);
        expect(masked.glossaryCount, 1);
        expect(masked.formatCount, 0);
        expect(masked.personalCount, 0);
        expect(masked.restore('A ⟨1⟩, a ⟨1⟩').text, 'A house, a house');
        expect(masked.restore('a ⟨1⟩', original: true).text, 'a Haus');
        expect(masked.restore('A house').missing, {0});
      });

      test('start with a capital at the start of a sentence', () {
        final masked = TextMasker.mask('Haus. Ein Haus', const [
          ProtectedSpan(
            0,
            4,
            kind: ProtectedKind.glossary,
            replacement: 'house',
          ),
          ProtectedSpan(
            10,
            14,
            kind: ProtectedKind.glossary,
            replacement: 'iPhone',
          ),
        ]);
        expect(
          masked.restore('⟨1⟩ is big. A ⟨1⟩!\n"⟨1⟩" ⟨2⟩. ⟨2⟩').text,
          'House is big. A house!\n"House" iPhone. iPhone',
        );
      });
    });
  });
}
