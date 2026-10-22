import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

import '../helpers/helpers.dart';

Finder _tool(TranslateTool tool) =>
    find.byKey(ValueKey('translate_tool_${tool.name}'));

Future<TranslateHarness> _open(
  WidgetTester tester, {
  TranslateState? state,
  Size size = const Size(400, 800),
}) async {
  final harness = TranslateHarness(state: state);
  await harness.pump(
    tester,
    size: size,
    child: const Align(alignment: Alignment.topRight, child: MoreToolsButton()),
  );
  await tester.tap(find.byKey(const Key('translate_more_tools')));
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  setUpAll(registerTranslateFallbacks);
  setUp(HardwareKeyboardSeen.reset);
  tearDown(HardwareKeyboardSeen.reset);

  group('MoreToolsButton', () {
    testWidgets('offers only tools without another way in on phones', (
      tester,
    ) async {
      await _open(tester, state: translatedState());
      expect(_tool(TranslateTool.documents), findsOneWidget);
      expect(_tool(TranslateTool.webPage), findsOneWidget);
      expect(_tool(TranslateTool.recentPairs), findsOneWidget);
      // The camera chip and button, the compare tool and a long press on
      // Listen are on the screen.
      expect(_tool(TranslateTool.image), findsNothing);
      expect(find.text('Compare engines'), findsNothing);
      expect(find.textContaining('slowly'), findsNothing);
      // No keyboard seen on a phone.
      expect(_tool(TranslateTool.shortcuts), findsNothing);
      expect(find.byType(PopupMenuDivider), findsOneWidget);
    });

    testWidgets('offers the shortcuts on wide layouts', (tester) async {
      await _open(tester, size: const Size(1200, 800));
      expect(_tool(TranslateTool.shortcuts), findsOneWidget);
    });

    testWidgets('offers the shortcuts once a hardware keyboard shows', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        size: const Size(400, 800),
        child: const MoreToolsButton(),
      );
      // Keys an on-screen keyboard sends too do not count.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      expect(HardwareKeyboardSeen.value, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(HardwareKeyboardSeen.value, isTrue);
      await tester.tap(find.byKey(const Key('translate_more_tools')));
      await tester.pumpAndSettle();
      expect(_tool(TranslateTool.shortcuts), findsOneWidget);
      await tester.tap(_tool(TranslateTool.shortcuts));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
    });

    testWidgets('offers the camera while there are no engines', (tester) async {
      final harness = await _open(
        tester,
        state: const TranslateState(enginesStatus: EnginesStatus.ready),
      );
      expect(_tool(TranslateTool.image), findsOneWidget);
      expect(_tool(TranslateTool.recentPairs), findsNothing);
      await tester.tap(_tool(TranslateTool.image));
      await tester.pumpAndSettle();
      verify(() => harness.router.push<void>('/translate/image')).called(1);
    });

    testWidgets('opens documents and web pages', (tester) async {
      final harness = await _open(tester);
      await tester.tap(_tool(TranslateTool.documents));
      await tester.pumpAndSettle();
      verify(() => harness.router.push<void>('/documents')).called(1);
      await tester.tap(find.byKey(const Key('translate_more_tools')));
      await tester.pumpAndSettle();
      await tester.tap(_tool(TranslateTool.webPage));
      await tester.pumpAndSettle();
      verify(() => harness.router.push<void>(TranslateTool.webPage.route!))
          .called(1);
    });

    testWidgets('opens the recent pairs', (tester) async {
      await _open(tester, state: translatedState());
      await tester.tap(_tool(TranslateTool.recentPairs));
      await tester.pumpAndSettle();
      expect(find.text('Recent language pairs'), findsWidgets);
    });

    test('canListenToTranslation needs a translation in a real language', () {
      expect(canListenToTranslation(translatedState()), isTrue);
      expect(canListenToTranslation(readyState(input: 'Hi')), isFalse);
    });
  });
}
