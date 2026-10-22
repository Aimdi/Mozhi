import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/focus_ring.dart';
import 'package:mozhi/l10n/l10n.dart';

import '../../helpers/helpers.dart';

void main() {
  final theme = buildAppTheme(
    appColorScheme(brightness: Brightness.light, seedColor: kDefaultAccent),
  );
  final accent = theme.colorScheme.primary;

  void keyboardMode() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
  }

  void touchMode() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
  }

  /// [child] in the app theme under a [FocusRingLayer], on an 800 x 600
  /// screen.
  Future<void> pumpLayer(WidgetTester tester, Widget child) =>
      tester.pumpWidget(
        FocusRingLayer(
          child: MaterialApp(
            theme: theme,
            localizationsDelegates: appLocalizationsDelegates,
            home: Material(child: child),
          ),
        ),
      );

  Finder ringPaint() => find.byWidgetPredicate(
    (widget) => widget.runtimeType.toString() == '_FocusRingPaint',
  );

  Rect screen(WidgetTester tester) =>
      Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;

  FocusRingGeometry? geometry(WidgetTester tester) => FocusRingGeometry.of(
    FocusManager.instance.primaryFocus!,
    screen: screen(tester),
  );

  group('focusRingPath', () {
    const rect = Rect.fromLTWH(10, 10, 100, 40);

    test('lies a gap outside the control', () {
      final bounds = focusRingPath(const StadiumBorder(), rect).getBounds();
      const out = kFocusRingGap + kFocusRingWidth / 2;
      expect(bounds, rect.inflate(out));
      expect(kFocusRingWidth, 2);
      expect(kFocusRingGap, greaterThan(0));
    });

    test('lies just inside the edge where there is no room', () {
      final bounds = focusRingPath(
        const RoundedRectangleBorder(),
        rect,
        inside: true,
      ).getBounds();
      expect(bounds, rect.deflate(kFocusRingWidth / 2));
    });

    test('keeps rounded corners concentric', () {
      const shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      );
      final path = focusRingPath(shape, rect);
      const out = kFocusRingGap + kFocusRingWidth / 2;
      // The corner of an 8 px radius ring would be cut at the ring's
      // corner; a concentric (8 + out) radius one is cut further in.
      final corner = rect.inflate(out).topLeft;
      expect(path.contains(corner + const Offset(1, 1)), isFalse);
      expect(path.contains(corner + const Offset(2.8, 2.8)), isFalse);
      expect(path.contains(rect.center), isTrue);
      // Square corners get a little rounding outside, none inside.
      final square = focusRingPath(const RoundedRectangleBorder(), rect);
      expect(square.contains(corner + const Offset(0.2, 0.2)), isFalse);
      final inside = focusRingPath(
        const RoundedRectangleBorder(),
        rect,
        inside: true,
      );
      expect(
        inside.contains(rect.deflate(1).topLeft + const Offset(0.1, 0.1)),
        isTrue,
      );
    });
  });

  group('isTextFieldFocus', () {
    testWidgets('tells text fields from controls', (tester) async {
      final field = FocusNode();
      final button = FocusNode();
      addTearDown(field.dispose);
      addTearDown(button.dispose);
      await tester.pumpApp(
        Material(
          child: Column(
            children: [
              TextField(focusNode: field),
              TextButton(
                focusNode: button,
                onPressed: () {},
                child: const Text('Go'),
              ),
            ],
          ),
        ),
      );
      expect(isTextFieldFocus(field), isTrue);
      expect(isTextFieldFocus(button), isFalse);
      expect(isTextFieldFocus(FocusNode()), isFalse);
    });
  });

  group('FocusRingLayer', () {
    testWidgets('rings the focused button while the keyboard is in use', (
      tester,
    ) async {
      keyboardMode();
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpLayer(
        tester,
        Center(
          child: FilledButton(
            focusNode: node,
            onPressed: () {},
            child: const Text('Go'),
          ),
        ),
      );
      expect(ringPaint(), isNot(paints..path()));

      node.requestFocus();
      await tester.pump();

      final button = tester.getRect(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.byType(InkWell),
        ),
      );
      final ring = geometry(tester)!;
      expect(ring.color, accent);
      expect(
        ring.path.getBounds(),
        rectMoreOrLessEquals(
          button.inflate(kFocusRingGap + kFocusRingWidth / 2),
        ),
      );
      expect(ring.clip, screen(tester));
      expect(
        ringPaint(),
        paints..path(
          color: accent,
          strokeWidth: kFocusRingWidth,
          style: PaintingStyle.stroke,
        ),
      );
    });

    testWidgets('shows no ring after touch', (tester) async {
      touchMode();
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpLayer(
        tester,
        Center(
          child: IconButton(
            focusNode: node,
            onPressed: () {},
            icon: const Icon(Icons.add),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();

      expect(ringPaint(), isNot(paints..path()));
    });

    testWidgets('appears and goes when the input mode changes', (tester) async {
      touchMode();
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpLayer(
        tester,
        Center(
          child: IconButton(
            focusNode: node,
            onPressed: () {},
            icon: const Icon(Icons.add),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
      expect(ringPaint(), isNot(paints..path()));

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      await tester.pump();
      expect(ringPaint(), paints..path(color: accent));
    });

    testWidgets('follows the ink well: a circle around an icon button', (
      tester,
    ) async {
      keyboardMode();
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpLayer(
        tester,
        Center(
          child: IconButton(
            focusNode: node,
            onPressed: () {},
            icon: const Icon(Icons.add),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();

      final button = tester.getRect(
        find.descendant(
          of: find.byType(IconButton),
          matching: find.byType(InkWell),
        ),
      );
      final path = geometry(tester)!.path;
      final ring = button.inflate(kFocusRingGap + kFocusRingWidth / 2);
      expect(path.getBounds(), rectMoreOrLessEquals(ring));
      // Round: the corners of its square are outside it.
      expect(path.contains(ring.topLeft + const Offset(2, 2)), isFalse);
    });

    testWidgets('rings list rows at the screen edge inside their bounds', (
      tester,
    ) async {
      keyboardMode();
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpLayer(
        tester,
        Scaffold(
          body: ListView(
            children: [
              ListTile(focusNode: node, title: const Text('Row'), onTap: () {}),
            ],
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();

      final tile = tester.getRect(find.byType(ListTile));
      expect(
        geometry(tester)!.path.getBounds(),
        rectMoreOrLessEquals(tile.deflate(kFocusRingWidth / 2)),
      );
    });

    testWidgets('a rounded ink well keeps its corners (custom tappables)', (
      tester,
    ) async {
      keyboardMode();
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpLayer(
        tester,
        Center(
          child: InkWell(
            focusNode: node,
            borderRadius: BorderRadius.circular(12),
            onTap: () {},
            child: const SizedBox(width: 100, height: 40),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();

      final well = tester.getRect(find.byType(InkWell));
      final ring = well.inflate(kFocusRingGap + kFocusRingWidth / 2);
      final path = geometry(tester)!.path;
      expect(path.getBounds(), rectMoreOrLessEquals(ring));
      expect(path.contains(ring.topLeft + const Offset(1, 1)), isFalse);
    });

    testWidgets('a plain ink response is ringed as a circle', (tester) async {
      keyboardMode();
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpLayer(
        tester,
        Center(
          child: InkResponse(
            focusNode: node,
            onTap: () {},
            child: const SizedBox.square(dimension: 40),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();

      final ring = tester
          .getRect(find.byType(InkResponse))
          .inflate(kFocusRingGap + kFocusRingWidth / 2);
      expect(
        geometry(tester)!.path.contains(ring.topLeft + const Offset(2, 2)),
        isFalse,
      );
    });

    testWidgets('follows the control while it scrolls, clipped to the list', (
      tester,
    ) async {
      keyboardMode();
      final node = FocusNode();
      final controller = ScrollController();
      addTearDown(node.dispose);
      addTearDown(controller.dispose);
      await pumpLayer(
        tester,
        Scaffold(
          appBar: AppBar(title: const Text('Title')),
          body: ListView(
            controller: controller,
            children: [
              const SizedBox(height: 100),
              Center(
                child: TextButton(
                  focusNode: node,
                  onPressed: () {},
                  child: const Text('Go'),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
      final before = geometry(tester)!;
      final list = tester.getRect(find.byType(ListView));
      expect(before.clip, list);

      controller.jumpTo(60);
      await tester.pump();
      final after = geometry(tester)!;
      expect(
        after.path.getBounds().top,
        moreOrLessEquals(before.path.getBounds().top - 60),
      );
      // The layer repainted along with the scroll, at the new place.
      expect(
        ringPaint(),
        paints..path(
          includes: [after.path.getBounds().center],
          excludes: [before.path.getBounds().topCenter],
        ),
      );
    });

    testWidgets('leaves out text fields, scopes and plain focus nodes', (
      tester,
    ) async {
      keyboardMode();
      final field = FocusNode();
      final plain = FocusNode();
      addTearDown(field.dispose);
      addTearDown(plain.dispose);
      await pumpLayer(
        tester,
        Scaffold(
          body: Column(
            children: [
              TextField(focusNode: field),
              Focus(focusNode: plain, child: const Text('Page')),
            ],
          ),
        ),
      );
      field.requestFocus();
      await tester.pump();
      expect(geometry(tester), isNull);
      expect(ringPaint(), isNot(paints..path()));

      plain.requestFocus();
      await tester.pump();
      expect(geometry(tester), isNull);

      final scope = FocusScope.of(tester.element(find.text('Page')));
      expect(FocusRingGeometry.of(scope, screen: screen(tester)), isNull);
    });

    testWidgets('leaves out controls that are not painted', (tester) async {
      keyboardMode();
      final hidden = FocusNode();
      final faded = FocusNode();
      addTearDown(hidden.dispose);
      addTearDown(faded.dispose);
      await pumpLayer(
        tester,
        Column(
          children: [
            SizedBox(
              height: 100,
              child: IndexedStack(
                children: [
                  const Text('Shown'),
                  TextButton(
                    focusNode: hidden,
                    onPressed: () {},
                    child: const Text('Hidden'),
                  ),
                ],
              ),
            ),
            Opacity(
              opacity: 0,
              child: TextButton(
                focusNode: faded,
                onPressed: () {},
                child: const Text('Faded'),
              ),
            ),
          ],
        ),
      );
      hidden.requestFocus();
      await tester.pump();
      expect(geometry(tester), isNull);

      faded.requestFocus();
      await tester.pump();
      expect(geometry(tester), isNull);
    });

    testWidgets('rings the shown child of an indexed stack', (tester) async {
      keyboardMode();
      final shown = FocusNode();
      addTearDown(shown.dispose);
      await pumpLayer(
        tester,
        Center(
          child: IndexedStack(
            index: 1,
            children: [
              const Text('Hidden'),
              TextButton(
                focusNode: shown,
                onPressed: () {},
                child: const Text('Shown'),
              ),
            ],
          ),
        ),
      );
      shown.requestFocus();
      await tester.pump();
      expect(geometry(tester), isNotNull);
    });

    testWidgets("takes the accent of the control's theme", (tester) async {
      keyboardMode();
      final node = FocusNode();
      addTearDown(node.dispose);
      final dark = buildAppTheme(
        appColorScheme(
          brightness: Brightness.dark,
          seedColor: const Color(0xFFFFD400),
        ),
      );
      await pumpLayer(
        tester,
        Theme(
          data: dark,
          child: Center(
            child: OutlinedButton(
              focusNode: node,
              onPressed: () {},
              child: const Text('Go'),
            ),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
      expect(geometry(tester)!.color, dark.colorScheme.primary);
    });

    testWidgets('rings navigation bar destinations around the indicator', (
      tester,
    ) async {
      keyboardMode();
      await pumpLayer(
        tester,
        Scaffold(
          bottomNavigationBar: NavigationBar(
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
              NavigationDestination(icon: Icon(Icons.star), label: 'Star'),
            ],
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      final ring = geometry(tester)!.path.getBounds();
      final bar = tester.getRect(find.byType(NavigationBar));
      // Around the icon's indicator, not the whole half of the bar.
      expect(ring.width, lessThan(bar.width / 2 - 20));
      expect(ring.contains(tester.getCenter(find.byIcon(Icons.home))), isTrue);
    });

    testWidgets('repaints with frames only while a ring shows', (tester) async {
      keyboardMode();
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpLayer(
        tester,
        Center(
          child: TextButton(
            focusNode: node,
            onPressed: () {},
            child: const Text('Go'),
          ),
        ),
      );
      final scheduler = SchedulerBinding.instance;
      expect(scheduler.transientCallbackCount, 0);

      node.requestFocus();
      // Settles (the button's focus highlight fades in): the ring asks
      // for no frames.
      await tester.pumpAndSettle();
      // It waits for the next frame, whenever it comes.
      expect(scheduler.transientCallbackCount, 1);
      expect(scheduler.hasScheduledFrame, isFalse);

      node.unfocus();
      await tester.pumpAndSettle();
      expect(scheduler.transientCallbackCount, 0);

      // Removed with a ring up: its last callback finds it gone.
      node.requestFocus();
      await tester.pumpAndSettle();
      expect(scheduler.transientCallbackCount, 1);
      await tester.pumpWidget(const SizedBox());
      expect(scheduler.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('takes no hits', (tester) async {
      var taps = 0;
      await pumpLayer(
        tester,
        Center(
          child: TextButton(onPressed: () => taps++, child: const Text('Go')),
        ),
      );
      await tester.tap(find.text('Go'));
      expect(taps, 1);
    });
  });

  group('FocusRing', () {
    CustomPaint ringOf(WidgetTester tester, [int index = 0]) =>
        tester.widget<CustomPaint>(
          find
              .descendant(
                of: find.byType(FocusRing),
                matching: find.byType(CustomPaint),
              )
              .at(index),
        );

    testWidgets('rings a custom tappable the layer leaves to it', (
      tester,
    ) async {
      keyboardMode();
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpLayer(
        tester,
        Center(
          child: FocusRing(
            shape: const StadiumBorder(),
            child: Focus(
              focusNode: node,
              child: GestureDetector(
                onTap: () {},
                child: const SizedBox(width: 80, height: 40),
              ),
            ),
          ),
        ),
      );
      expect(ringOf(tester).foregroundPainter, isNull);

      node.requestFocus();
      await tester.pump();

      expect(ringOf(tester).foregroundPainter, isNotNull);
      expect(FocusRing.claims(node), isTrue);
      final box = tester.getRect(find.byType(FocusRing));
      expect(
        find.byType(FocusRing),
        paints..path(
          color: accent,
          strokeWidth: kFocusRingWidth,
          includes: [Offset(box.width / 2, -kFocusRingGap - 1)],
        ),
      );
      // Drawn once: the layer leaves it out.
      expect(geometry(tester), isNull);

      node.unfocus();
      await tester.pump();
      await tester.pump();
      expect(ringOf(tester).foregroundPainter, isNull);
    });

    testWidgets('leaves controls nested in its control to the layer', (
      tester,
    ) async {
      keyboardMode();
      final inner = FocusNode();
      addTearDown(inner.dispose);
      await pumpLayer(
        tester,
        Center(
          child: FocusRing(
            child: InkWell(
              onTap: () {},
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: IconButton(
                  focusNode: inner,
                  onPressed: () {},
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
          ),
        ),
      );
      inner.requestFocus();
      await tester.pump();

      expect(ringOf(tester).foregroundPainter, isNull);
      expect(FocusRing.claims(inner), isFalse);
      expect(geometry(tester), isNotNull);
    });

    testWidgets('shows no ring after touch or while disabled', (tester) async {
      touchMode();
      final node = FocusNode();
      addTearDown(node.dispose);
      Future<void> pump({required bool enabled}) => pumpLayer(
        tester,
        Center(
          child: FocusRing(
            enabled: enabled,
            child: InkWell(
              focusNode: node,
              onTap: () {},
              child: const SizedBox.square(dimension: 40),
            ),
          ),
        ),
      );
      await pump(enabled: true);
      node.requestFocus();
      await tester.pump();
      expect(ringOf(tester).foregroundPainter, isNull);

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      await tester.pump();
      expect(ringOf(tester).foregroundPainter, isNotNull);

      await pump(enabled: false);
      expect(ringOf(tester).foregroundPainter, isNull);
    });

    testWidgets('.field rings a borderless field, inside a margin', (
      tester,
    ) async {
      keyboardMode();
      final field = FocusNode();
      final button = FocusNode();
      addTearDown(field.dispose);
      addTearDown(button.dispose);
      const margin = EdgeInsetsDirectional.only(start: 12, bottom: 8);
      await pumpLayer(
        tester,
        Center(
          child: SizedBox(
            width: 300,
            child: FocusRing.field(
              margin: margin,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(20)),
              ),
              child: Padding(
                padding: margin,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        focusNode: field,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    IconButton(
                      focusNode: button,
                      onPressed: () {},
                      icon: const Icon(Icons.mic),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      field.requestFocus();
      await tester.pump();
      expect(ringOf(tester).foregroundPainter, isNotNull);
      final size = tester.getSize(find.byType(FocusRing));
      final painter = ringOf(tester).foregroundPainter!;
      expect(
        (Canvas canvas) => painter.paint(canvas, size),
        paints..path(
          color: accent,
          // Inside the margin at the start: left of it, not ringed.
          includes: [Offset(12 - kFocusRingGap - 1, size.height / 2)],
          excludes: [Offset(1, size.height / 2)],
        ),
      );
      // Not a control of its own: the field's focus is not claimed.
      expect(FocusRing.claims(field), isFalse);

      // A button in the composer gets its own ring from the layer.
      button.requestFocus();
      await tester.pump();
      expect(ringOf(tester).foregroundPainter, isNull);
      expect(geometry(tester), isNotNull);
    });

    testWidgets('switching kinds recomputes the focus', (tester) async {
      keyboardMode();
      final field = FocusNode();
      addTearDown(field.dispose);
      Widget ring({required bool fields}) => Center(
        child: SizedBox(
          width: 200,
          child: fields
              ? FocusRing.field(child: TextField(focusNode: field))
              : FocusRing(child: TextField(focusNode: field)),
        ),
      );
      await pumpLayer(tester, ring(fields: true));
      field.requestFocus();
      await tester.pump();
      expect(ringOf(tester).foregroundPainter, isNotNull);

      await pumpLayer(tester, ring(fields: false));
      // A plain ring is for the field too (the first control in it).
      expect(ringOf(tester).foregroundPainter, isNotNull);
    });

    test('defaults to a softly rounded box', () {
      expect(FocusRing.defaultShape, isA<RoundedRectangleBorder>());
    });
  });
}
