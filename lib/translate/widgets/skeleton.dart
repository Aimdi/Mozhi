import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';

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
      _controller.stop();
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
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: TranslateLayout.cardBorderRadius,
      ),
      child: const Padding(
        padding: EdgeInsets.all(20),
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

/// Shown while the engine list loads for the first time.
class TranslateSkeleton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.translateLoadingEngines,
      liveRegion: true,
      child: ExcludeSemantics(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TranslateLayout.gutter),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: TranslateLayout.maxColumnWidth,
              ),
              child: const Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: SkeletonBox(height: 40, radius: 20)),
                      SizedBox(width: 56),
                      Expanded(child: SkeletonBox(height: 40, radius: 20)),
                    ],
                  ),
                  SizedBox(height: TranslateLayout.gap),
                  SkeletonBox(height: 160, radius: TranslateLayout.cardRadius),
                  SizedBox(height: TranslateLayout.gap),
                  SkeletonBox(height: 120, radius: TranslateLayout.cardRadius),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
