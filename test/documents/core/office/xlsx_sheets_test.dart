// XML fixtures are written as adjacent string literals.
// ignore_for_file: missing_whitespace_between_adjacent_strings, lines_longer_than_80_chars

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/office/office.dart';
import 'package:mozhi/documents/core/office/workbook_parts.dart';

import 'office_fixtures.dart';

const _s = 'application/vnd.openxmlformats-officedocument.spreadsheetml';
const _chartType =
    'application/vnd.openxmlformats-officedocument.drawingml.chart+xml';
const _cNs = 'http://schemas.openxmlformats.org/drawingml/2006/chart';
const _xmNs = 'http://schemas.microsoft.com/office/excel/2006/main';
const _x14Ns = 'http://schemas.microsoft.com/office/spreadsheetml/2009/9/main';
const _tcNs =
    'http://schemas.microsoft.com/office/spreadsheetml/2018/threadedcomments';

/// A workbook with [sheets] (names), each with the worksheet XML inside
/// `<worksheet>` from [worksheets] (by index), [definedNames], shared
/// [strings] and [extra] parts (name -> (content type, XML)).
Uint8List _workbook(
  List<String> sheets, {
  Map<int, String> worksheets = const {},
  String definedNames = '',
  List<String> strings = const ['<si><t>Hello</t></si>'],
  Map<String, (String, Object)> extra = const {},
}) {
  final overrides = {
    'xl/workbook.xml': '$_s.sheet.main+xml',
    'xl/sharedStrings.xml': '$_s.sharedStrings+xml',
    for (var i = 0; i < sheets.length; i++)
      'xl/worksheets/sheet${i + 1}.xml': '$_s.worksheet+xml',
    for (final MapEntry(:key, :value) in extra.entries)
      if (value.$1.isNotEmpty) key: value.$1,
  };
  return zipOf({
    '[Content_Types].xml':
        '$declaration<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '${[for (final MapEntry(:key, :value) in overrides.entries) '<Override PartName="/$key" ContentType="$value"/>'].join()}'
        '</Types>',
    'xl/workbook.xml':
        '$declaration<workbook xmlns="$sNs" xmlns:r="$rNs"><sheets>'
        '${[for (final (i, name) in sheets.indexed) '<sheet name="${name.replaceAll('&', '&amp;')}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}'
        '</sheets>'
        '${definedNames.isEmpty ? '' : '<definedNames>$definedNames</definedNames>'}'
        '<calcPr calcId="191029"/></workbook>',
    'xl/sharedStrings.xml':
        '$declaration<sst xmlns="$sNs" count="${strings.length}" '
        'uniqueCount="${strings.length}">${strings.join()}</sst>',
    for (var i = 0; i < sheets.length; i++)
      'xl/worksheets/sheet${i + 1}.xml':
          '$declaration<worksheet xmlns="$sNs" xmlns:r="$rNs" '
          'xmlns:x14="$_x14Ns" xmlns:xm="$_xmNs">'
          '${worksheets[i] ?? '<sheetData/>'}</worksheet>',
    for (final MapEntry(:key, :value) in extra.entries) key: value.$2,
  });
}

PackagedDocument _parse(Uint8List bytes) =>
    parsePackagedDocument(bytes, DocumentFormat.xlsx, targetLanguage: 'es');

/// Asserts that every entry of [output] but [changed] has the bytes it
/// has in [original].
void _expectUntouched(
  Uint8List original,
  Uint8List output,
  Set<String> changed,
) {
  final before = {
    for (final entry in entriesOf(original)) entry.name: entry.readBytes(),
  };
  for (final entry in entriesOf(output)) {
    if (changed.contains(entry.name)) {
      expect(entry.readBytes(), isNot(before[entry.name]), reason: entry.name);
    } else {
      expect(entry.readBytes(), before[entry.name], reason: entry.name);
    }
  }
}

