import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';

/// Shown when no AI provider is configured: proofreading needs an LLM.
class ProofreadEmptyState extends StatelessWidget {
  const new({super.key});

  /// Route of the AI provider settings.
  static const providersRoute = '/settings/providers';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: SingleChildScrollView(
        child: EmptyStateView(
          icon: Icons.spellcheck,
          title: l10n.proofreadEmptyTitle,
          body: l10n.proofreadEmptyBody,
          action: FilledButton.icon(
            onPressed: () => context.go(providersRoute),
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
