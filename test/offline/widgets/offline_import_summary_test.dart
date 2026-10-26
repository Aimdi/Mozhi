import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:mozhi/platform/free_space.dart';

import '../../helpers/helpers.dart';

void main() {
  const german = OfflineLanguage(code: 'de', name: 'German');
  const english = OfflineLanguage(code: 'en', name: 'English');
  const french = OfflineLanguage(code: 'fr', name: 'French');

  /// "German → English" as the dialog writes it (bidi isolates).
  String direction(OfflineLanguage source, OfflineLanguage target) =>
      '\u2068${source.name}\u2069 → \u2068${target.name}\u2069';

  Future<void> pump(WidgetTester tester, OfflineImportOutcome outcome) =>
      tester.pumpApp(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => OfflineImportSummaryDialog(outcome: outcome),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );

  Future<void> open(WidgetTester tester, OfflineImportOutcome outcome) async {
    await pump(tester, outcome);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('offlineDirectionLabel', () {
    test('isolates both names', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(
        offlineDirectionLabel(l10n, german, english),
        direction(german, english),
      );
    });
  });

  group('OfflineImportSummaryDialog', () {
    testWidgets('lists what each direction did', (tester) async {
      await open(
        tester,
        const OfflineImportOutcome(
          entries: [
            OfflineImportEntry(
              source: german,
              target: english,
              status: OfflineImportStatus.installed,
            ),
            OfflineImportEntry(
              source: english,
              target: german,
              status: OfflineImportStatus.alreadyInstalled,
            ),
            OfflineImportEntry(
              source: french,
              target: english,
              status: OfflineImportStatus.incomplete,
              missingFiles: ['vocab.fren.spm.gz'],
            ),
            OfflineImportEntry(
              source: english,
              target: french,
              status: OfflineImportStatus.damaged,
              missingFiles: ['model.enfr.intgemm.alphas.bin.gz'],
            ),
          ],
          unmatchedFiles: ['notes.txt', 'photo.jpg'],
        ),
      );

      expect(find.text('Models imported'), findsOneWidget);
      expect(
        find.text('Installed ${direction(german, english)}'),
        findsOneWidget,
      );
      expect(
        find.text('${direction(english, german)} was already installed'),
        findsOneWidget,
      );
      expect(
        find.text('Missing 1 file for ${direction(french, english)}'),
        findsOneWidget,
      );
      expect(find.text('vocab.fren.spm.gz'), findsOneWidget);
      expect(
        find.text(
          'A file for ${direction(english, french)} is damaged (checksum '
          'mismatch)',
        ),
        findsOneWidget,
      );
      expect(find.text('model.enfr.intgemm.alphas.bin.gz'), findsOneWidget);
      expect(find.text('2 files didn’t match any model'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(
        find.text('Tap a language in the list to see the files it needs.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(OfflineImportSummaryDialog), findsNothing);
    });

    testWidgets('says when nothing was installed', (tester) async {
      await open(
        tester,
        const OfflineImportOutcome(
          entries: [
            OfflineImportEntry(
              source: french,
              target: english,
              status: OfflineImportStatus.incomplete,
              missingFiles: ['a.gz', 'b.gz'],
            ),
          ],
          unmatchedFiles: ['notes.txt'],
        ),
      );
      expect(find.text('Nothing was installed'), findsOneWidget);
      expect(
        find.text('Missing 2 files for ${direction(french, english)}'),
        findsOneWidget,
      );
      expect(find.text('1 file didn’t match any model'), findsOneWidget);
    });

    testWidgets('explains failed installs', (tester) async {
      await open(
        tester,
        const OfflineImportOutcome(
          entries: [
            OfflineImportEntry(
              source: german,
              target: english,
              status: OfflineImportStatus.failed,
              error: OfflineModelError(OfflineModelErrorKind.storage),
            ),
            OfflineImportEntry(
              source: english,
              target: german,
              status: OfflineImportStatus.failed,
            ),
          ],
        ),
      );
      expect(
        find.text(
          'Couldn’t save ${direction(german, english)}. Free up some storage '
          'and try again.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Couldn’t install ${direction(english, german)}'),
        findsOneWidget,
      );
      expect(
        find.text('Tap a language in the list to see the files it needs.'),
        findsNothing,
      );
    });

    testWidgets('says how much free space an install needed', (tester) async {
      await open(
        tester,
        const OfflineImportOutcome(
          entries: [
            OfflineImportEntry(
              source: german,
              target: english,
              status: OfflineImportStatus.failed,
              error: OfflineModelError(
                OfflineModelErrorKind.space,
                space: SpaceShortfall(
                  requiredBytes: 60 * 1024 * 1024,
                  availableBytes: 5 * 1024 * 1024,
                ),
              ),
            ),
          ],
        ),
      );
      expect(
        find.text(
          'Not enough free space for ${direction(german, english)}: needs '
          '60 MB, 5.0 MB free.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('reports an import that failed as a whole', (tester) async {
      await open(
        tester,
        const OfflineImportOutcome(
          error: OfflineModelError(OfflineModelErrorKind.unknown),
        ),
      );
      expect(find.text('Couldn’t import the files'), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsNothing);
    });
  });
}
