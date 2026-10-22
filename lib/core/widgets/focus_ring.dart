import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';

/// Width (logical pixels) of a keyboard focus ring.
const double kFocusRingWidth = 2;

/// Space (logical pixels) between a control and its focus ring.
const double kFocusRingGap = 2;

/// Whether focus rings show: while a keyboard (or a mouse) is in use, not
/// after touch ([FocusManager.highlightMode]).
bool focusRingsVisible() =>
    FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

/// Whether [node] is the focus of an editable text field, which shows focus
/// with its own border (`InputDecorationTheme.focusedBorder`) or with a
/// [FocusRing.field] around it, and with its caret.
bool isTextFieldFocus(FocusNode node) {
  final context = node.context;
  if (context == null || !context.mounted) return false;
  return context.widget is EditableText ||
      context.findAncestorStateOfType<EditableTextState>() != null;
}

/// The outline of a focus ring around [rect], the bounds of a control of
/// [shape]: [kFocusRingGap] outside it, or with [inside] just inside its
/// edge (where there is no room outside, e.g. a list row at the edge of
/// the screen). Stroke it [kFocusRingWidth] wide.
///
/// Rounded rectangles keep concentric corners.
Path focusRingPath(
  ShapeBorder shape,
  Rect rect, {
  bool inside = false,
  TextDirection? textDirection,
}) {
  final delta = inside
      ? -kFocusRingWidth / 2
      : kFocusRingGap + kFocusRingWidth / 2;
  final ring = switch (shape) {
    RoundedRectangleBorder(:final borderRadius) => RoundedRectangleBorder(
      borderRadius: _grow(borderRadius.resolve(textDirection), delta),
    ),
    _ => shape,
  };
  return ring.getOuterPath(rect.inflate(delta), textDirection: textDirection);
}

BorderRadius _grow(BorderRadius radius, double delta) {
  Radius grow(Radius r) =>
      Radius.elliptical(math.max(0, r.x + delta), math.max(0, r.y + delta));
  return BorderRadius.only(
    topLeft: grow(radius.topLeft),
    topRight: grow(radius.topRight),
    bottomLeft: grow(radius.bottomLeft),
    bottomRight: grow(radius.bottomRight),
  );
}

Paint _ringPaint(Color color) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = kFocusRingWidth;

/// Where and how [FocusRingLayer] draws the focus ring of a control, in
/// global (logical) coordinates.
@immutable
class FocusRingGeometry {
  const new({required this.path, required this.clip, required this.color});

  /// The ring's outline ([focusRingPath]), to stroke [kFocusRingWidth]
  /// wide.
  final Path path;

  /// The part of the screen where the control is visible (e.g. inside a
  /// scrolling list): the ring is clipped to it.
  final Rect clip;

  /// The accent (`ColorScheme.primary`) of the control's theme: at least
  /// 4.5:1 on the surfaces (WCAG 1.4.11 asks for 3:1).
  final Color color;

  /// How deep below an [InkResponse] its focus node sits (Actions, its
  /// scope and the ink well's own widgets).
  static const _maxInkDepth = 8;

  /// The ring of the control focused by [node] within [screen] (the global
  /// rect the ring may use), or null when [node] gets none: no control
  /// built on an ink well ([InkResponse]: buttons of every kind, chips,
  /// list tiles, menu items, navigation destinations, ...), a text field
  /// ([isTextFieldFocus]), a node a [FocusRing] draws itself, or a control
  /// that is not painted (an inactive tab).
  ///
  /// The ring follows the ink well's shape (`customBorder`, else its
  /// `borderRadius`, else a circle for an uncontained [InkResponse]) and
  /// highlight rect (e.g. a navigation bar's indicator).
  static FocusRingGeometry? of(FocusNode node, {required Rect screen}) {
    final context = node.context;
    if (node is FocusScopeNode || context == null || !context.mounted) {
      return null;
    }
    if (isTextFieldFocus(node) || FocusRing.claims(node)) return null;
    final ink = _inkResponseOf(context);
    final box = context.findRenderObject();
    if (ink == null || box is! RenderBox || !box.attached || !box.hasSize) {
      return null;
    }
    final clip = _visibleRect(box, screen);
    if (clip == null || clip.isEmpty) return null;

    final bounds = ink.getRectCallback(box)?.call() ?? Offset.zero & box.size;
    final ShapeBorder shape;
    if (ink.customBorder case final border?) {
      shape = border;
    } else if (ink.borderRadius case final radius?) {
      shape = RoundedRectangleBorder(borderRadius: radius);
    } else if (!ink.containedInkWell && ink.highlightShape == BoxShape.circle) {
      shape = const CircleBorder();
    } else {
      shape = const RoundedRectangleBorder();
    }
    final transform = box.getTransformTo(null);
    final outside = MatrixUtils.transformRect(
      transform,
      bounds.inflate(kFocusRingGap + kFocusRingWidth),
    );
    final textDirection = context
        .getInheritedWidgetOfExactType<Directionality>()
        ?.textDirection;
    final path = focusRingPath(
      shape,
      bounds,
      inside: !_contains(clip, outside),
      textDirection: textDirection,
    ).transform(transform.storage);
    final theme = context.findAncestorWidgetOfExactType<Theme>()?.data;
    return FocusRingGeometry(
      path: path,
      clip: clip,
      color: (theme ?? ThemeData.fallback()).colorScheme.primary,
    );
  }

