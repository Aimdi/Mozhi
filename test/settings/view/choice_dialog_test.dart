import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';

/// Finds the semantics node of a button with [tooltip] that screen readers
/// can reach on its own (not merged into another node).
FinderBase<SemanticsNode> _buttonByTooltip(String tooltip) =>
    find.semantics.byPredicate(
      (node) =>
          !node.isMergedIntoParent &&
          node.tooltip == tooltip &&
          node.getSemanticsData().hasAction(SemanticsAction.tap),
    );

void main() {
  group(ChoiceDialog, () {
    late List<String> played;

    setUp(() => played = []);

    /// Opens a dialog with two options that each have a play action.
    Future<void> open(
      WidgetTester tester, {
      Widget? footer,
      TextDirection direction = TextDirection.ltr,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              Directionality(textDirection: direction, child: child!),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<String>(
                context: context,
                builder: (context) => ChoiceDialog<String>(
                  title: 'Voice',
                  body: 'Pick one',
                  initialValue: 'a',
                  footer: footer,
                  options: [
                    for (final value in ['a', 'b'])
                      ChoiceDialogOption(
                        value: value,
                        title: Text('Option $value'),
                        action: IconButton(
                          tooltip: 'Play $value',
                          onPressed: () => played.add(value),
                          icon: const Icon(Icons.play_arrow),
                        ),
                      ),
                  ],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('keeps actions reachable by screen readers', (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester);

      expect(_buttonByTooltip('Play b'), findsOne);
      tester.semantics.tap(_buttonByTooltip('Play b'));
      await tester.pump();

      expect(played, ['b']);
      // The radio row is still one node, and pressing the action did not
      // select it.
      expect(
        find.semantics.byPredicate(
          (node) =>
              node.label == 'Option b' &&
              node
                  .getSemanticsData()
                  .flagsCollection
                  .isInMutuallyExclusiveGroup,
        ),
        findsOne,
      );
      expect(
        tester
            .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
            .groupValue,
        'a',
      );
      semantics.dispose();
    });

    testWidgets('selects an option and saves it', (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showDialog<String>(
                context: context,
                builder: (context) => const ChoiceDialog<String>(
                  title: 'Voice',
                  initialValue: 'a',
                  options: [
                    ChoiceDialogOption(value: 'a', title: Text('Option a')),
                    ChoiceDialogOption(value: 'b', title: Text('Option b')),
                  ],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Option b'));
      await tester.tap(find.byKey(ChoiceDialog.saveKey));
      await tester.pumpAndSettle();

      expect(result, 'b');
    });

    testWidgets('places actions at the end of the row', (tester) async {
      for (final direction in TextDirection.values) {
        await open(tester, direction: direction);

        final tile = tester.getRect(find.byType(RadioListTile<String>).last);
        final action = tester.getRect(find.byTooltip('Play b'));
        if (direction == TextDirection.ltr) {
          expect(action.left, greaterThanOrEqualTo(tile.right));
        } else {
          expect(action.right, lessThanOrEqualTo(tile.left));
        }
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('keeps the footer visible under scrolling options', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(360, 300)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await open(tester, footer: const Text('Status line'));

      expect(tester.takeException(), isNull);
      // The options scroll; the footer stays put above the actions.
      final options = tester.firstState<ScrollableState>(
        find.byType(Scrollable),
      );
      expect(options.position.maxScrollExtent, greaterThan(0));
      final footer = tester.getRect(find.text('Status line'));
      final save = tester.getRect(find.byKey(ChoiceDialog.saveKey));
      expect(footer.bottom, lessThanOrEqualTo(save.top));
      expect(footer.top, greaterThanOrEqualTo(0));
    });

    testWidgets('meets the tap target and label guidelines', (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester);

      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
    });
  });
}
