import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/fold_aware_split.dart';

const _first = Key('first');
const _second = Key('second');
const _divider = Key('divider');

/// A hinge (Surface Duo style: it has a width) at [left]..[left + width],
/// the full window height.
DisplayFeature _hinge(double left, {double width = 20, double height = 600}) =>
    DisplayFeature(
      bounds: Rect.fromLTWH(left, 0, width, height),
      type: DisplayFeatureType.hinge,
      state: DisplayFeatureState.unknown,
    );

/// A horizontal fold (tabletop posture when half opened) at [top].
DisplayFeature _horizontalFold(
  double top, {
  DisplayFeatureState state = DisplayFeatureState.postureHalfOpened,
  double width = 800,
}) => DisplayFeature(
  bounds: Rect.fromLTWH(0, top, width, 0),
  type: DisplayFeatureType.fold,
  state: state,
);

/// A vertical fold (book posture when half opened) at [left].
DisplayFeature _verticalFold(
  double left, {
  DisplayFeatureState state = DisplayFeatureState.postureHalfOpened,
}) => DisplayFeature(
  bounds: Rect.fromLTWH(left, 0, 0, 600),
  type: DisplayFeatureType.fold,
  state: state,
);

FoldAwareSplit _split({
  Axis direction = Axis.horizontal,
  int firstFlex = 1,
  int secondFlex = 1,
  double gap = 1,
  CrossAxisAlignment crossAxisAlignment = CrossAxisAlignment.stretch,
  Set<Axis> foldDirections = const {Axis.horizontal, Axis.vertical},
  Widget first = const ColoredBox(key: _first, color: Color(0xFF2196F3)),
  Widget second = const ColoredBox(key: _second, color: Color(0xFF4CAF50)),
  bool withDivider = true,
}) => FoldAwareSplit(
  direction: direction,
  firstFlex: firstFlex,
  secondFlex: secondFlex,
  gap: gap,
  crossAxisAlignment: crossAxisAlignment,
  foldDirections: foldDirections,
  divider: withDivider
      ? const ColoredBox(key: _divider, color: Color(0xFF000000))
      : null,
  first: first,
  second: second,
);

