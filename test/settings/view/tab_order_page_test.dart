import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/tab_order_page.dart';

import 'helpers.dart';

class _MockSettingsRepository extends Mock implements SettingsRepository;

const List<AppTab> _custom = [
  AppTab.dictionary,
  AppTab.translate,
  AppTab.proofread,
  AppTab.conversation,
];

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(const AppSettings());
  });

  group(TabOrderPage, () {
    late SettingsCubit cubit;

    setUp(() {
      final repository = _MockSettingsRepository();
      when(() => repository.save(any())).thenAnswer((_) async {});
      cubit = SettingsCubit(repository: repository);
    });

    tearDown(() => cubit.close());

    Future<void> pump(
      WidgetTester tester, {
      List<AppTab> order = AppTab.values,
      Size size = const Size(400, 800),
      double textScale = 1,
      ThemeData? theme,
    }) async {
      cubit.setTabOrder(order);
      tester.setScreenSize(size);
      await tester.pumpView(
        const TabOrderPage(),
        settings: cubit,
        textScale: textScale,
        theme: theme,
      );
      await tester.pumpAndSettle();
    }

    /// The tab names from top to bottom.
    List<String> namesOnScreen(WidgetTester tester) {
      final names = ['Translate', 'Dictionary', 'Proofread', 'Conversation'];
      return names.toList()..sort(
        (a, b) => tester
            .getTopLeft(find.text(a))
            .dy
            .compareTo(tester.getTopLeft(find.text(b)).dy),
      );
    }

    Finder upButton(AppTab tab) => find.byKey(Key('tab_order_up_${tab.name}'));
    Finder downButton(AppTab tab) =>
        find.byKey(Key('tab_order_down_${tab.name}'));

    bool enabled(WidgetTester tester, Finder button) =>
        tester.widget<IconButton>(button).onPressed != null;

    testWidgets('lists the tabs in the saved order', (tester) async {
      await pump(tester, order: _custom);

      expect(find.text('Tab order'), findsOneWidget);
      expect(
        find.text(
          'The app opens on the first tab. Drag a tab by its handle or use '
          'the arrows to move it.',
        ),
        findsOneWidget,
      );
      expect(namesOnScreen(tester), [
        'Dictionary',
        'Translate',
        'Proofread',
        'Conversation',
      ]);
      // The first one says it opens at start.
      final first = tester.getTopLeft(find.byKey(const Key('tab_order_first')));
      expect(
        first.dy,
        greaterThan(tester.getTopLeft(find.text('Dictionary')).dy),
      );
      expect(first.dy, lessThan(tester.getTopLeft(find.text('Translate')).dy));
      expect(find.byIcon(Icons.menu_book_outlined), findsOneWidget);
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(4));
    });

    testWidgets('moves tabs with the arrow buttons', (tester) async {
      await pump(tester);

      expect(enabled(tester, upButton(AppTab.translate)), isFalse);
      expect(enabled(tester, downButton(AppTab.conversation)), isFalse);
      expect(find.byTooltip('Move Translate down'), findsOneWidget);

      await tester.tap(downButton(AppTab.translate));
      await tester.pumpAndSettle();
      expect(cubit.state.tabOrder, [
        AppTab.dictionary,
        AppTab.translate,
        AppTab.proofread,
        AppTab.conversation,
      ]);
      expect(namesOnScreen(tester).first, 'Dictionary');

      await tester.tap(upButton(AppTab.conversation));
      await tester.pumpAndSettle();
      expect(cubit.state.tabOrder, [
        AppTab.dictionary,
        AppTab.translate,
        AppTab.conversation,
        AppTab.proofread,
      ]);
      expect(enabled(tester, upButton(AppTab.dictionary)), isFalse);
      expect(enabled(tester, downButton(AppTab.proofread)), isFalse);
    });

    testWidgets('moves a tab by dragging its handle', (tester) async {
      await pump(tester);
      final handles = find.byIcon(Icons.drag_indicator);
      final rowHeight =
          tester.getCenter(handles.at(1)).dy -
          tester.getCenter(handles.at(0)).dy;

      final gesture = await tester.startGesture(
        tester.getCenter(handles.first),
      );
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(Offset(0, rowHeight * 0.25));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(cubit.state.tabOrder.first, AppTab.dictionary);
      expect(cubit.state.tabOrder.indexOf(AppTab.translate), greaterThan(1));
    });

    testWidgets('screen readers can move tabs with list actions', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester);

      final node = tester.getSemantics(find.text('Dictionary'));
      final actions = <String>{};
      // The move actions are on the item's node or an ancestor.
      SemanticsNode? current = node;
      while (current != null) {
        final data = current.getSemanticsData();
        for (final id in data.customSemanticsActionIds ?? <int>[]) {
          actions.add(CustomSemanticsAction.getAction(id)!.label!);
        }
        current = current.parent;
      }
      expect(actions, containsAll(<String>['Move up', 'Move down']));
      handle.dispose();
    });

    testWidgets('Reset restores the default order and can be undone', (
      tester,
    ) async {
      await pump(tester, order: _custom);
      expect(enabled(tester, find.byKey(TabOrderView.resetKey)), isTrue);

      await tester.tap(find.byKey(TabOrderView.resetKey));
      await tester.pumpAndSettle();
      expect(cubit.state.tabOrder, AppTab.values);
      expect(find.text('Default tab order restored'), findsOneWidget);
      expect(enabled(tester, find.byKey(TabOrderView.resetKey)), isFalse);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(cubit.state.tabOrder, _custom);
    });

    testWidgets('Reset is disabled in the default order', (tester) async {
      await pump(tester);

      expect(find.byTooltip('Reset to the default order'), findsOneWidget);
      expect(enabled(tester, find.byKey(TabOrderView.resetKey)), isFalse);
    });

    testWidgets('fits 320 dp at 200% text with the arrows under the names', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, size: const Size(320, 2000), textScale: 2);

      expect(tester.takeException(), isNull);
      // The arrows sit below the name on a line of their own.
      final name = tester.getRect(find.text('Conversation'));
      final up = tester.getRect(upButton(AppTab.conversation));
      expect(up.top, greaterThanOrEqualTo(name.bottom));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('keeps the arrows beside the names on wide screens', (
      tester,
    ) async {
      await pump(tester, size: const Size(800, 800));

      final name = tester.getRect(find.text('Conversation'));
      final up = tester.getRect(upButton(AppTab.conversation));
      expect(up.center.dy, moreOrLessEquals(name.center.dy, epsilon: 2));
      expect(up.left, greaterThan(name.right));
    });

    testWidgets('mirrors in right-to-left layouts', (tester) async {
      cubit.setTabOrder(AppTab.values);
      tester.setScreenSize(const Size(400, 800));
      await tester.pumpView(
        const Directionality(
          textDirection: TextDirection.rtl,
          child: TabOrderPage(),
        ),
        settings: cubit,
      );
      await tester.pumpAndSettle();

      final handle = tester.getRect(find.byIcon(Icons.drag_indicator).first);
      final name = tester.getRect(find.text('Translate'));
      expect(handle.left, greaterThan(name.right));
    });

    testWidgets('renders in the dark theme and meets the contrast guideline', (
      tester,
    ) async {
      await pump(tester, theme: ThemeData(brightness: Brightness.dark));

      expect(find.byType(TabOrderView), findsOneWidget);
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });
  });
}
