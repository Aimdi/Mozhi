import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Page indicator: one dot per step, the current one elongated. Read by
/// screen readers as "Step x of y".
class OnboardingProgressDots extends StatelessWidget {
  const new({required this.count, required this.current, super.key});

  final int count;

  /// Zero-based index of the current step.
  final int current;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 250);
    return Semantics(
      label: context.l10n.onboardingStepProgress(current + 1, count),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              key: ValueKey('onboarding-dot-$i'),
              duration: duration,
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: i == current ? 24 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i <= current ? colors.primary : colors.outline,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ],
      ),
    );
  }
}
