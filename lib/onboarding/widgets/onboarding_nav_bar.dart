import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/cubit/onboarding_state.dart';
import 'package:mozhi/onboarding/widgets/progress_dots.dart';

/// Bottom bar of the onboarding: progress dots, Back and Next (or
/// "Start translating" on the last step).
class OnboardingNavBar extends StatelessWidget {
  const new({
    required this.step,
    required this.onBack,
    required this.onNext,
    required this.onFinish,
    super.key,
  });

  final OnboardingStep step;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onFinish;

  static const _buttonSize = Size(88, 48);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isFirst = step.index == 0;
    final isLast = step.index == OnboardingStep.values.length - 1;
    return SafeArea(
      top: false,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                OnboardingProgressDots(
                  count: OnboardingStep.values.length,
                  current: step.index,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (!isFirst)
                      TextButton.icon(
                        style: TextButton.styleFrom(minimumSize: _buttonSize),
                        onPressed: onBack,
                        icon: const Icon(Icons.arrow_back),
                        label: Text(l10n.onboardingBack),
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: isLast
                            ? FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  minimumSize: _buttonSize,
                                ),
                                onPressed: onFinish,
                                icon: const Icon(Icons.translate),
                                label: Text(
                                  l10n.onboardingStartTranslating,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              )
                            : FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  minimumSize: _buttonSize,
                                ),
                                onPressed: onNext,
                                icon: const Icon(Icons.arrow_forward),
                                iconAlignment: IconAlignment.end,
                                label: Text(l10n.onboardingNext),
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