void main() {
  /// Pumps [child] in a [size] window with [features], [padding] around
  /// it, then one more frame (the split follows the box's position after
  /// its first layout).
  Future<void> pumpSplit(
    WidgetTester tester,
    Widget child, {
    List<DisplayFeature> features = const [],
    Size size = const Size(800, 600),
    TextDirection textDirection = TextDirection.ltr,
    EdgeInsets padding = EdgeInsets.zero,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size, displayFeatures: features),
        child: Directionality(
          textDirection: textDirection,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
    await tester.pump();
  }

  Rect rectOf(WidgetTester tester, Key key) => tester.getRect(find.byKey(key));

  RenderFoldAwareSplit renderOf(WidgetTester tester) =>
      tester.renderObject<RenderFoldAwareSplit>(
        find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_FoldAwareSplitLayout',
        ),
      );

  group('isSeparatingDisplayFeature', () {
    DisplayFeature feature(
      DisplayFeatureType type, [
      DisplayFeatureState state = DisplayFeatureState.unknown,
    ]) => DisplayFeature(
      bounds: const Rect.fromLTWH(400, 0, 0, 600),
      type: type,
      state: state,
    );

    test('a hinge separates in every posture', () {
      for (final state in DisplayFeatureState.values) {
        expect(
          isSeparatingDisplayFeature(feature(DisplayFeatureType.hinge, state)),
          isTrue,
          reason: '$state',
        );
      }
    });

    test('a fold separates only when half opened', () {
      expect(
        isSeparatingDisplayFeature(
          feature(
            DisplayFeatureType.fold,
            DisplayFeatureState.postureHalfOpened,
          ),
        ),
        isTrue,
      );
      for (final state in [
        DisplayFeatureState.postureFlat,
        DisplayFeatureState.unknown,
      ]) {
        expect(
          isSeparatingDisplayFeature(feature(DisplayFeatureType.fold, state)),
          isFalse,
          reason: '$state',
        );
      }
    });

    test('cutouts and unknown features do not separate', () {
      for (final type in [
        DisplayFeatureType.cutout,
        DisplayFeatureType.unknown,
      ]) {
        expect(
          isSeparatingDisplayFeature(feature(type)),
          isFalse,
          reason: '$type',
        );
      }
    });
  });

  group('FoldAwareSplit.featureDirectionOf', () {
    Future<Axis?> directionWith(
      WidgetTester tester,
      List<DisplayFeature> features,
    ) async {
      Axis? direction;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(displayFeatures: features),
          child: Builder(
            builder: (context) {
              direction = FoldAwareSplit.featureDirectionOf(context);
              return const SizedBox();
            },
          ),
        ),
      );
      return direction;
    }

    testWidgets('is null without a separating feature', (tester) async {
      expect(await directionWith(tester, const []), isNull);
      expect(
        await directionWith(tester, [
          _verticalFold(400, state: DisplayFeatureState.postureFlat),
        ]),
        isNull,
      );
    });

    testWidgets('is side by side for a vertical hinge', (tester) async {
      expect(await directionWith(tester, [_hinge(390)]), Axis.horizontal);
      expect(
        await directionWith(tester, [_verticalFold(400)]),
        Axis.horizontal,
      );
    });

    testWidgets('is one above the other for a horizontal fold', (tester) async {
      expect(
        await directionWith(tester, [_horizontalFold(300)]),
        Axis.vertical,
      );
    });
  });

  group('FoldAwareSplit', () {
    testWidgets('without a feature lays out like a row of two Expanded', (
      tester,
    ) async {
      await pumpSplit(tester, _split());
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 399.5, 600));
      expect(rectOf(tester, _divider), const Rect.fromLTWH(399.5, 0, 1, 600));
      expect(
        rectOf(tester, _second),
        const Rect.fromLTWH(400.5, 0, 399.5, 600),
      );
      expect(renderOf(tester).splitsAtFeature, isFalse);
    });

    testWidgets('keeps the flex ratio and the gap', (tester) async {
      await pumpSplit(
        tester,
        _split(firstFlex: 2, gap: 24, withDivider: false),
        size: const Size(624, 400),
      );
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 400, 400));
      expect(rectOf(tester, _second), const Rect.fromLTWH(424, 0, 200, 400));
    });

    testWidgets('stacks the panes in the vertical direction', (tester) async {
      await pumpSplit(tester, _split(direction: Axis.vertical, gap: 0));
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 800, 300));
      expect(rectOf(tester, _second), const Rect.fromLTWH(0, 300, 800, 300));
    });

    testWidgets('splits at a vertical hinge in the middle', (tester) async {
      await pumpSplit(tester, _split(), features: [_hinge(390)]);
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 390, 600));
      expect(rectOf(tester, _second), const Rect.fromLTWH(410, 0, 390, 600));
      // Nothing under the hinge: the divider is not shown.
      expect(rectOf(tester, _divider).isEmpty, isTrue);
      expect(renderOf(tester).splitsAtFeature, isTrue);
    });

    testWidgets('splits at an off-centre hinge', (tester) async {
      await pumpSplit(tester, _split(), features: [_hinge(250, width: 34)]);
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 250, 600));
      expect(rectOf(tester, _second), const Rect.fromLTWH(284, 0, 516, 600));
    });

    testWidgets('splits at a half-opened vertical fold without a gap', (
      tester,
    ) async {
      await pumpSplit(tester, _split(), features: [_verticalFold(300)]);
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 300, 600));
      expect(rectOf(tester, _second), const Rect.fromLTWH(300, 0, 500, 600));
    });

    testWidgets('converts the feature into its own coordinates', (
      tester,
    ) async {
      // The box starts 100 px in (a navigation rail, padding).
      await pumpSplit(
        tester,
        _split(),
        features: [_hinge(390)],
        padding: const EdgeInsets.fromLTRB(100, 50, 20, 0),
      );
      expect(rectOf(tester, _first), const Rect.fromLTWH(100, 50, 290, 550));
      expect(rectOf(tester, _second), const Rect.fromLTWH(410, 50, 370, 550));
    });

    testWidgets('puts the first pane above a horizontal half-opened fold', (
      tester,
    ) async {
      // Side by side without the fold; the fold wins.
      await pumpSplit(tester, _split(), features: [_horizontalFold(240)]);
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 800, 240));
      expect(rectOf(tester, _second), const Rect.fromLTWH(0, 240, 800, 360));
      expect(renderOf(tester).splitsAtFeature, isTrue);
    });

    testWidgets('stacks at a tabletop fold on a phone-width window', (
      tester,
    ) async {
      await pumpSplit(
        tester,
        _split(),
        size: const Size(400, 900),
        features: [_horizontalFold(450, width: 400)],
      );
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 400, 450));
      expect(rectOf(tester, _second), const Rect.fromLTWH(0, 450, 400, 450));
    });

    testWidgets('ignores a feature outside its box', (tester) async {
      await pumpSplit(
        tester,
        Align(
          alignment: AlignmentDirectional.topStart,
          child: SizedBox(width: 300, height: 200, child: _split(gap: 0)),
        ),
        features: [_hinge(500), _horizontalFold(400)],
      );
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 150, 200));
      expect(rectOf(tester, _second), const Rect.fromLTWH(150, 0, 150, 200));
      expect(renderOf(tester).splitsAtFeature, isFalse);
    });

    testWidgets('ignores a feature that only touches its edge', (tester) async {
      // The hinge would leave the first pane no space.
      await pumpSplit(tester, _split(gap: 0), features: [_hinge(0)]);
      expect(rectOf(tester, _first).width, 400);
      expect(renderOf(tester).splitsAtFeature, isFalse);
    });

    testWidgets('ignores a vertical feature that misses its box vertically', (
      tester,
    ) async {
      await pumpSplit(
        tester,
        Align(
          alignment: AlignmentDirectional.topStart,
          child: SizedBox(width: 800, height: 200, child: _split(gap: 0)),
        ),
        features: [
          const DisplayFeature(
            bounds: Rect.fromLTWH(390, 300, 20, 300),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.unknown,
          ),
        ],
      );
      expect(renderOf(tester).splitsAtFeature, isFalse);
    });

    testWidgets('ignores a flat fold', (tester) async {
      await pumpSplit(
        tester,
        _split(),
        features: [
          _verticalFold(300, state: DisplayFeatureState.postureFlat),
          _horizontalFold(300, state: DisplayFeatureState.postureFlat),
        ],
      );
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 399.5, 600));
      expect(rectOf(tester, _divider).width, 1);
      expect(renderOf(tester).splitsAtFeature, isFalse);
    });

    testWidgets('follows only the allowed fold directions', (tester) async {
      await pumpSplit(
        tester,
        _split(gap: 0, foldDirections: const {Axis.horizontal}),
        features: [_horizontalFold(240)],
      );
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 400, 600));
      expect(renderOf(tester).splitsAtFeature, isFalse);
    });

    testWidgets('puts the start pane on the right in RTL', (tester) async {
      await pumpSplit(tester, _split(), textDirection: TextDirection.rtl);
      expect(rectOf(tester, _first), const Rect.fromLTWH(400.5, 0, 399.5, 600));
      expect(rectOf(tester, _divider), const Rect.fromLTWH(399.5, 0, 1, 600));
      expect(rectOf(tester, _second), const Rect.fromLTWH(0, 0, 399.5, 600));
    });

    testWidgets('splits at a hinge in RTL with the start pane on the right', (
      tester,
    ) async {
      await pumpSplit(
        tester,
        _split(),
        textDirection: TextDirection.rtl,
        features: [_hinge(250, width: 34)],
      );
      expect(rectOf(tester, _first), const Rect.fromLTWH(284, 0, 516, 600));
      expect(rectOf(tester, _second), const Rect.fromLTWH(0, 0, 250, 600));
    });

    testWidgets('in a vertical scroll view follows only vertical hinges', (
      tester,
    ) async {
      Widget scrolling() => SingleChildScrollView(
        child: _split(
          gap: 24,
          withDivider: false,
          crossAxisAlignment: CrossAxisAlignment.start,
          first: const SizedBox(key: _first, height: 900),
          second: const SizedBox(key: _second, height: 300),
        ),
      );
      await pumpSplit(tester, scrolling(), features: [_horizontalFold(300)]);
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 388, 900));
      expect(rectOf(tester, _second), const Rect.fromLTWH(412, 0, 388, 300));

      await pumpSplit(tester, scrolling(), features: [_hinge(390)]);
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 390, 900));
      expect(rectOf(tester, _second), const Rect.fromLTWH(410, 0, 390, 300));
      // Scrolling does not move the split.
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -200),
      );
      await tester.pump();
      expect(rectOf(tester, _first).left, 0);
      expect(rectOf(tester, _second).left, 410);
    });

    testWidgets('in a padded list takes the padding into account', (
      tester,
    ) async {
      await pumpSplit(
        tester,
        ListView(
          padding: const EdgeInsets.only(left: 100, top: 20),
          children: [
            _split(
              gap: 0,
              crossAxisAlignment: CrossAxisAlignment.start,
              first: const SizedBox(key: _first, height: 50),
              second: const SizedBox(key: _second, height: 50),
            ),
          ],
        ),
        features: [_hinge(390)],
      );
      expect(rectOf(tester, _first), const Rect.fromLTWH(100, 20, 290, 50));
      expect(rectOf(tester, _second), const Rect.fromLTWH(410, 20, 390, 50));
    });

    testWidgets('aligns the panes across the main axis', (tester) async {
      Widget aligned(CrossAxisAlignment alignment, Axis direction) => Center(
        child: SizedBox(
          width: 400,
          height: 400,
          child: _split(
            direction: direction,
            gap: 0,
            crossAxisAlignment: alignment,
            first: const SizedBox(key: _first, width: 100, height: 100),
            second: const SizedBox(key: _second, width: 200, height: 200),
          ),
        ),
      );
      // The split is 400 x 400 at (200, 100).
      await pumpSplit(
        tester,
        aligned(CrossAxisAlignment.center, Axis.horizontal),
      );
      expect(rectOf(tester, _first), const Rect.fromLTWH(200, 250, 200, 100));
      await pumpSplit(tester, aligned(CrossAxisAlignment.end, Axis.horizontal));
      expect(rectOf(tester, _first), const Rect.fromLTWH(200, 400, 200, 100));
      await pumpSplit(tester, aligned(CrossAxisAlignment.start, Axis.vertical));
      expect(rectOf(tester, _first), const Rect.fromLTWH(200, 100, 100, 200));
      await pumpSplit(
        tester,
        aligned(CrossAxisAlignment.start, Axis.vertical),
        textDirection: TextDirection.rtl,
      );
      expect(rectOf(tester, _first), const Rect.fromLTWH(500, 100, 100, 200));
    });

    testWidgets('takes the natural size along an unbounded main axis', (
      tester,
    ) async {
      Widget unbounded() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: _split(
          gap: 10,
          first: const SizedBox(key: _first, width: 100),
          second: const SizedBox(key: _second, width: 150),
        ),
      );
      await pumpSplit(tester, unbounded(), features: [_hinge(390)]);
      expect(rectOf(tester, _first), const Rect.fromLTWH(0, 0, 100, 600));
      expect(rectOf(tester, _divider), const Rect.fromLTWH(100, 0, 10, 600));
      expect(rectOf(tester, _second), const Rect.fromLTWH(110, 0, 150, 600));

      await pumpSplit(tester, unbounded(), textDirection: TextDirection.rtl);
      // Scrolled to the end that comes first in RTL.
      final first = rectOf(tester, _first);
      final second = rectOf(tester, _second);
      expect(first.width, 100);
      expect(second.width, 150);
      expect(first.left, second.right + 10);
    });

    testWidgets('follows the box when it moves', (tester) async {
      Widget at(double start) => Padding(
        padding: EdgeInsetsDirectional.only(start: start),
        child: _split(gap: 0),
      );
      await pumpSplit(tester, at(0), features: [_hinge(390)]);
      expect(rectOf(tester, _first).right, 390);

      // Same size, new position: corrected after the next frame.
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: const Size(800, 600),
            displayFeatures: [_hinge(390)],
          ),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Padding(
              padding: const EdgeInsets.only(left: 90),
              child: SizedBox(width: 710, child: at(0)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(rectOf(tester, _first), const Rect.fromLTWH(90, 0, 300, 600));
      expect(rectOf(tester, _second), const Rect.fromLTWH(410, 0, 390, 600));
    });

    testWidgets('updates when its properties change', (tester) async {
      await pumpSplit(tester, _split());
      await pumpSplit(
        tester,
        _split(
          direction: Axis.vertical,
          firstFlex: 3,
          gap: 0,
          crossAxisAlignment: CrossAxisAlignment.center,
          foldDirections: const {Axis.vertical},
        ),
        textDirection: TextDirection.rtl,
        features: [_hinge(390)],
      );
      final render = renderOf(tester);
      expect(render.direction, Axis.vertical);
      expect(render.firstFlex, 3);
      expect(render.secondFlex, 1);
      expect(render.gap, 0);
      expect(render.crossAxisAlignment, CrossAxisAlignment.center);
      expect(render.foldDirections, {Axis.vertical});
      expect(render.textDirection, TextDirection.rtl);
      expect(render.features, [_hinge(390).bounds]);
      // A vertical hinge is not followed: no horizontal fold direction.
      // Centred across: the empty pane has no width of its own.
      expect(rectOf(tester, _first), const Rect.fromLTWH(400, 0, 0, 450));
      await pumpSplit(tester, _split(secondFlex: 3, gap: 0));
      expect(rectOf(tester, _first).width, 200);
    });

    testWidgets('hit tests each pane', (tester) async {
      final taps = <String>[];
      await pumpSplit(
        tester,
        _split(
          first: GestureDetector(
            key: _first,
            behavior: HitTestBehavior.opaque,
            onTap: () => taps.add('first'),
          ),
          second: GestureDetector(
            key: _second,
            behavior: HitTestBehavior.opaque,
            onTap: () => taps.add('second'),
          ),
        ),
        features: [_hinge(390)],
      );
      await tester.tapAt(const Offset(100, 300));
      await tester.tapAt(const Offset(700, 300));
      await tester.tapAt(const Offset(400, 300));
      expect(taps, ['first', 'second']);
    });

    testWidgets('reports intrinsic sizes, dry layout and baselines', (
      tester,
    ) async {
      await pumpSplit(
        tester,
        Center(
          child: IntrinsicHeight(
            child: _split(
              gap: 10,
              first: const SizedBox(key: _first, width: 50, height: 40),
              second: const Text('x', key: _second),
            ),
          ),
        ),
      );
      final render = renderOf(tester);
      expect(render.getMinIntrinsicWidth(100), greaterThanOrEqualTo(60));
      expect(render.getMaxIntrinsicWidth(100), greaterThanOrEqualTo(60));
      expect(render.getMinIntrinsicHeight(210), 40);
      expect(render.getMaxIntrinsicHeight(210), 40);
      expect(render.getMinIntrinsicHeight(double.infinity), 40);
      expect(
        render.getDryLayout(const BoxConstraints(maxWidth: 300, maxHeight: 80)),
        const Size(300, 80),
      );
      expect(
        render.getDryLayout(const BoxConstraints(maxWidth: 300)),
        const Size(300, 40),
      );
      expect(
        render.getDryBaseline(
          const BoxConstraints(maxWidth: 300, maxHeight: 80),
          TextBaseline.alphabetic,
        ),
        isNull,
      );

      await pumpSplit(
        tester,
        Center(
          child: _split(
            direction: Axis.vertical,
            gap: 10,
            first: const Text('x', key: _first),
            second: const SizedBox(key: _second, width: 50, height: 40),
          ),
        ),
      );
      final vertical = renderOf(tester);
      expect(vertical.getMinIntrinsicWidth(100), 50);
      expect(vertical.getMaxIntrinsicWidth(100), 50);
      expect(vertical.getMinIntrinsicHeight(100), greaterThan(50));
      expect(vertical.getMaxIntrinsicHeight(100), greaterThan(50));
      expect(
        vertical.getDryBaseline(
          const BoxConstraints(maxWidth: 300, maxHeight: 200),
          TextBaseline.alphabetic,
        ),
        isNotNull,
      );
    });

    testWidgets('aligns by the baseline of the first pane', (tester) async {
      const sibling = Key('sibling');
      await pumpSplit(
        tester,
        Align(
          alignment: AlignmentDirectional.topStart,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              const Text('x', key: sibling),
              SizedBox(
                height: 200,
                child: _split(
                  direction: Axis.vertical,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  first: const Padding(
                    padding: EdgeInsets.only(top: 30),
                    child: Text('x', key: _first),
                  ),
                  second: const SizedBox(key: _second, width: 50),
                ),
              ),
              // Without a baseline in its first pane.
              _split(
                gap: 0,
                first: const SizedBox(width: 10, height: 10),
                second: const SizedBox(width: 10, height: 10),
              ),
            ],
          ),
        ),
      );
      expect(
        tester.getTopLeft(find.byKey(sibling)).dy,
        tester.getTopLeft(find.byKey(_first)).dy,
      );
      expect(tester.getTopLeft(find.byKey(sibling)).dy, 30);
    });

    testWidgets('describes itself for debugging', (tester) async {
      await pumpSplit(tester, _split(), features: [_hinge(390)]);
      final description = renderOf(tester).toStringDeep();
      expect(description, contains('direction: horizontal'));
      expect(description, contains('splits at a display feature'));
    });
  });
}
