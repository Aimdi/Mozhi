import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/undo_snack_bar.dart';
import 'package:mozhi/l10n/l10n.dart';

import '../helpers/helpers.dart';

void main() {
  group('showUndoSnackBar', () {
    late int undos;

    setUp(() => undos = 0);

    Future<void> show(WidgetTester tester, String message) async {
      await tester.tap(find.text('Show $message'));
      await tester.pumpAndSettle();
    }

    Future<void> pump(WidgetTester tester) => tester.pumpApp(
      Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              for (final message in ['first', 'second'])
                TextButton(
                  onPressed: () => showUndoSnackBar(
                    context,
                    message: message,
                    onUndo: () => undos++,
                  ),
                  child: Text('Show $message'),
                ),
            ],
          ),
        ),
      ),
    );

    testWidgets('undoes with its action', (tester) async {
      await pump(tester);
      await show(tester, 'first');
      expect(find.text('first'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(undos, 1);
      expect(find.text('first'), findsNothing);
    });

    testWidgets('waits for the user and closes without undoing', (
      tester,
    ) async {
      await pump(tester);
      await show(tester, 'first');
      await tester.pump(const Duration(minutes: 5));
      expect(find.text('first'), findsOneWidget);

      final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snackBar.persist, isTrue);
      expect(snackBar.showCloseIcon, isTrue);
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('first'), findsNothing);
      expect(undos, 0);
    });

    testWidgets('replaces the current snack bar', (tester) async {
      await pump(tester);
      await show(tester, 'first');
      await show(tester, 'second');
      expect(find.text('first'), findsNothing);
      expect(find.text('second'), findsOneWidget);
    });

    testWidgets('does nothing without a scaffold messenger', (tester) async {
      await tester.pumpWidget(
        Localizations(
          locale: const Locale('en'),
          delegates: appLocalizationsDelegates,
          child: Builder(
            builder: (context) {
              showUndoSnackBar(context, message: 'first', onUndo: () {});
              return const SizedBox();
            },
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
