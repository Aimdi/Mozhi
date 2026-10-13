import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/cubit/onboarding_cubit.dart';
import 'package:mozhi/onboarding/widgets/onboarding_badge.dart';
import 'package:mozhi/onboarding/widgets/provider_form.dart';
import 'package:mozhi/onboarding/widgets/provider_grid.dart';
import 'package:mozhi/onboarding/widgets/step_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Step 3 (optional): why AI helps, preset grid and the provider form.
class AiStep extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final presetId = context.select((OnboardingCubit c) => c.state.presetId);
    return OnboardingStepLayout(
      icon: Icons.auto_awesome_outlined,
      title: l10n.onboardingAiTitle,
      titleTrailing: OnboardingBadge(
        label: l10n.onboardingAiOptional,
        color: colors.secondary,
      ),
      subtitle: l10n.onboardingAiBody,
      children: [
        OnboardingInfoRow(
          icon: Icons.alt_route,
          text: l10n.onboardingAiBenefitAlternatives,
        ),
        OnboardingInfoRow(
          icon: Icons.lightbulb_outline,
          text: l10n.onboardingAiBenefitInsights,
        ),
        OnboardingInfoRow(
          icon: Icons.school_outlined,
          text: l10n.onboardingAiBenefitExplain,
        ),
        OnboardingInfoRow(
          icon: Icons.spellcheck,
          text: l10n.onboardingAiBenefitProofread,
        ),
        OnboardingInfoRow(
          icon: Icons.tune,
          text: l10n.onboardingAiBenefitStyles,
        ),
        const SizedBox(height: 12),
        OnboardingNote(
          icon: Icons.shield_outlined,
          text: l10n.onboardingAiPrivacy,
        ),
        const SizedBox(height: 24),
        OnboardingSection(
          title: l10n.onboardingAiChooseProvider,
          child: ProviderGrid(
            presets: AiProviderPreset.all,
            selectedId: presetId,
            onSelected: context.read<OnboardingCubit>().selectPreset,
          ),
        ),
        if (presetId != null) ...[
          ProviderForm(key: ValueKey('provider-form-$presetId')),
          const SizedBox(height: 16),
        ],
        Text(
          l10n.onboardingAiLater,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
