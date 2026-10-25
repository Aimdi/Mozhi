import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/parsers/xliff_parser.dart';
import 'package:xml/xml.dart';

import '../helpers/document_helpers.dart';

void main() {
  group('parseXliff 1.2', () {
    const xliff12 =
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<xliff version="1.2" xmlns="urn:oasis:names:tc:xliff:document:1.2">\n'
        '  <file source-language="en" datatype="plaintext" original="app">\n'
        '    <header><note>Not this</note></header>\n'
        '    <body>\n'
        '      <trans-unit id="greeting">\n'
        '        <source>Hello <g id="1">dear</g> %1\$s &amp; friends!</source>\n'
        '        <note>A greeting</note>\n'
        '      </trans-unit>\n'
        '      <trans-unit id="done" approved="yes">\n'
        '        <source>Done</source>\n'
        '        <target>Fertig</target>\n'
        '      </trans-unit>\n'
        '      <trans-unit id="brand" translate="no">\n'
        '        <source>Mozhi</source>\n'
        '      </trans-unit>\n'
        '      <trans-unit id="empty">\n'
        '        <source>Save the file</source>\n'
        '        <target state="new"/>\n'
        '      </trans-unit>\n'
        '      <trans-unit id="code"><source>%d</source></trans-unit>\n'
        '    </body>\n'
        '  </file>\n'
        '</xliff>\n';

    test('round-trips and lists untranslated sources', () {
      final document = parseXliff(xliff12, targetLanguage: 'de');
      expect(document.format, DocumentFormat.xliff);
      expectRoundTrip(document, xliff12);
      expect(texts(document), [
        'Hello ⟨1⟩dear⟨2⟩ ⟨3⟩ & friends!',
        'Save the file',
      ]);
      expect(document.segments.first.label, 'greeting');
    });

    test('creates targets, escapes, and sets the target language', () {
      final document = parseXliff(xliff12, targetLanguage: 'de');
      final output = document.render([
        'Hallo ⟨1⟩liebe⟨2⟩ ⟨3⟩ & Freunde <3',
        'Datei speichern',
      ]);
      expect(
        output,
        contains(
          '<source>Hello <g id="1">dear</g> %1\$s &amp; friends!</source>\n'
          '        <target state="needs-review-translation">Hallo <g id="1">'
          'liebe</g> %1\$s &amp; Freunde &lt;3</target>\n'
          '        <note>',
        ),
      );
      expect(
        output,
        contains(
          '<target state="needs-review-translation">Datei speichern</target>',
        ),
      );
      expect(
        output,
        contains(
          '<file source-language="en" datatype="plaintext" '
          'original="app" target-language="de">',
        ),
      );
      expect(output, contains('<target>Fertig</target>'));
      expect(XmlDocument.parse(output), isNotNull);
    });

    test('repairs inline codes an engine reordered', () {
      final document = parseXliff(xliff12, targetLanguage: 'de');
      final output = document.render(['⟨2⟩Hallo⟨1⟩ ⟨3⟩ liebe Freunde']);
      expect(XmlDocument.parse(output), isNotNull);
      expect(output, contains('<target state="needs-review-translation">'));
    });
  });
  group('parseXliff 1.2 (more)', () {
    test('translates again when the file is for another language', () {
      const text =
          '<xliff version="1.2"><file source-language="en" '
          'target-language="de"><body>'
          '<trans-unit id="a"><source>Yes</source><target xml:lang="de" '
          'state="translated">Ja</target></trans-unit>'
          '<trans-unit id="b"><source>No</source><seg-source><mrk mtype="seg" '
          'mid="1">No</mrk></seg-source></trans-unit>'
          '</body></file></xliff>';
      final same = parseXliff(text, targetLanguage: 'de-DE');
      expect(texts(same), ['No']);
      final other = parseXliff(text, targetLanguage: 'fr');
      expectRoundTrip(other, text);
      expect(texts(other), ['Yes', 'No']);
      final output = other.render(['Oui', 'Non']);
      expect(
        output,
        contains(
          '<target xml:lang="fr" state="needs-review-translation">Oui</target>',
        ),
      );
      expect(
        output,
        contains(
          '</seg-source><target state="needs-review-translation">Non</target>',
        ),
      );
      expect(output, contains('target-language="fr"'));
      expect(XmlDocument.parse(output), isNotNull);
    });

    test('reads CDATA sources, protected markers and codes', () {
      const text =
          '<?xml version="1.0" encoding="ISO-8859-1"?>\r\n'
          '<xliff version="1.2"><file source-language="en"><body>\r\n'
          '  <trans-unit id="c"><source> <![CDATA[Hello <b>you</b> & me]]> '
          '</source></trans-unit>\r\n'
          '  <trans-unit id="d"><source>Press <x id="1"/> or <mrk '
          'mtype="protected">Ctrl</mrk><!-- key --> now <ph id="2">%s</ph>'
          '</source></trans-unit>\r\n'
          '  <group translate="no"><trans-unit id="e"><source>Skip me</source>'
          '</trans-unit></group>\r\n'
          '  <trans-unit id="f"><source>Old</source><target></target>'
          '<alt-trans><source>Old</source><target>Alt</target></alt-trans>'
          '</trans-unit>\r\n'
          '</body></file></xliff>\r\n';
      final document = parseXliff(text, targetLanguage: 'es');
      expectRoundTrip(document, text);
      expect(texts(document), [
        'Hello ⟨1⟩you⟨2⟩ & me',
        'Press ⟨1⟩ or ⟨2⟩⟨3⟩ now ⟨4⟩',
        'Old',
      ]);
      final output = document.render([
        'Hola ⟨1⟩tú⟨2⟩ ]]> yo',
        'Pulsa ⟨1⟩ o ⟨2⟩⟨3⟩ ahora ⟨4⟩',
        'Viejo',
      ]);
      expect(output, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(
        output,
        contains(
          '</source><target state="needs-review-translation"> <![CDATA[Hola '
          '<b>tú</b> ]]]]><![CDATA[> yo]]> </target>',
        ),
      );
      expect(
        output,
        contains(
          '>Pulsa <x id="1"/> o <mrk mtype="protected">Ctrl</mrk><!-- key --> '
          'ahora <ph id="2">%s</ph></target>',
        ),
      );
      expect(
        output,
        contains('<target state="needs-review-translation">Viejo</target>'),
      );
      expect(output, contains('<target>Alt</target>'));
      expect(XmlDocument.parse(output), isNotNull);
    });

    test('keeps ICU plural structure (Angular)', () {
      const text =
          '<xliff version="1.2"><file source-language="en"><body>'
          '<trans-unit id="minutes"><source>{VAR_PLURAL, plural, =0 {just now}'
          ' =1 {one minute ago} other {<x id="INTERPOLATION" '
          'equiv-text="{{minutes}}"/> minutes ago}}</source></trans-unit>'
          '<trans-unit id="sel"><source>{VAR_SELECT, select, male {He} other '
          '{They}} said {{name}} #1</source></trans-unit>'
          '<trans-unit id="broken"><source>{VAR_PLURAL, plural, other {open'
          '</source></trans-unit>'
          '</body></file></xliff>';
      final document = parseXliff(text, targetLanguage: 'de');
      expectRoundTrip(document, text);
      expect(texts(document), [
        'just now',
        'one minute ago',
        '⟨1⟩ minutes ago',
        'He',
        'They',
        '⟨1⟩ said ⟨2⟩ #1',
        '{VAR_PLURAL, plural, other {open',
      ]);
      final output = document.render([
        'gerade eben',
        'vor einer Minute',
        'vor ⟨1⟩ Minuten',
        'Er',
        'Sie',
        '⟨1⟩ sagten ⟨2⟩ #1',
        null,
      ]);
      expect(
        output,
        contains(
          '<target state="needs-review-translation">{VAR_PLURAL, plural, '
          '=0 {gerade eben} =1 {vor einer Minute} other {vor <x '
          'id="INTERPOLATION" equiv-text="{{minutes}}"/> Minuten}}</target>',
        ),
      );
      expect(
        output,
        contains(
          '>{VAR_SELECT, select, male {Er} other {Sie}} sagten {{name}} #1<',
        ),
      );
    });

    test('rejects other documents', () {
      expect(
        () => parseXliff('<resources/>'),
        throwsA(isA<DocumentParseException>()),
      );
      expect(
        () => parseXliff('<xliff><file>'),
        throwsA(
          isA<DocumentParseException>().having(
            (error) => error.message,
            'message',
            startsWith('XLIFF:'),
          ),
        ),
      );
    });
  });

  group('parseXliff 2.x', () {
    const xliff20 = '''
<?xml version="1.0" encoding="UTF-8"?>
<xliff xmlns="urn:oasis:names:tc:xliff:document:2.0" version="2.0" srcLang="en">
  <file id="f1">
    <notes><note>Not this</note></notes>
    <unit id="u1">
      <segment id="s1">
        <source>Click <pc id="1">here</pc> to <ph id="2"/> continue.</source>
      </segment>
      <ignorable><source> </source></ignorable>
      <segment id="s2" state="initial">
        <source>Second <mrk id="m1" translate="no">Mozhi</mrk> sentence.</source>
        <target>Second Mozhi sentence.</target>
      </segment>
    </unit>
    <unit id="u2" translate="no">
      <segment><source>Not translated</source></segment>
    </unit>
    <unit id="u3">
      <segment state="final">
        <source>Done</source>
        <target>Fertig</target>
      </segment>
    </unit>
  </file>
</xliff>
''';

    test('round-trips and lists segments', () {
      final document = parseXliff(xliff20, targetLanguage: 'de');
      expectRoundTrip(document, xliff20);
      expect(texts(document), [
        'Click ⟨1⟩here⟨2⟩ to ⟨3⟩ continue.',
        'Second ⟨1⟩ sentence.',
      ]);
      expect(document.segments.first.label, 'u1/s1');
    });

    test('adds targets, marks segments translated and sets trgLang', () {
      final document = parseXliff(xliff20, targetLanguage: 'de');
      final output = document.render([
        'Klicken Sie ⟨1⟩hier⟨2⟩, um ⟨3⟩ fortzufahren.',
        'Zweiter ⟨1⟩ Satz.',
      ]);
      expect(
        output,
        contains(
          '<segment id="s1" state="translated">\n'
          '        <source>Click <pc id="1">here</pc> to <ph id="2"/> '
          'continue.</source>\n'
          '        <target>Klicken Sie <pc id="1">hier</pc>, um <ph id="2"/> '
          'fortzufahren.</target>\n'
          '      </segment>',
        ),
      );
      expect(
        output,
        contains(
          '<segment id="s2" state="translated">\n'
          '        <source>Second <mrk id="m1" translate="no">Mozhi</mrk> '
          'sentence.</source>\n'
          '        <target>Zweiter <mrk id="m1" translate="no">Mozhi</mrk> '
          'Satz.</target>',
        ),
      );
      expect(output, contains('version="2.0" srcLang="en" trgLang="de">'));
      expect(output, contains('<target>Fertig</target>'));
      expect(XmlDocument.parse(output), isNotNull);

      // Without a target language nothing names it.
      final plain = parseXliff(xliff20)
          .render(['Klicken ⟨1⟩hier⟨2⟩ ⟨3⟩.', 'Zweiter ⟨1⟩ Satz.']);
      expect(plain, isNot(contains('trgLang')));
    });

    test('translates again for another trgLang', () {
      const text =
          '<xliff xmlns="urn:oasis:names:tc:xliff:document:2.0" version="2.1" '
          'srcLang="en" trgLang="de"><file id="f"><unit id="u"><segment>'
          '<source>Yes</source><target>Ja</target></segment></unit></file>'
          '</xliff>';
      expect(parseXliff(text, targetLanguage: 'de').isEmpty, isTrue);
      final document = parseXliff(text, targetLanguage: 'it');
      final output = document.render(['Sì']);
      expect(
        output,
        contains(
          '<segment state="translated"><source>Yes</source>'
          '<target>Sì</target></segment>',
        ),
      );
      expect(output, contains('trgLang="it"'));
    });
  });

  test('keeps prefixes, CRLF indentation and mixed CDATA', () {
    const text =
        '<x:xliff xmlns:x="urn:oasis:names:tc:xliff:document:1.2" '
        'version="1.2"><x:file><x:body><x:trans-unit id="1">\r\n'
        '  <x:source>Hello <![CDATA[<raw>]]> there</x:source>\r\n'
        '</x:trans-unit></x:body></x:file></x:xliff>';
    final document = parseXliff(text);
    expectRoundTrip(document, text);
    expect(texts(document), ['Hello ⟨1⟩ there']);
    expect(
      document.render(['Hallo ⟨1⟩ da']),
      contains(
        '</x:source>\r\n  <x:target state="needs-review-translation">Hallo '
        '<![CDATA[<raw>]]> da</x:target>\r\n',
      ),
    );

    const v2 =
        '<x:xliff xmlns:x="urn:oasis:names:tc:xliff:document:2.0" '
        'version="2.0"><x:file id="f"><x:unit id="u"><x:segment>\n'
        '  <x:source>Bye</x:source></x:segment></x:unit></x:file></x:xliff>';
    expect(
      parseXliff(v2).render(['Tschüss']),
      contains('</x:source>\n  <x:target>Tschüss</x:target>'),
    );
  });
}
