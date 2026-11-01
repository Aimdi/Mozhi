import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/on_device_ai_setup_button.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';

/// Shown when no AI engine that can proofread is configured: proofreading
/// needs an LLM with the general prompt profile (dedicated translation
/// models can't do it). Offers "Add AI provider" and, where on-device AI
/// runs and a model fits the phone ([offersOnDeviceAiSetup]), "Set up
/// on-device AI" first.
class ProofreadEmptyState extends StatelessWidget {
  const new({super.key});

  /// Route of the AI provider settings.
  static const providersRoute = '/settings/providers';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final onDevice = offersOnDeviceAiSetup(context);
    void addProvider() => unawaited(context.push<void>(providersRoute));
    return Center(
      child: SingleChildScrollView(
        child: EmptyStateView(
          icon: Icons.spellcheck,
          title: l10n.proofreadEmptyTitle,
          body: onDevice
              ? l10n.proofreadEmptyBodyOnDevice
              : l10n.proofreadEmptyBody,
          // Above the tabs: back returns to proofreading.
          action: onDevice
              ? Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    const OnDeviceAiSetupButton(
                      key: Key('proofread_set_up_on_device_ai'),
                      filled: true,
                    ),
                    OutlinedButton.icon(
                      key: const Key('proofread_add_provider'),
                      onPressed: addProvider,
                      icon: const Icon(Icons.add),
                      label: Text(l10n.proofreadEmptyAction),
                    ),
                  ],
                )
              : FilledButton.icon(
                  key: const Key('proofread_add_provider'),
                  onPressed: addProvider,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.proofreadEmptyAction),
                ),
        ),
      ),
    );
  }
}

/// Shown when the engines could not be loaded, e.g. because the Mozhi
/// instance is unreachable: AI providers may well be configured.
class ProofreadEnginesError extends StatelessWidget {
  const new({required this.onRetry, super.key});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: SingleChildScrollView(
        child: EmptyStateView(
          icon: Icons.cloud_off_outlined,
          tone: EmptyStateTone.error,
          announce: true,
          title: l10n.proofreadEnginesErrorTitle,
          body: l10n.proofreadEnginesErrorBody,
          action: FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.commonRetry),
          ),
        ),
      ),
    );
  }
}
