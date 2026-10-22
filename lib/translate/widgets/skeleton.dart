import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';

/// How long work may take before its progress is shown ([DelayedReveal]):
/// quick (cached, local) translations never flash a progress bar.
const loadingRevealDelay = Duration(milliseconds: 300);

/// Shows [child] once it has been in the tree for [delay], nothing (an
/// empty box) before. Put it where progress is shown only while work is
/// running: removing it cancels the wait.
class DelayedReveal extends StatefulWidget {
  const new({required this.child, this.delay = loadingRevealDelay, super.key});

  final Widget child;
  final Duration delay;

  @override
  State<DelayedReveal> createState() => _DelayedRevealState();
}

class _DelayedRevealState extends State<DelayedReveal> {
  Timer? _timer;
  late bool _shown = widget.delay <= Duration.zero;

  @override
  void initState() {
    super.initState();
    if (!_shown) {
      _timer = Timer(widget.delay, () {
        if (mounted) setState(() => _shown = true);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _shown ? widget.child : const SizedBox.shrink();
}

/// Placeholder lines for a translation that has not produced text yet: two
/// full lines and a shorter third one, shown as soon as a translation is
/// queued or running (no reveal delay on top of the typing pause).
///
/// Decorative unless [label] is given: then screen readers hear it
/// ("Translating…") instead of the lines.
class TranslateOutputSkeleton extends StatelessWidget {
  const new({this.label, super.key});

  /// What screen readers hear for the placeholder, or null (decorative).
  final String? label;

  @override
  Widget build(BuildContext context) {
    const lines = Column(
      key: Key('translate_output_skeleton'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkeletonBox(height: 18),
        SizedBox(height: 10),
        SkeletonBox(height: 18),
        SizedBox(height: 10),
        FractionallySizedBox(
          widthFactor: 0.6,
          child: SkeletonBox(height: 18),
        ),
      ],
    );
    final label = this.label;
    if (label == null) return const ExcludeSemantics(child: lines);
    return Semantics(
      container: true,
      label: label,
      child: const ExcludeSemantics(child: lines),
    );
  }
}

/// Gently pulsing placeholder box. Static when animations are disabled.
class SkeletonBox extends StatefulWidget {
  const new({this.height = 16, this.width, this.radius = 8, super.key});

  final double height;
  final double? width;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      // Reduced motion: a static, fully visible placeholder.
      _controller
        ..stop()
        ..value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1).animate(_controller),
      child: Container(
        height: widget.height,
        width: widget.width,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

/// Placeholder for one compare result while it is still running.
class SkeletonCard extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return const TranslateFlatCard(
      look: TranslateCardLook.quote,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonBox(height: 14, width: 96),
            SizedBox(height: 16),
            SkeletonBox(),
            SizedBox(height: 8),
            FractionallySizedBox(widthFactor: 0.6, child: SkeletonBox()),
          ],
        ),
      ),
    );
  }
}

/// Shown while the engine list loads for the first time: the empty
/// screen's outline, a greeting in the middle and the composer card at
/// the bottom (with the language bar).
class TranslateSkeleton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.translateLoadingEngines,
      liveRegion: true,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              const Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SkeletonBox(height: 52, width: 52, radius: 26),
                        SizedBox(height: 16),
                        SkeletonBox(height: 30, width: 220, radius: 15),
                        SizedBox(height: 20),
                        SkeletonBox(height: 40, width: 240, radius: 20),
                      ],
                    ),
                  ),
                ),
              ),
              // The composer card.
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: TranslateLayout.maxColumnWidth,
                ),
                child: const SkeletonBox(height: 150, radius: 28),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
