import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Whether [feature] separates the screen into two areas: a hinge (in any
/// posture), or a fold while the device is half opened (book or tabletop
/// posture). A flat fold and display cutouts do not separate anything.
bool isSeparatingDisplayFeature(DisplayFeature feature) =>
    switch (feature.type) {
      DisplayFeatureType.hinge => true,
      DisplayFeatureType.fold =>
        feature.state == DisplayFeatureState.postureHalfOpened,
      DisplayFeatureType.cutout || DisplayFeatureType.unknown => false,
    };

/// Two panes next to each other ([Axis.horizontal]: [first] at the start,
/// [second] at the end) or one above the other ([Axis.vertical]: [first]
/// on top) that split exactly at a hinge or a half-opened fold.
///
/// Without such a display feature crossing this widget's box it behaves
/// like a [Row] (or [Column]) of two [Expanded] children with flex
/// [firstFlex] and [secondFlex] and [gap] logical pixels between them, in
/// which [divider] (e.g. a hairline) is laid out.
///
/// When `MediaQuery.displayFeaturesOf` has a separating feature
/// ([isSeparatingDisplayFeature]) that crosses the box, each pane gets
/// one side of it and the feature itself (the hinge width, nothing for a
/// zero-width fold) becomes the gap: nothing is placed under a hinge and
/// [divider] is not shown. A vertical feature (book posture) puts the
/// panes side by side, a horizontal one (tabletop posture) puts [first]
/// above [second], whatever [direction] is, as long as the feature's
/// split direction is in [foldDirections] and this box is bounded along
/// it (inside a vertical scroll view only vertical features are followed).
/// A feature is ignored when it would leave one pane without space.
///
/// The feature bounds are in window coordinates; the box's position is
/// taken from layout offsets (route transitions and scrolling do not move
/// the split). The position is only known once the box is laid out, so
/// the first frame on a foldable may lay the panes out without the
/// feature and correct them on the next frame.
class FoldAwareSplit extends StatelessWidget {
  const new({
    required this.first,
    required this.second,
    this.direction = Axis.horizontal,
    this.firstFlex = 1,
    this.secondFlex = 1,
    this.gap = 0,
    this.divider,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
    this.foldDirections = const {Axis.horizontal, Axis.vertical},
    super.key,
  }) : assert(firstFlex > 0 && secondFlex > 0, 'Flex factors must be > 0'),
       assert(gap >= 0, 'The gap must not be negative'),
       assert(
         crossAxisAlignment != CrossAxisAlignment.baseline,
         'Baseline alignment is not supported',
       );

  /// The start pane (left in left-to-right text), or the top one.
  final Widget first;

  /// The end pane, or the bottom one.
  final Widget second;

  /// How the panes are arranged without a separating display feature.
  final Axis direction;

  /// Share of the space of [first] without a display feature.
  final int firstFlex;

  /// Share of the space of [second] without a display feature.
  final int secondFlex;

  /// Space between the panes without a display feature (logical pixels).
  final double gap;

  /// Laid out in the [gap] (its full cross extent) when the panes do not
  /// split at a display feature.
  final Widget? divider;

  /// How the panes are placed across [direction]; [CrossAxisAlignment.
  /// stretch] (the default) fills a bounded cross axis.
  final CrossAxisAlignment crossAxisAlignment;

  /// The split directions that may follow a display feature:
  /// [Axis.horizontal] (side by side) at vertical hinges and folds,
  /// [Axis.vertical] (one above the other) at horizontal ones.
  final Set<Axis> foldDirections;

  /// The separating display features of the screen
  /// ([isSeparatingDisplayFeature]).
  static List<DisplayFeature> separatingFeaturesOf(BuildContext context) => [
    for (final feature in MediaQuery.displayFeaturesOf(context))
      if (isSeparatingDisplayFeature(feature)) feature,
  ];

  /// How the first separating display feature of the screen splits it
  /// (whether it crosses a given box or not): [Axis.horizontal] (side by
  /// side) for a vertical hinge or fold, [Axis.vertical] (one above the
  /// other) for a horizontal one, or null without one.
  static Axis? featureDirectionOf(BuildContext context) {
    final features = separatingFeaturesOf(context);
    if (features.isEmpty) return null;
    return splitDirectionOf(features.first.bounds);
  }

  /// The split direction of a feature with [bounds]: [Axis.horizontal]
  /// (side by side) when it is at least as tall as wide.
  static Axis splitDirectionOf(Rect bounds) =>
      bounds.height >= bounds.width ? Axis.horizontal : Axis.vertical;

  @override
  Widget build(BuildContext context) {
    return _FoldAwareSplitLayout(
      direction: direction,
      firstFlex: firstFlex,
      secondFlex: secondFlex,
      gap: gap,
      crossAxisAlignment: crossAxisAlignment,
      foldDirections: foldDirections,
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      features: [
        for (final feature in separatingFeaturesOf(context)) feature.bounds,
      ],
      first: first,
      second: second,
      divider: divider,
    );
  }
}

enum _SplitSlot { first, divider, second }

class _FoldAwareSplitLayout
    extends SlottedMultiChildRenderObjectWidget<_SplitSlot, RenderBox> {
  const new({
    required this.direction,
    required this.firstFlex,
    required this.secondFlex,
    required this.gap,
    required this.crossAxisAlignment,
    required this.foldDirections,
    required this.textDirection,
    required this.features,
    required this.first,
    required this.second,
    required this.divider,
  });

  final Axis direction;
  final int firstFlex;
  final int secondFlex;
  final double gap;
  final CrossAxisAlignment crossAxisAlignment;
  final Set<Axis> foldDirections;
  final TextDirection textDirection;
  final List<Rect> features;
  final Widget first;
  final Widget second;
  final Widget? divider;

  @override
  Iterable<_SplitSlot> get slots => _SplitSlot.values;

  @override
  Widget? childForSlot(_SplitSlot slot) => switch (slot) {
    _SplitSlot.first => first,
    _SplitSlot.divider => divider,
    _SplitSlot.second => second,
  };

  @override
  RenderFoldAwareSplit createRenderObject(BuildContext context) =>
      RenderFoldAwareSplit(
        direction: direction,
        firstFlex: firstFlex,
        secondFlex: secondFlex,
        gap: gap,
        crossAxisAlignment: crossAxisAlignment,
        foldDirections: foldDirections,
        textDirection: textDirection,
        features: features,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderFoldAwareSplit renderObject,
  ) {
    renderObject
      ..direction = direction
      ..firstFlex = firstFlex
      ..secondFlex = secondFlex
      ..gap = gap
      ..crossAxisAlignment = crossAxisAlignment
      ..foldDirections = foldDirections
      ..textDirection = textDirection
      ..features = features;
  }
}

/// Where the panes of a [RenderFoldAwareSplit] go along its main axis
/// (`axis`); `atFeature` tells whether they split at a display feature.
/// Extents are null along an unbounded main axis (the panes take their
/// natural size there). A record, so splits compare by value.
typedef _Split = ({
  Axis axis,
  bool atFeature,
  double firstStart,
  double? firstExtent,
  double secondStart,
  double? secondExtent,
  double dividerStart,
});

_Split _splitOf({
  required Axis axis,
  required bool atFeature,
  double firstStart = 0,
  double? firstExtent,
  double secondStart = 0,
  double? secondExtent,
  double dividerStart = 0,
}) => (
  axis: axis,
  atFeature: atFeature,
  firstStart: firstStart,
  firstExtent: firstExtent,
  secondStart: secondStart,
  secondExtent: secondExtent,
  dividerStart: dividerStart,
);

/// The outcome of laying out a [RenderFoldAwareSplit] (or of a dry run).
typedef _SplitLayout = ({
  Size size,
  _Split split,
  BoxConstraints firstConstraints,
  BoxConstraints secondConstraints,
  Offset firstOffset,
  Offset secondOffset,
  Offset dividerOffset,
  Size dividerSize,
});

/// Render object of [FoldAwareSplit].
class RenderFoldAwareSplit extends RenderBox
    with SlottedContainerRenderObjectMixin<_SplitSlot, RenderBox> {
  new({
    required this._direction,
    required this._firstFlex,
    required this._secondFlex,
    required this._gap,
    required this._crossAxisAlignment,
    required this._foldDirections,
    required this._textDirection,
    required this._features,
  });

  /// Consecutive corrections of the split after the position of the box
  /// changed, before giving up until the next regular layout.
  static const _maxCorrections = 3;

  Axis get direction => _direction;
  Axis _direction;
  set direction(Axis value) {
    if (_direction == value) return;
    _direction = value;
    markNeedsLayout();
  }

  int get firstFlex => _firstFlex;
  int _firstFlex;
  set firstFlex(int value) {
    if (_firstFlex == value) return;
    _firstFlex = value;
    markNeedsLayout();
  }

  int get secondFlex => _secondFlex;
  int _secondFlex;
  set secondFlex(int value) {
    if (_secondFlex == value) return;
    _secondFlex = value;
    markNeedsLayout();
  }

  double get gap => _gap;
  double _gap;
  set gap(double value) {
    if (_gap == value) return;
    _gap = value;
    markNeedsLayout();
  }

  CrossAxisAlignment get crossAxisAlignment => _crossAxisAlignment;
  CrossAxisAlignment _crossAxisAlignment;
  set crossAxisAlignment(CrossAxisAlignment value) {
    if (_crossAxisAlignment == value) return;
    _crossAxisAlignment = value;
    markNeedsLayout();
  }

  Set<Axis> get foldDirections => _foldDirections;
  Set<Axis> _foldDirections;
  set foldDirections(Set<Axis> value) {
    if (setEquals(_foldDirections, value)) return;
    _foldDirections = value;
    markNeedsLayout();
  }

  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  /// Bounds of the separating display features, in window coordinates.
  List<Rect> get features => _features;
  List<Rect> _features;
  set features(List<Rect> value) {
    if (listEquals(_features, value)) return;
    _features = value;
    markNeedsLayout();
  }

  RenderBox? get _first => childForSlot(_SplitSlot.first);
  RenderBox? get _second => childForSlot(_SplitSlot.second);
  RenderBox? get _divider => childForSlot(_SplitSlot.divider);

  /// The split of the last layout.
  _Split? _split;

  /// Whether the last layout showed the divider (no display feature).
  bool _dividerVisible = false;

  bool _correctionScheduled = false;
  bool _correcting = false;
  int _corrections = 0;

  /// Whether the panes of the last layout split at a display feature.
  @visibleForTesting
  bool get splitsAtFeature => _split?.atFeature ?? false;

  /// This box's top-left corner in window coordinates, from the layout
  /// offsets of it and its ancestors: paint-only transforms (route
  /// transitions, scroll offsets) are left out.
  Offset _layoutOrigin() {
    var origin = Offset.zero;
    RenderObject node = this;
    var parent = node.parent;
    while (parent != null) {
      switch (node.parentData) {
        case final BoxParentData data:
          origin += data.offset;
        case final SliverPhysicalParentData data:
          origin += data.paintOffset;
      }
      node = parent;
      parent = node.parent;
    }
    return origin;
  }

  _Split _resolveSplit(BoxConstraints constraints) {
    if (_features.isNotEmpty) {
      final origin = _layoutOrigin();
      for (final bounds in _features) {
        final split = _splitAt(bounds.shift(-origin), constraints);
        if (split != null) return split;
      }
    }
    return _defaultSplit(constraints);
  }

  /// The split at a feature with [local] bounds (in this box's
  /// coordinates), or null when it does not cross the box, its direction
  /// is not followed or it would leave a pane without space.
  _Split? _splitAt(Rect local, BoxConstraints constraints) {
    final axis = FoldAwareSplit.splitDirectionOf(local);
    if (!_foldDirections.contains(axis)) return null;
    final horizontal = axis == Axis.horizontal;
    final mainExtent = horizontal
        ? constraints.maxWidth
        : constraints.maxHeight;
    final crossExtent = horizontal
        ? constraints.maxHeight
        : constraints.maxWidth;
    if (!mainExtent.isFinite) return null;
    final (crossStart, crossEnd) = horizontal
        ? (local.top, local.bottom)
        : (local.left, local.right);
    // Across the split: the feature must overlap the box (always true for
    // real features, which span the window).
    if (crossExtent.isFinite && (crossStart >= crossExtent || crossEnd <= 0)) {
      return null;
    }
    final (start, end) = horizontal
        ? (local.left, local.right)
        : (local.top, local.bottom);
    final before = start;
    final after = mainExtent - end;
    if (before <= 0 || after <= 0) return null;
    if (horizontal && _textDirection == TextDirection.rtl) {
      return _splitOf(
        axis: axis,
        atFeature: true,
        firstStart: end,
        firstExtent: after,
        secondExtent: before,
      );
    }
    return _splitOf(
      axis: axis,
      atFeature: true,
      firstExtent: before,
      secondStart: end,
      secondExtent: after,
    );
  }

  /// The split without a display feature: [firstFlex] to [secondFlex]
  /// with [gap] between (natural sizes along an unbounded main axis).
  _Split _defaultSplit(BoxConstraints constraints) {
    final horizontal = _direction == Axis.horizontal;
    final mainExtent = horizontal
        ? constraints.maxWidth
        : constraints.maxHeight;
    if (!mainExtent.isFinite) {
      return _splitOf(axis: _direction, atFeature: false);
    }
    final available = math.max(0, mainExtent - _gap).toDouble();
    final firstExtent = available * _firstFlex / (_firstFlex + _secondFlex);
    final secondExtent = available - firstExtent;
    if (horizontal && _textDirection == TextDirection.rtl) {
      return _splitOf(
        axis: _direction,
        atFeature: false,
        firstStart: secondExtent + _gap,
        firstExtent: firstExtent,
        secondExtent: secondExtent,
        dividerStart: secondExtent,
      );
    }
    return _splitOf(
      axis: _direction,
      atFeature: false,
      firstExtent: firstExtent,
      secondStart: firstExtent + _gap,
      secondExtent: secondExtent,
      dividerStart: firstExtent,
    );
  }

  _SplitLayout _computeLayout(
    BoxConstraints constraints,
    ChildLayouter layoutChild,
  ) {
    final split = _resolveSplit(constraints);
    final horizontal = split.axis == Axis.horizontal;
    final maxMain = horizontal ? constraints.maxWidth : constraints.maxHeight;
    final maxCross = horizontal ? constraints.maxHeight : constraints.maxWidth;
    final stretch =
        _crossAxisAlignment == CrossAxisAlignment.stretch && maxCross.isFinite;

    BoxConstraints paneConstraints(double? extent) {
      final minCross = stretch ? maxCross : 0.0;
      return horizontal
          ? BoxConstraints(
              minWidth: extent ?? 0,
              maxWidth: extent ?? double.infinity,
              minHeight: minCross,
              maxHeight: maxCross,
            )
          : BoxConstraints(
              minWidth: minCross,
              maxWidth: maxCross,
              minHeight: extent ?? 0,
              maxHeight: extent ?? double.infinity,
            );
    }

    double mainOf(Size size) => horizontal ? size.width : size.height;
    double crossOf(Size size) => horizontal ? size.height : size.width;

    final firstConstraints = paneConstraints(split.firstExtent);
    final secondConstraints = paneConstraints(split.secondExtent);
    final first = _first;
    final second = _second;
    final firstSize = first == null
        ? Size.zero
        : layoutChild(first, firstConstraints);
    final secondSize = second == null
        ? Size.zero
        : layoutChild(second, secondConstraints);

    // Along an unbounded main axis the panes keep their natural size.
    final firstExtent = split.firstExtent ?? mainOf(firstSize);
    final secondExtent = split.secondExtent ?? mainOf(secondSize);
    final mainExtent = maxMain.isFinite
        ? maxMain
        : firstExtent + _gap + secondExtent;
    final rtl = horizontal && _textDirection == TextDirection.rtl;
    final (firstStart, secondStart, dividerStart) = maxMain.isFinite
        ? (split.firstStart, split.secondStart, split.dividerStart)
        : rtl
        ? (secondExtent + _gap, 0.0, secondExtent)
        : (0.0, firstExtent + _gap, firstExtent);

    final size = constraints.constrain(
      horizontal
          ? Size(
              mainExtent,
              stretch
                  ? maxCross
                  : math.max(firstSize.height, secondSize.height),
            )
          : Size(
              stretch ? maxCross : math.max(firstSize.width, secondSize.width),
              mainExtent,
            ),
    );
    final crossExtent = crossOf(size);

    // Across the main axis; start is the top, or the reading start.
    double crossStart(Size child) {
      final free = crossExtent - crossOf(child);
      final fromStart = switch (_crossAxisAlignment) {
        CrossAxisAlignment.start ||
        CrossAxisAlignment.stretch ||
        CrossAxisAlignment.baseline => 0.0,
        CrossAxisAlignment.center => free / 2,
        CrossAxisAlignment.end => free,
      };
      final flip = !horizontal && _textDirection == TextDirection.rtl;
      return flip ? free - fromStart : fromStart;
    }

    Offset offsetAt(double main, double cross) =>
        horizontal ? Offset(main, cross) : Offset(cross, main);

    final dividerVisible = !split.atFeature && _gap > 0;
    return (
      size: size,
      split: split,
      firstConstraints: firstConstraints,
      secondConstraints: secondConstraints,
      firstOffset: offsetAt(firstStart, crossStart(firstSize)),
      secondOffset: offsetAt(secondStart, crossStart(secondSize)),
      dividerOffset: offsetAt(dividerStart, 0),
      dividerSize: dividerVisible
          ? (horizontal ? Size(_gap, crossExtent) : Size(crossExtent, _gap))
          : Size.zero,
    );
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _computeLayout(constraints, ChildLayoutHelper.dryLayoutChild).size;

  @override
  double? computeDryBaseline(
    covariant BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final first = _first;
    if (first == null) return null;
    final layout = _computeLayout(
      constraints,
      ChildLayoutHelper.dryLayoutChild,
    );
    final distance = first.getDryBaseline(layout.firstConstraints, baseline);
    return distance == null ? null : distance + layout.firstOffset.dy;
  }

  @override
  void performLayout() {
    if (!_correcting) _corrections = 0;
    _correcting = false;
    final layout = _computeLayout(constraints, ChildLayoutHelper.layoutChild);
    size = layout.size;
    _split = layout.split;
    _dividerVisible = layout.dividerSize != Size.zero;
    if (_first case final first?) {
      (first.parentData! as BoxParentData).offset = layout.firstOffset;
    }
    if (_second case final second?) {
      (second.parentData! as BoxParentData).offset = layout.secondOffset;
    }
    if (_divider case final divider?) {
      divider.layout(BoxConstraints.tight(layout.dividerSize));
      (divider.parentData! as BoxParentData).offset = layout.dividerOffset;
    }
  }

  /// After layout, the offsets of this box and its ancestors are final:
  /// lays out again (after this frame) when the box has moved relative to
  /// a display feature since its layout.
  void _checkPosition() {
    if (_features.isEmpty || _correctionScheduled) return;
    if (_corrections >= _maxCorrections) return;
    if (_resolveSplit(constraints) == _split) return;
    _correctionScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _correctionScheduled = false;
      if (!attached) return;
      _corrections++;
      _correcting = true;
      markNeedsLayout();
    }, debugLabel: 'FoldAwareSplit.relayout');
  }

  Iterable<RenderBox> get _visibleChildren => [
    ?_first,
    if (_dividerVisible) ?_divider,
    ?_second,
  ];

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in _visibleChildren) {
      final data = child.parentData! as BoxParentData;
      context.paintChild(child, offset + data.offset);
    }
    _checkPosition();
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in _visibleChildren.toList().reversed) {
      final data = child.parentData! as BoxParentData;
      final hit = result.addWithPaintOffset(
        offset: data.offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    _visibleChildren.forEach(visitor);
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final first = _first;
    if (first == null) return null;
    final distance = first.getDistanceToActualBaseline(baseline);
    final data = first.parentData! as BoxParentData;
    return distance == null ? null : distance + data.offset.dy;
  }

  // Intrinsic sizes ignore display features (they depend on the position).

  /// The panes' extents along [extent] of the main axis without a feature.
  (double, double) _intrinsicExtents(double extent) {
    if (!extent.isFinite) return (double.infinity, double.infinity);
    final available = math.max(0, extent - _gap).toDouble();
    final first = available * _firstFlex / (_firstFlex + _secondFlex);
    return (first, available - first);
  }

  double _sum(double Function(RenderBox child) of) =>
      (_first == null ? 0 : of(_first!)) +
      _gap +
      (_second == null ? 0 : of(_second!));

  double _max(double Function(RenderBox child, double extent) of, double e) {
    final (first, second) = _intrinsicExtents(e);
    return math.max(
      _first == null ? 0 : of(_first!, first),
      _second == null ? 0 : of(_second!, second),
    );
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _direction == Axis.horizontal
      ? _sum((child) => child.getMinIntrinsicWidth(height))
      : math.max(
          _first?.getMinIntrinsicWidth(height) ?? 0,
          _second?.getMinIntrinsicWidth(height) ?? 0,
        );

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _direction == Axis.horizontal
      ? _sum((child) => child.getMaxIntrinsicWidth(height))
      : math.max(
          _first?.getMaxIntrinsicWidth(height) ?? 0,
          _second?.getMaxIntrinsicWidth(height) ?? 0,
        );

  @override
  double computeMinIntrinsicHeight(double width) => _direction == Axis.vertical
      ? _sum((child) => child.getMinIntrinsicHeight(width))
      : _max((child, extent) => child.getMinIntrinsicHeight(extent), width);

  @override
  double computeMaxIntrinsicHeight(double width) => _direction == Axis.vertical
      ? _sum((child) => child.getMaxIntrinsicHeight(width))
      : _max((child, extent) => child.getMaxIntrinsicHeight(extent), width);

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(EnumProperty<Axis>('direction', direction))
      ..add(IntProperty('firstFlex', firstFlex))
      ..add(IntProperty('secondFlex', secondFlex))
      ..add(DoubleProperty('gap', gap))
      ..add(
        EnumProperty<CrossAxisAlignment>(
          'crossAxisAlignment',
          crossAxisAlignment,
        ),
      )
      ..add(IterableProperty<Axis>('foldDirections', foldDirections))
      ..add(EnumProperty<TextDirection>('textDirection', textDirection))
      ..add(IterableProperty<Rect>('features', features))
      ..add(
        FlagProperty(
          'splitsAtFeature',
          value: splitsAtFeature,
          ifTrue: 'splits at a display feature',
        ),
      );
  }
}
