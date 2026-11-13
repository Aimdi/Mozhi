import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

/// The Translate screen's sheets open on the root navigator: above the
/// navigation shell's bottom bar (dimmed and covered), not in the tab's
/// own navigator, where they stayed open when the user switched tabs.
void main() {
  setUpAll(registerTranslateFallbacks);

  final sheets = <String, Future<void> Function(BuildContext)>{
    'engine picker': showEngineSheet,
    'explanation': showExplainSheet,
    'extra targets': showExtraTargetsSheet,
    'recent pairs': showRecentPairsSheet,
    'span alternatives': showSpanAlternativesSheet,
    'instance switcher': showInstanceSwitcher,
    'word insight': (context) => showInsightSheet(
      context,
      const WordInsight(
        sourceText: 'Hello',
        targetText: 'Bonjour',
        explanation: 'A greeting',
      ),
    ),
    'translation options': showOptionsSheet,
  };

  for (final MapEntry(key: name, value: show) in sheets.entries) {
    testWidgets('the $name sheet opens above the tabs', (tester) async {
      final harness = TranslateHarness(
        state: readyState(engine: claude, input: 'Hello'),
      );
      await harness.pump(
        tester,
        size: const Size(400, 900),
        // A tab's own navigator, like a StatefulShellRoute branch.
        child: SizedBox(
          height: 600,
          child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => TextButton(
                key: const Key('open'),
                onPressed: () => unawaited(show(context)),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      final root = tester.state<NavigatorState>(find.byType(Navigator).first);
      final tab = tester.state<NavigatorState>(find.byType(Navigator).last);
      expect(identical(root, tab), isFalse);

      await tester.tap(find.byKey(const Key('open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      expect(identical(Navigator.of(tester.element(sheet)), root), isTrue);
      root.pop();
      await tester.pumpAndSettle();
    });
  }
}