  /// The ink well whose focus node's element is [context], if any.
  static InkResponse? _inkResponseOf(BuildContext context) {
    InkResponse? ink;
    var depth = 0;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is InkResponse) {
        ink = widget;
        return false;
      }
      // Another focus boundary: [context] is not the ink well's own node.
      if (widget is Focus) return false;
      return ++depth < _maxInkDepth;
    });
    return ink;
  }

  /// The global rect in which [box] is visible (its ancestors' clips within
  /// [screen]), or null when an ancestor does not paint it.
  static Rect? _visibleRect(RenderBox box, Rect screen) {
    var clip = screen;
    RenderObject child = box;
    var parent = child.parent;
    while (parent != null) {
      if (!parent.paintsChild(child) ||
          (parent is RenderIndexedStack && !_isShown(parent, child))) {
        return null;
      }
      if (parent.describeApproximatePaintClip(child) case final rect?) {
        clip = clip.intersect(
          MatrixUtils.transformRect(parent.getTransformTo(null), rect),
        );
      }
      child = parent;
      parent = child.parent;
    }
    return clip;
  }

  /// Whether [child] is the child [stack] shows.
  static bool _isShown(RenderIndexedStack stack, RenderObject child) {
    var index = 0;
    var current = stack.firstChild;
    while (current != null && current != child) {
      current = stack.childAfter(current);
      index++;
    }
    return index == stack.index;
  }

  static bool _contains(Rect outer, Rect inner) =>
      inner.left >= outer.left &&
      inner.top >= outer.top &&
      inner.right <= outer.right &&
      inner.bottom <= outer.bottom;
}

/// Draws a keyboard focus ring app-wide (WCAG 2.4.7): a [kFocusRingWidth]
/// accent ring [kFocusRingGap] around the control that has focus, while
/// focus is shown ([focusRingsVisible]: keyboard and mouse, never after
/// touch).
///
/// Every control built on an ink well gets one ([FocusRingGeometry.of]):
/// icon, text, filled, outlined and elevated buttons, segmented buttons,
/// chips, list tiles, menu items, navigation bar and rail destinations,
/// and custom `InkWell`s. Text fields show their own focused border;
/// switches get a ring in the theme; anything else can draw one with a
/// [FocusRing].
///
/// Place it above the app (it needs no theme: it takes the accent of the
/// focused control's theme). It paints above everything, clipped to where
/// the control is visible, and follows it while it scrolls or moves
/// without asking for frames of its own.
class FocusRingLayer extends StatefulWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  State<FocusRingLayer> createState() => _FocusRingLayerState();
}

class _FocusRingLayerState extends State<FocusRingLayer> {
  final _changes = _Changes();

  @override
  void initState() {
    super.initState();
    FocusManager.instance
      ..addListener(_changes.changed)
      ..addHighlightModeListener(_onHighlightMode);
  }

  void _onHighlightMode(FocusHighlightMode mode) => _changes.changed();

  @override
  void dispose() {
    FocusManager.instance
      ..removeListener(_changes.changed)
      ..removeHighlightModeListener(_onHighlightMode);
    _changes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        _FocusRingPaint(changes: _changes),
      ],
    );
  }
}

class _Changes extends ChangeNotifier {
  void changed() => notifyListeners();
}

class _FocusRingPaint extends LeafRenderObjectWidget {
  const new({required this.changes});

  final Listenable changes;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFocusRing(changes);
}

/// Paints the ring of the primary focus (see [FocusRingLayer]); it never
/// takes hits.
class _RenderFocusRing extends RenderBox {
  new(this._changes);

  /// Notifies of focus and highlight mode changes.
  final Listenable _changes;

  /// The pending callback that repaints the ring in the next frame.
  int? _nextFrame;

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _changes.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _changes.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final node = FocusManager.instance.primaryFocus;
    if (node == null || !focusRingsVisible()) return;
    final origin = localToGlobal(Offset.zero);
    final ring = FocusRingGeometry.of(node, screen: origin & size);
    if (ring == null) return;
    final shift = offset - origin;
    context.canvas
      ..save()
      ..clipRect(ring.clip.shift(shift))
      ..drawPath(ring.path.shift(shift), _ringPaint(ring.color))
      ..restore();
    // The control may move (a scroll, an animation) without anything
    // telling this layer: repaint along with the next frame, whenever one
    // comes (this never asks for one).
    _nextFrame ??= SchedulerBinding.instance.scheduleFrameCallback((_) {
      _nextFrame = null;
      // Removed meanwhile: nothing to paint.
      if (attached) markNeedsPaint();
    }, scheduleNewFrame: false);
  }
}

