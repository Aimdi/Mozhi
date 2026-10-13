import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/widgets/step_layout.dart';

/// Step 1: what Mozhi is, plus a privacy note.
class WelcomeStep extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return OnboardingStepLayout(
      icon: Icons.translate,
      title: l10n.onboardingWelcomeTitle,
      subtitle: l10n.onboardingWelcomeSubtitle,
      children: [
        OnboardingInfoRow(
          icon: Icons.hub_outlined,
          title: l10n.onboardingWelcomeEnginesTitle,
          text: l10n.onboardingWelcomeEnginesBody,
        ),
        OnboardingInfoRow(
          icon: Icons.auto_awesome_outlined,
          title: l10n.onboardingWelcomeAiTitle,
          text: l10n.onboardingWelcomeAiBody,
        ),
        OnboardingInfoRow(
          icon: Icons.lock_outline,
          title: l10n.onboardingWelcomePrivacyTitle,
          text: l10n.onboardingWelcomePrivacyBody,
        ),
        const SizedBox(height: 16),
        OnboardingNote(
          icon: Icons.privacy_tip_outlined,
          text: l10n.onboardingWelcomePrivacyNote,
          background: colors.secondaryContainer,
          foreground: colors.onSecondaryContainer,
        ),
      ],
    );
  }
}
