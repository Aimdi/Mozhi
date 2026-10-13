import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
import 'package:mozhi/image_translate/widgets/image_translate_links.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';

/// Error message with a retry button and, when useful, a shortcut to the
/// settings page that fixes it.
class ImageTranslateErrorView extends StatelessWidget {
  const new({required this.error, this.onRetry, super.key});

  final Object? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final info = describeImageTranslateError(l10n, error);
    final (fixLabel, fixRoute) = switch (info.fix) {
      TranslateErrorFix.instances => (
        l10n.translateManageInstances,
        ImageTranslateLinks.instances,
      ),
      TranslateErrorFix.providers => (
        l10n.translateProvidersAction,
        ImageTranslateLinks.providers,
      ),
      TranslateErrorFix.none => (null, null),
    };
    return Card(
      key: const Key('image_translate_error'),
      color: theme.colorScheme.errorContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      info.message,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (onRetry != null || fixRoute != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (onRetry != null)
                    FilledButton.tonalIcon(
                      key: const Key('image_translate_retry_button'),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.commonRetry),
                    ),
                  if (fixRoute != null && fixLabel != null)
                    TextButton(
                      onPressed: () => context.go(fixRoute),
                      child: Text(fixLabel),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