/// A focus ring around [child] that the app-wide [FocusRingLayer] cannot
/// draw: around a custom tappable that is not an ink well, or one whose
/// ring needs another [shape].
///
/// [FocusRing.new] shows while the first focusable control inside [child]
/// (not one nested in it) has focus, and [FocusRingLayer] leaves that
/// control to it. [FocusRing.field] shows while a text field inside has
/// focus, for fields that draw no border of their own (the composers).
/// Either shows only while focus is shown ([focusRingsVisible]) and while
/// [enabled].
///
/// The ring is [kFocusRingWidth] wide in the theme's accent,
/// [kFocusRingGap] outside [child] less its [margin].
class FocusRing extends StatefulWidget {
  const new({
    required this.child,
    this.shape = defaultShape,
    this.margin = EdgeInsets.zero,
    this.enabled = true,
    super.key,
  }) : fields = false;

  /// A ring around [child] while a text field inside it has focus.
  const new field({
    required this.child,
    this.shape = defaultShape,
    this.margin = EdgeInsets.zero,
    this.enabled = true,
    super.key,
  }) : fields = true;

  /// A rounded rectangle ([AppRadius.badge]).
  static const ShapeBorder defaultShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppRadius.badge)),
  );

  final Widget child;

  /// The shape of [child] (the ring follows it).
  final ShapeBorder shape;

  /// Space around the shape inside [child] (e.g. a card's margin).
  final EdgeInsetsGeometry margin;

  /// Whether the ring may show.
  final bool enabled;

  /// Whether the ring is for text fields inside [child] ([FocusRing.field]).
  final bool fields;

  /// Whether a [FocusRing] (not a [FocusRing.field]) draws the ring of
  /// [node], so [FocusRingLayer] leaves it out.
  static bool claims(FocusNode node) {
    for (final ancestor in node.ancestors) {
      final ring = _rings[ancestor];
      if (ring != null) return !ring.widget.fields && ring._owns(node);
    }
    return false;
  }

  @override
  State<FocusRing> createState() => _FocusRingState();
}

/// The mounted [FocusRing]s by their focus node.
final _rings = <FocusNode, _FocusRingState>{};

class _FocusRingState extends State<FocusRing> {
  final _node = FocusNode(
    debugLabel: 'FocusRing',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Whether focus is shown on a control this ring is for.
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _rings[_node] = this;
    FocusManager.instance
      ..addListener(_update)
      ..addHighlightModeListener(_onHighlightMode);
    _focused = _computeFocused();
  }

  @override
  void didUpdateWidget(FocusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fields != widget.fields) _focused = _computeFocused();
  }

  @override
  void dispose() {
    _rings.remove(_node);
    FocusManager.instance
      ..removeListener(_update)
      ..removeHighlightModeListener(_onHighlightMode);
    _node.dispose();
    super.dispose();
  }

  void _onHighlightMode(FocusHighlightMode mode) => _update();

  void _update() {
    final focused = _computeFocused();
    if (focused != _focused && mounted) setState(() => _focused = focused);
  }

  bool _computeFocused() {
    final focus = FocusManager.instance.primaryFocus;
    return focus != null && focusRingsVisible() && _owns(focus);
  }

  /// Whether this ring is for [focus]: a text field inside it (a field
  /// ring), else the first focusable node inside it.
  bool _owns(FocusNode focus) {
    if (widget.fields) {
      return isTextFieldFocus(focus) && focus.ancestors.contains(_node);
    }
    for (final ancestor in focus.ancestors) {
      if (ancestor == _node) return true;
      if (ancestor.canRequestFocus && !ancestor.skipTraversal) return false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      child: CustomPaint(
        foregroundPainter: widget.enabled && _focused
            ? _FocusRingPainter(
                shape: widget.shape,
                margin: widget.margin,
                color: Theme.of(context).colorScheme.primary,
                textDirection: Directionality.maybeOf(context),
              )
            : null,
        child: widget.child,
      ),
    );
  }
}

class _FocusRingPainter extends CustomPainter {
  const new({
    required this.shape,
    required this.margin,
    required this.color,
    required this.textDirection,
  });

  final ShapeBorder shape;
  final EdgeInsetsGeometry margin;
  final Color color;
  final TextDirection? textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = margin.resolve(textDirection).deflateRect(Offset.zero & size);
    canvas.drawPath(
      focusRingPath(shape, rect, textDirection: textDirection),
      _ringPaint(color),
    );
  }

  @override
  bool shouldRepaint(_FocusRingPainter oldDelegate) =>
      oldDelegate.shape != shape ||
      oldDelegate.margin != margin ||
      oldDelegate.color != color ||
      oldDelegate.textDirection != textDirection;
}
