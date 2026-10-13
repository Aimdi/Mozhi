import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/widgets/step_layout.dart';

/// Step 4: summary of the setup. "Start translating" lives in the
/// navigation bar.
class DoneStep extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final instances = context.select((c) => c.state.instances);
    final providers = context
        .select((c) => c.state.providers)
        .where((provider) => provider.enabled)
        .toList();
    final pings = context.select((c) => c.state.pings);

    final preferred = instances.firstOrNull;
    final latency = preferred == null ? null : pings[preferred.url]?.latency;
    final service = preferred == null
        ? l10n.onboardingDoneNoService
        : [
            if (latency == null)
              preferred.displayName
            else
              l10n.onboardingDoneServiceLatency(
                preferred.displayName,
                latency.inMilliseconds,
              ),
            l10n.onboardingDoneFallbacks(instances.length - 1),
          ].join('\n');
    final ai = providers.isEmpty
        ? l10n.onboardingDoneAiNone
        : [
            for (final provider in providers)
              l10n.onboardingDoneAiValue(provider.name, provider.model),
          ].join('\n');

    return OnboardingStepLayout(
      icon: Icons.celebration_outlined,
      title: l10n.onboardingDoneTitle,
      subtitle: l10n.onboardingDoneBody,
      children: [
        Card.filled(
          margin: EdgeInsets.zero,
          color: colors.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              ListTile(
                key: const Key('onboarding-summary-service'),
                leading: const Icon(Icons.dns_outlined),
                title: Text(l10n.onboardingDoneService),
                subtitle: Text(service),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                key: const Key('onboarding-summary-ai'),
                leading: const Icon(Icons.auto_awesome_outlined),
                title: Text(l10n.onboardingDoneAi),
                subtitle: Text(ai),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        OnboardingInfoRow(
          icon: Icons.lock_outline,
          text: l10n.onboardingDonePrivacy,
        ),
      ],
    );
  }
}
