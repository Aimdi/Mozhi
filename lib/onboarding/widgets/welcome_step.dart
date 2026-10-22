import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/widgets/step_layout.dart';

/// Step 1: what Mozhi is, plus a privacy note, and (with [onRestore])
/// a way to bring back a backup instead of setting up again.
class WelcomeStep extends StatelessWidget {
  const new({this.onRestore, super.key});

  /// Restores a backup (`showBackupRestoreDialog`); null hides the
  /// button.
  final VoidCallback? onRestore;

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
        if (onRestore case final restore?) ...[
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('onboarding_restore_backup'),
              onPressed: restore,
              icon: const Icon(Icons.settings_backup_restore),
              label: Text(l10n.onboardingRestoreBackup),
            ),
          ),
        ],
      ],
    );
  }
}
