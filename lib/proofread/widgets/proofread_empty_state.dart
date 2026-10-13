import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Shown when no AI provider is configured: proofreading needs an LLM.
class ProofreadEmptyState extends StatelessWidget {
  const ProofreadEmptyState({super.key});

  /// Route of the AI provider settings.
  static const providersRoute = '/settings/providers';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 16,
            children: [
              Icon(
                Icons.spellcheck,
                size: 64,
                color: theme.colorScheme.primary,
              ),
              Text(
                l10n.proofreadEmptyTitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              Text(
                l10n.proofreadEmptyBody,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              FilledButton.icon(
                onPressed: () => context.go(providersRoute),
                icon: const Icon(Icons.add),
                label: Text(l10n.proofreadEmptyAction),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
