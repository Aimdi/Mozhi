import 'package:material_ui/material_ui.dart';

/// Gives [child] an [Overlay] of its own, sized by [child].
///
/// Use it around a Material [Slider] (or another widget that keeps an
/// [OverlayPortal] shown). A [Slider] always keeps its value indicator shown
/// in the nearest overlay, even when no indicator is drawn. That overlay
/// child is laid out at the overlay's full size and gets a semantics node of
/// its own: in a page's overlay it is an empty, screen-sized node above the
/// whole page, which on the web intercepts pointer events meant for the
/// widgets below it (and fails hit-target checks in browser tests).
///
/// In a local overlay that node stays within [child]'s bounds; wrap the
/// [LocalOverlay] in a [MergeSemantics] to fold it into [child]'s node.
/// The overlay does not clip, so a value indicator drawn above the slider
/// stays visible.
class LocalOverlay extends StatefulWidget {
  /// Creates a local overlay around [child].
  const new({required this.child, super.key});

  /// The widget shown in the overlay; it determines the overlay's size.
  final Widget child;

  @override
  State<LocalOverlay> createState() => _LocalOverlayState();
}

class _LocalOverlayState extends State<LocalOverlay> {
  late final OverlayEntry _entry = OverlayEntry(
    canSizeOverlay: true,
    builder: (context) => widget.child,
  );

  @override
  void didUpdateWidget(LocalOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) _entry.markNeedsBuild();
  }

  @override
  void dispose() {
    _entry
      ..remove()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Overlay(clipBehavior: Clip.none, initialEntries: [_entry]);
}