void main() {
  group('XLSX sheet names', () {
    test('renames sheets and rewrites the formulas that refer to them', () {
      const chart =
          '$declaration<c:chartSpace xmlns:c="$_cNs" xmlns:a="$aNs"><c:chart>'
          '<c:title><c:tx><c:rich><a:bodyPr/><a:p><a:r><a:t>Sales by month</a:t>'
          '</a:r></a:p></c:rich></c:tx></c:title><c:plotArea><c:barChart><c:ser>'
          r"<c:tx><c:strRef><c:f>'Data 2024'!$B$1</c:f><c:strCache>"
          '<c:ptCount val="1"/><c:pt idx="0"><c:v>Revenue</c:v></c:pt>'
          '</c:strCache></c:strRef></c:tx><c:val><c:numRef><c:f>'
          "'Data 2024'!\$B\$2:\$B\$9</c:f><c:numCache><c:pt idx=\"0\"><c:v>4</c:v>"
          '</c:pt></c:numCache></c:numRef></c:val></c:ser></c:barChart>'
          '<c:valAx><c:title><c:tx><c:rich><a:bodyPr/><a:p><a:r><a:t>Amount</a:t>'
          '</a:r></a:p></c:rich></c:tx></c:title></c:valAx></c:plotArea></c:chart>'
          '</c:chartSpace>';
      final bytes = _workbook(
        ['Summary', 'Data 2024', 'Notes'],
        definedNames:
            '<definedName name="_xlnm.Print_Area" localSheetId="1">'
            r"'Data 2024'!$A$1:$B$9</definedName>"
            r'<definedName name="Total">Summary!$B$2</definedName>',
        worksheets: {
          0:
              '<sheetData><row r="1"><c r="A1"><f>SUM(&apos;Data 2024&apos;!B2:B9)'
              '+Notes!A1</f><v>3</v></c><c r="B1"><f>Summary!A1*2</f><v>6</v>'
              '</c></row></sheetData><hyperlinks><hyperlink ref="C1" '
              "location=\"'Data 2024'!A1\" display=\"Data\"/></hyperlinks>",
          1: '<sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row></sheetData>',
          2:
              '<sheetData/><dataValidations count="1"><dataValidation '
              r'type="list" sqref="A1"><formula1>Summary!$A$1:$A$3'
              '</formula1></dataValidation></dataValidations><extLst><ext '
              'uri="{CCE6A557-97BC-4b89-ADB6-D9C93CAAB3DF}"><x14:dataValidations '
              'count="1"><x14:dataValidation type="list"><x14:formula1><xm:f>'
              r'Notes!$B$1:$B$4</xm:f></x14:formula1><xm:sqref>B1</xm:sqref>'
              '</x14:dataValidation></x14:dataValidations></ext></extLst>',
        },
        extra: {'xl/charts/chart1.xml': (_chartType, chart)},
      );
      final document = _parse(bytes);
      expect(textsOf(document), [
        'Summary',
        'Data 2024',
        'Notes',
        'Hello',
        'Sales by month',
        'Amount',
      ]);
      expectRoundTrip(document, bytes, targetLanguage: 'es');

      final output = renderWith(document, {
        'Summary': 'Resumen',
        'Data 2024': 'Datos 2024',
        'Notes': 'Notas',
        'Sales by month': 'Ventas por mes',
      });
      final workbook = entryText(output, 'xl/workbook.xml');
      expect(
        workbook,
        contains('<sheet name="Resumen" sheetId="1" r:id="rId1"/>'),
      );
      expect(workbook, contains('<sheet name="Datos 2024" sheetId="2"'));
      expect(workbook, contains('<sheet name="Notas" sheetId="3"'));
      expect(
        workbook,
        contains(
          '<definedName name="_xlnm.Print_Area" localSheetId="1">'
          r"'Datos 2024'!$A$1:$B$9</definedName>"
          "<definedName name=\"Total\">'Resumen'!\$B\$2</definedName>",
        ),
      );
      expect(workbook, contains('<calcPr calcId="191029"/>'));

      final summary = entryText(output, 'xl/worksheets/sheet1.xml');
      expect(
        summary,
        contains("<f>SUM('Datos 2024'!B2:B9)+'Notas'!A1</f><v>3</v>"),
      );
      expect(summary, contains("<f>'Resumen'!A1*2</f>"));
      expect(
        summary,
        contains(
          '<hyperlink ref="C1" location="\'Datos 2024\'!A1" display="Data"/>',
        ),
      );
      final notes = entryText(output, 'xl/worksheets/sheet3.xml');
      expect(notes, contains(r"<formula1>'Resumen'!$A$1:$A$3</formula1>"));
      expect(notes, contains(r"<xm:f>'Notas'!$B$1:$B$4</xm:f>"));
      expect(notes, contains('<xm:sqref>B1</xm:sqref>'));

      final chartXml = entryText(output, 'xl/charts/chart1.xml');
      expect(chartXml, contains('<a:t>Ventas por mes</a:t>'));
      expect(chartXml, contains(r"<c:f>'Datos 2024'!$B$1</c:f>"));
      expect(chartXml, contains(r"<c:f>'Datos 2024'!$B$2:$B$9</c:f>"));
      // Cached data is a copy of the cells: never translated.
      expect(chartXml, contains('<c:v>Revenue</c:v>'));
      expect(chartXml, contains('<a:t>Amount</a:t>'));

      // The sheet without references and the strings stay byte for byte.
      _expectUntouched(bytes, output, {
        'xl/workbook.xml',
        'xl/worksheets/sheet1.xml',
        'xl/worksheets/sheet3.xml',
        'xl/charts/chart1.xml',
      });
    });

    test('only rewrites what refers to a renamed sheet', () {
      final bytes = _workbook(
        ['Summary', 'Data'],
        worksheets: {
          0: '<sheetData><row r="1"><c r="A1"><f>Data!A1</f></c></row></sheetData>',
        },
      );
      final document = _parse(bytes);
      // Only "Summary" is translated: the formula naming "Data" stays.
      final output = renderWith(document, {'Summary': 'Resumen'});
      expect(
        entryText(output, 'xl/workbook.xml'),
        contains(
          '<sheet name="Resumen" sheetId="1" r:id="rId1"/><sheet name="Data"',
        ),
      );
      _expectUntouched(bytes, output, {'xl/workbook.xml'});
    });

    test('keeps names that other parts refer to in ways it cannot rewrite', () {
      final bytes = _workbook(
        ['Plan', 'Budget', 'Pivot source', 'Links', 'Tax & fees'],
        worksheets: {
          0:
              '<sheetData><row r="1"><c r="A1"><f>INDIRECT("Budget!A1")</f>'
              '</c><c r="B1"><f>HYPERLINK("#Links!A1","Go")</f></c></row>'
              '</sheetData>',
          4:
              '<sheetData><row r="1"><c r="A1"><f>&apos;Tax &amp; fees&apos;!B1'
              '</f></c></row></sheetData>',
        },
        extra: {
          'xl/charts/chartEx1.xml': (
            'application/vnd.ms-office.chartex+xml',
            '<cx:chartSpace xmlns:cx="http://schemas.microsoft.com/office/'
                'drawing/2014/chartex"><cx:chartData><cx:data id="0">'
                r'<cx:numDim type="val"><cx:f>Plan!$A$1:$A$3</cx:f>'
                '</cx:numDim></cx:data></cx:chartData></cx:chartSpace>',
          ),
          'xl/pivotCache/pivotCacheDefinition1.xml': (
            '$_s.pivotCacheDefinition+xml',
            '<pivotCacheDefinition xmlns="$sNs"><cacheSource type="worksheet">'
                '<worksheetSource ref="A1:B3" sheet="Pivot&#x20;source"/>'
                '<!-- &#65; -->'
                '</cacheSource></pivotCacheDefinition>',
          ),
        },
      );
      final document = _parse(bytes);
      expect(textsOf(document), ['Plan', 'Tax & fees', 'Hello']);
      final output = renderWith(document, {
        'Plan': 'Plan anual',
        'Tax & fees': 'Impuestos y tasas',
      });
      final workbook = entryText(output, 'xl/workbook.xml');
      expect(workbook, contains('<sheet name="Plan anual"'));
      expect(workbook, contains('<sheet name="Budget"'));
      expect(workbook, contains('<sheet name="Pivot source"'));
      expect(workbook, contains('<sheet name="Links"'));
      expect(workbook, contains('<sheet name="Impuestos y tasas"'));
      expect(
        entryText(output, 'xl/charts/chartEx1.xml'),
        contains(r"<cx:f>'Plan anual'!$A$1:$A$3</cx:f>"),
      );
      expect(
        entryText(output, 'xl/worksheets/sheet5.xml'),
        contains("<f>'Impuestos y tasas'!B1</f>"),
      );
      expect(
        entryText(output, 'xl/worksheets/sheet1.xml'),
        entryText(bytes, 'xl/worksheets/sheet1.xml'),
      );
    });

    test('keeps every name of a workbook with macros or unreadable parts', () {
      final macros = _workbook(
        ['Plan'],
        extra: {
          'xl/vbaProject.bin': ('', Uint8List.fromList([1, 2, 3])),
        },
      );
      expect(textsOf(_parse(macros)), ['Hello']);

      final damaged = _workbook(
        ['Plan', 'Other'],
        worksheets: {0: '<sheetData><row><c><f>Other!A1</f></c>'},
      );
      expect(textsOf(_parse(damaged)), ['Hello']);

      final numbers = _workbook(['2024', '2025']);
      expect(textsOf(_parse(numbers)), ['Hello']);
    });

    test('writes valid and unique names', () {
      final bytes = _workbook(['One', 'Two', 'Data', 'Sheet', 'Old', 'Long']);
      final document = _parse(bytes);
      final output = renderWith(document, {
        'One': 'Uno',
        'Two': 'Uno',
        'Sheet': 'DATA',
        'Old': 'History',
        'Long': 'Q1/Q2: [draft]* ${'x' * 40}',
      });
      final workbook = entryText(output, 'xl/workbook.xml');
      expect(workbook, contains('<sheet name="Uno" sheetId="1"'));
      expect(workbook, contains('<sheet name="Uno (2)" sheetId="2"'));
      expect(workbook, contains('<sheet name="Data" sheetId="3"'));
      expect(workbook, contains('<sheet name="DATA (2)" sheetId="4"'));
      expect(workbook, contains('<sheet name="Old" sheetId="5"'));
      expect(
        workbook,
        contains('<sheet name="Q1-Q2- (draft) xxxxxxxxxxxxxxxx" sheetId="6"'),
      );
    });

    test('sheetNameFrom follows Excel rules', () {
      expect(SheetNames.sheetNameFrom("  'Résumé'  "), 'Résumé');
      expect(SheetNames.sheetNameFrom('a\tb\nc'), 'a b c');
      expect(SheetNames.sheetNameFrom('***'), isNull);
      expect(SheetNames.sheetNameFrom('history'), isNull);
      expect(SheetNames.sheetNameFrom('${'a' * 30}😀'), 'a' * 30);
      expect(SheetNames.sheetNameFrom('${'a' * 29}😀'), '${'a' * 29}😀');
    });
  });

  group('formula references', () {
    test('are found and rewritten, quoted', () {
      const formula =
          "SUM(Data!A1,'Data'!B2,\"Data!C3\",[1]Data!A1,Jan:Mar!A1,"
          "'It''s'!A1,Table1[[#This Row],[Data]],#REF!A1,'[Book.xlsx]Data'!A1,"
          r"data!$A$1,A1:B2,'Q1:Q2'!C1)";
      final scan = sheetReferences(formula);
      expect(
        [for (final reference in scan.references) reference.names],
        [
          ['Data'],
          ['Data'],
          ['Jan', 'Mar'],
          ["It's"],
          ['data'],
          ['Q1', 'Q2'],
        ],
      );
      expect(scan.literals, ['Data!C3']);
      expect(
        rewriteSheetReferences(formula, {
          'data': 'Datos',
          'jan': 'Ene',
          "it's": "Es's",
          'q2': 'T2',
        }),
        "SUM('Datos'!A1,'Datos'!B2,\"Data!C3\",[1]Data!A1,'Ene:Mar'!A1,"
        "'Es''s'!A1,Table1[[#This Row],[Data]],#REF!A1,'[Book.xlsx]Data'!A1,"
        r"'Datos'!$A$1,A1:B2,'Q1:T2'!C1)",
      );
      expect(rewriteSheetReferences(formula, {'other': 'X'}), isNull);
      expect(rewriteSheetReferences(formula, {}), isNull);
      expect(sheetReferences('"unterminated').literals, ['unterminated']);
    });
  });

  group('XLSX comments', () {
    test('legacy and threaded comments are translated, authors are not', () {
      const comments =
          '$declaration<comments xmlns="$sNs"><authors><author>Ana Diaz</author>'
          '</authors><commentList><comment ref="A1" authorId="0"><text><r><rPr>'
          '<b/><sz val="9"/></rPr><t>Ana Diaz:</t></r><r><rPr><sz val="9"/></rPr>'
          '<t xml:space="preserve">\nCheck this total</t></r></text></comment>'
          '<comment ref="B1" authorId="0"><text><t>Plain note</t></text>'
          '</comment></commentList></comments>';
      const threaded =
          '$declaration<ThreadedComments xmlns="$_tcNs"><threadedComment '
          'ref="A1" dT="2026-01-01T00:00:00.00" personId="{1}" id="{2}">'
          '<text>Is this final?\nPlease confirm.</text></threadedComment>'
          '<threadedComment ref="A1" personId="{1}" id="{3}" parentId="{2}">'
          '<text>@Ana Diaz yes</text><mentions><mention mentionpersonId="{1}" '
          'mentionId="{4}" startIndex="0" length="9"/></mentions>'
          '</threadedComment></ThreadedComments>';
      final bytes = _workbook(
        ['1'],
        extra: {
          'xl/comments1.xml': ('$_s.comments+xml', comments),
          'xl/threadedComments/threadedComment1.xml': (
            'application/vnd.ms-excel.threadedcomments+xml',
            threaded,
          ),
        },
      );
      final document = _parse(bytes);
      expect(textsOf(document), [
        'Hello',
        '⟨1⟩Ana Diaz:⟨2⟩\nCheck this total',
        'Plain note',
        'Is this final?\nPlease confirm.',
      ]);
      expectRoundTrip(document, bytes, targetLanguage: 'es');
      final output = renderWith(document, {
        '⟨1⟩Ana Diaz:⟨2⟩\nCheck this total':
            '⟨1⟩Ana Diaz:⟨2⟩\nRevisa este total',
        'Plain note': 'Nota',
        'Is this final?\nPlease confirm.': '¿Es definitivo?\nConfírmalo.',
      });
      final legacy = entryText(output, 'xl/comments1.xml');
      expect(legacy, contains('<authors><author>Ana Diaz</author></authors>'));
      expect(
        legacy,
        contains(
          '<r><rPr><b/><sz val="9"/></rPr><t xml:space="preserve">Ana Diaz:</t>'
          '</r><r><rPr><sz val="9"/></rPr><t xml:space="preserve">\n'
          'Revisa este total</t></r>',
        ),
      );
      expect(legacy, contains('<text><t xml:space="preserve">Nota</t></text>'));
      final threads = entryText(
        output,
        'xl/threadedComments/threadedComment1.xml',
      );
      expect(threads, contains('<text>¿Es definitivo?\nConfírmalo.</text>'));
      // Mentions point into the text: that reply is kept.
      expect(threads, contains('<text>@Ana Diaz yes</text>'));
    });
  });

  group('asynchronous parsing', () {
    test('gives the same document and output as parse and render', () async {
      final bytes = _workbook(
        ['Summary'],
        worksheets: {
          0: '<sheetData><row r="1"><c r="A1"><f>Summary!B1</f></c></row></sheetData>',
        },
      );
      final document = await OfficePackage.parseAsync(
        bytes,
        DocumentFormat.xlsx,
        targetLanguage: 'es',
      );
      final sync = OfficePackage.parse(
        bytes,
        DocumentFormat.xlsx,
        targetLanguage: 'es',
      );
      expect(textsOf(document), textsOf(sync));
      final translations = ['Resumen', 'Hola'];
      expect(
        await document.renderAsync(translations),
        sync.render(translations),
      );
      expect(await document.renderAsync(), bytes);
      await expectLater(
        OfficePackage.parseAsync(bytes, DocumentFormat.pdf),
        throwsArgumentError,
      );
    });
  });
}
