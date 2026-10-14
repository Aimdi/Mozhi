import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/local_overlay.dart';

void main() {
  group(LocalOverlay, () {
    Widget app(Widget child) => MaterialApp(
      home: Scaffold(body: Column(children: [child])),
    );

    testWidgets('is sized by its child and rebuilds it', (tester) async {
      await tester.pumpWidget(
        app(const LocalOverlay(child: SizedBox(height: 40, child: Text('a')))),
      );
      expect(tester.getSize(find.byType(LocalOverlay)).height, 40);
      expect(find.text('a'), findsOneWidget);

      await tester.pumpWidget(
        app(const LocalOverlay(child: SizedBox(height: 40, child: Text('b')))),
      );
      expect(find.text('a'), findsNothing);
      expect(find.text('b'), findsOneWidget);

      await tester.pumpWidget(app(const SizedBox()));
      expect(find.byType(Overlay), findsOneWidget);
    });

    testWidgets('keeps a slider overlay node within the slider', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        app(
          MergeSemantics(
            child: Semantics(
              label: 'Rate',
              child: LocalOverlay(
                child: Slider(value: 0.5, divisions: 10, onChanged: (_) {}),
              ),
            ),
          ),
        ),
      );
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      final empty = find.semantics.byPredicate((node) {
        final data = node.getSemanticsData();
        return !node.isMergedIntoParent &&
            !node.hasChildren &&
            data.label.isEmpty &&
            data.actions == 0;
      });
      expect(empty, findsNothing);
      final slider = tester.getSemantics(find.byType(Slider));
      expect(slider, isSemantics(label: 'Rate', isSlider: true));
      expect(slider.rect.height, lessThan(screen.height / 2));
      handle.dispose();
    });
  });
}
