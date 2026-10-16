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
                  SizedBox(height: 20),
                  _SkeletonPost(lines: 3),
                  SizedBox(height: 20),
                  _SkeletonPost(lines: 2),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A placeholder post of the thread layout: an avatar and a few lines.
class _SkeletonPost extends StatelessWidget {
  const new({required this.lines});

  final int lines;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SkeletonBox(
          height: TranslateLayout.avatarSize,
          width: TranslateLayout.avatarSize,
          radius: TranslateLayout.avatarSize / 2,
        ),
        const SizedBox(width: TranslateLayout.avatarGap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SkeletonBox(height: 14, width: 96),
              for (var line = 0; line < lines; line++) ...[
                const SizedBox(height: 10),
                FractionallySizedBox(
                  widthFactor: line == lines - 1 ? 0.6 : 1,
                  child: const SkeletonBox(height: 18),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
