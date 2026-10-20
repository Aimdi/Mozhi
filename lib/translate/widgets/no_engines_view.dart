import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:translation_repository/translation_repository.dart';

/// Shown when no Mozhi instance is reachable and no AI provider is set up.
///
/// When the privacy settings kept the engine list from loading
/// (`ConsentRequiredException`: offline only, or offline first before the
/// user let the app contact the servers), that is said instead, with the
/// prompt to allow it.
class NoEnginesView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final error = context.select<TranslateCubit, Object?>(
      (cubit) => cubit.state.error,
    );
    if (error is ConsentRequiredException) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: TranslateErrorView(
              key: const Key('translate_no_engines_consent'),
              error: error,
              onRetry: () => unawaited(
                context.read<TranslateCubit>().loadEngines(refresh: true),
              ),
            ),
          ),
        ),
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Semantics(
                header: true,
                child: Text(
                  l10n.translateNoEnginesTitle,
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.translateNoEnginesBody,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: () =>
                        unawaited(context.push<void>(AppRoutes.providers)),
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(l10n.translateAddAiProvider),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        unawaited(context.push<void>(AppRoutes.instances)),
                    icon: const Icon(Icons.dns_outlined),
                    label: Text(l10n.translateManageInstances),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => unawaited(
                  context.read<TranslateCubit>().loadEngines(refresh: true),
                ),
                icon: const Icon(Icons.refresh),
                label: Text(l10n.commonRetry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
