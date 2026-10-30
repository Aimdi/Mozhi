import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/word_lookup/widgets/word_tap_tracker.dart';

const _text = 'Bonjour le monde';

/// Where to tap to put the caret before [offset] of the text.
Offset _at(WidgetTester tester, int offset) {
  final editable = tester.state<EditableTextState>(
    find.descendant(
      of: find.byType(SelectableText),
      matching: find.byType(EditableText),
    ),
  );
  final render = editable.renderEditable;
  final caret = render.getLocalRectForCaret(TextPosition(offset: offset));
  return render.localToGlobal(caret.center + const Offset(2, 0));
}

void main() {
  late List<int> taps;
  late WordTapTracker tracker;

  setUp(() {
    taps = [];
    tracker = WordTapTracker(onWordTap: taps.add);
  });

  tearDown(() => tracker.dispose());

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Column(
          children: [
            Builder(
              builder: (context) => SelectableText(
                _text,
                style: const TextStyle(fontSize: 20),
                focusNode: tracker.focusNode,
                onSelectionChanged: tracker.onSelectionChanged,
                onTap: () => tracker.onTap(context),
              ),
            ),
            const TextField(key: Key('other')),
          ],
        ),
      ),
    ),
  );

  testWidgets('a tap reports its offset after the double-tap timeout', (
    tester,
  ) async {
    await pump(tester);
    await tester.tapAt(_at(tester, 12));
    await tester.pump();
    expect(taps, isEmpty);
    expect(tracker.isPending, isTrue);
    await tester.pump(kDoubleTapTimeout);
    expect(taps, [12]);
    expect(tracker.isPending, isFalse);
  });

  testWidgets('the same spot tapped again reports again', (tester) async {
    await pump(tester);
    await tester.tapAt(_at(tester, 12));
    await tester.pump(kDoubleTapTimeout);
    await tester.tapAt(_at(tester, 12));
    await tester.pump(kDoubleTapTimeout);
    expect(taps, [12, 12]);
  });

  testWidgets('a double tap selects a word and reports nothing', (
    tester,
  ) async {
    await pump(tester);
    await tester.tapAt(_at(tester, 12));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(_at(tester, 12));
    await tester.pump(kDoubleTapTimeout);
    await tester.pump(kDoubleTapTimeout);
    expect(taps, isEmpty);
    expect(tracker.hasSelection, isTrue);
  });

  testWidgets('a long press selects a word and reports nothing', (
    tester,
  ) async {
    await pump(tester);
    await tester.longPressAt(_at(tester, 12));
    await tester.pump(kDoubleTapTimeout);
    expect(taps, isEmpty);
    expect(tracker.hasSelection, isTrue);
    // A tap that clears the selection reports nothing either.
    await tester.tapAt(_at(tester, 2));
    await tester.pump(kDoubleTapTimeout);
    expect(taps, isEmpty);
    expect(tracker.hasSelection, isFalse);
    // The next one does.
    await tester.tapAt(_at(tester, 2));
    await tester.pump(kDoubleTapTimeout);
    expect(taps, [2]);
  });

  testWidgets('a selection made while a tap waits drops it', (tester) async {
    await pump(tester);
    await tester.tapAt(_at(tester, 12));
    await tester.pump();
    tracker.onSelectionChanged(
      const TextSelection(baseOffset: 0, extentOffset: 7),
      SelectionChangedCause.drag,
    );
    await tester.pump(kDoubleTapTimeout);
    expect(taps, isEmpty);
  });

  testWidgets('focus leaving the text forgets its selection', (tester) async {
    await pump(tester);
    await tester.longPressAt(_at(tester, 12));
    await tester.pump();
    expect(tracker.hasSelection, isTrue);
    await tester.tap(find.byKey(const Key('other')));
    await tester.pump();
    expect(tracker.hasSelection, isFalse);
    await tester.tapAt(_at(tester, 4));
    await tester.pump(kDoubleTapTimeout);
    expect(taps, [4]);
  });

  testWidgets('cancel drops a waiting tap', (tester) async {
    await pump(tester);
    await tester.tapAt(_at(tester, 12));
    await tester.pump();
    tracker.cancel();
    await tester.pump(kDoubleTapTimeout);
    expect(taps, isEmpty);
  });

  testWidgets('a tap without an editable text uses the latest selection', (
    tester,
  ) async {
    tracker
      ..onSelectionChanged(
        const TextSelection.collapsed(offset: 3),
        SelectionChangedCause.tap,
      )
      ..onTap(_NoChildren());
    await tester.pump(kDoubleTapTimeout);
    expect(taps, [3]);
    tracker
      ..onSelectionChanged(
        const TextSelection.collapsed(offset: -1),
        SelectionChangedCause.tap,
      )
      ..onTap(_NoChildren());
    await tester.pump(kDoubleTapTimeout);
    expect(taps, [3]);
  });
}

/// A context without children.
class _NoChildren extends Fake implements BuildContext {
  @override
  void visitChildElements(ElementVisitor visitor) {}
}
