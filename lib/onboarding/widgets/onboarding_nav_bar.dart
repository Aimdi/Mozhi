import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/cubit/onboarding_state.dart';
import 'package:mozhi/onboarding/widgets/progress_dots.dart';
import 'package:mozhi/onboarding/widgets/step_layout.dart';

/// Bottom bar of the onboarding in the style of X's sign-up: progress
/// dots, a full-width inverse pill for Next (or "Start translating" on the
/// last step) and, after the first step, an outlined pill for Back. The
/// buttons are as wide as the steps' content column
/// ([onboardingContentPadding]).
class OnboardingNavBar extends StatelessWidget {
  const new({
    required this.step,
    required this.onBack,
    required this.onNext,
    required this.onFinish,
    this.steps = OnboardingStep.values,
    super.key,
  });

  final OnboardingStep step;

  /// The steps of the flow (see `OnboardingState.steps`).
  final List<OnboardingStep> steps;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onFinish;

  static const _buttonSize = Size.fromHeight(48);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final index = steps.indexOf(step);
    final isFirst = index <= 0;
    final isLast = index == steps.length - 1;
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = onboardingContentPadding(constraints.maxWidth);
          return Padding(
            padding: EdgeInsets.fromLTRB(side, 8, side, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: OnboardingProgressDots(
                    count: steps.length,
                    current: index < 0 ? 0 : index,
                  ),
                ),
                const SizedBox(height: 12),
                if (isLast)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: _buttonSize),
                    onPressed: onFinish,
                    icon: const Icon(Icons.translate),
                    label: Text(
                      l10n.onboardingStartTranslating,
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                else
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: _buttonSize),
                    onPressed: onNext,
                    icon: const Icon(Icons.arrow_forward),
                    iconAlignment: IconAlignment.end,
                    label: Text(l10n.onboardingNext),
                  ),
                if (!isFirst) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: _buttonSize),
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back),
                    label: Text(l10n.onboardingBack),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
