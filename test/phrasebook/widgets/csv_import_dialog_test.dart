import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/data/phrasebook_csv.dart';
import 'package:mozhi/phrasebook/data/collection_csv.dart';
import 'package:mozhi/phrasebook/widgets/csv_import_dialog.dart';

import '../pump.dart';

void main() {
  final table = PhrasebookCsv.parse(
    'Hello\tOlá\tgreeting\nThanks\tObrigado\t\nBeer\tCerveja\tbar\n',
  );

  Future<Future<CsvImportMapping?> Function()> open(WidgetTester tester) async {
    CsvImportMapping? result;
    var done = false;
    await tester.pumpPhrasebook(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<CsvImportMapping>(
                context: context,
                builder: (_) => CsvImportDialog(
                  fileName: 'words.tsv',
                  table: table,
                  initial: CsvImportMapping.suggest(
                    table,
                    sourceCode: 'en',
                    targetCode: 'pt',
                  ),
                ),
              );
              done = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
      size: const Size(600, 1400),
    );
    return () async => done ? result : null;
  }

  testWidgets('previews, maps the columns and the languages', (tester) async {
    final result = await open(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('words.tsv · 3 rows'), findsOneWidget);
    expect(find.text('Hello  →  Olá'), findsOneWidget);
    expect(find.text('Import 3 phrases'), findsOneWidget);

    // The header switch.
    await tester.tap(find.byKey(const Key('phrasebook_import_header')));
    await tester.pumpAndSettle();
    expect(find.text('Import 2 phrases'), findsOneWidget);
    await tester.tap(find.byKey(const Key('phrasebook_import_header')));
    await tester.pumpAndSettle();

    // The same column twice is refused.
    await tester.tap(
      find.byKey(const Key('phrasebook_import_translation_column')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Column 1: Hello').last);
    await tester.pumpAndSettle();
    expect(find.text('Choose two different columns.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('phrasebook_import_confirm')),
          )
          .onPressed,
      isNull,
    );
    // The third column as the translation.
    await tester.tap(
      find.byKey(const Key('phrasebook_import_translation_column')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Column 3: greeting').last);
    await tester.pumpAndSettle();
    expect(find.text('Import 2 phrases'), findsOneWidget);
    // And the phrase column.
    await tester.tap(find.byKey(const Key('phrasebook_import_text_column')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Column 2: Olá').last);
    await tester.pumpAndSettle();
    expect(find.text('Olá  →  greeting'), findsOneWidget);

    // The languages.
    await tester.tap(find.byKey(const Key('phrasebook_import_from')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'German');
    await tester.pumpAndSettle();
    await tester.tap(find.text('German').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('phrasebook_import_to')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'French');
    await tester.pumpAndSettle();
    await tester.tap(find.text('French').last);
    await tester.pumpAndSettle();
    expect(find.text('German'), findsOneWidget);
    expect(find.text('French'), findsOneWidget);

    await tester.tap(find.byKey(const Key('phrasebook_import_confirm')));
    await tester.pumpAndSettle();
    final mapping = await result();
    expect(mapping!.textColumn, 1);
    expect(mapping.translationColumn, 2);
    expect(mapping.sourceCode, 'de');
    expect(mapping.targetCode, 'fr');
  });

  testWidgets('cancelling imports nothing', (tester) async {
    final result = await open(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Dismissing a language picker keeps the language.
    await tester.tap(find.byKey(const Key('phrasebook_import_from')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('English'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result(), isNull);
  });
}
