import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// Where the user can go to fix an error.
enum TranslateErrorFix { none, instances, providers }

/// A readable description of a translation error.
class TranslateErrorInfo {
  const TranslateErrorInfo(this.message, {this.fix = TranslateErrorFix.none});

  final String message;
  final TranslateErrorFix fix;
}

/// Maps `MozhiApiException` / `LlmApiException` / `LlmRefusalException`
/// and other errors to friendly text.
TranslateErrorInfo describeTranslateError(
  AppLocalizations l10n,
  Object? error,
) {
  return switch (error) {
    LlmRefusalException() => TranslateErrorInfo(l10n.translateErrorRefused),
    LlmApiException(isAuthError: true) => TranslateErrorInfo(
      l10n.translateErrorAuth,
      fix: TranslateErrorFix.providers,
    ),
    LlmApiException(isRateLimited: true) => TranslateErrorInfo(
      l10n.translateErrorRateLimited,
    ),
    LlmApiException(isNotFound: true) => TranslateErrorInfo(
      l10n.translateErrorModelNotFound,
      fix: TranslateErrorFix.providers,
    ),
    LlmApiException(statusCode: null) => TranslateErrorInfo(
      l10n.translateErrorUnreachableProvider,
      fix: TranslateErrorFix.providers,
    ),
    LlmApiException(:final int statusCode) => TranslateErrorInfo(
      l10n.translateErrorProvider('$statusCode'),
    ),
    MozhiApiException(statusCode: null) => TranslateErrorInfo(
      l10n.translateErrorUnreachableInstance,
      fix: TranslateErrorFix.instances,
    ),
    MozhiApiException(statusCode: 429) => TranslateErrorInfo(
      l10n.translateErrorRateLimited,
    ),
    MozhiApiException(:final int statusCode) => TranslateErrorInfo(
      l10n.translateErrorInstance('$statusCode'),
      fix: TranslateErrorFix.instances,
    ),
    TimeoutException() => TranslateErrorInfo(l10n.translateErrorTimeout),
    _ => TranslateErrorInfo(l10n.translateErrorGeneric),
  };
}

/// Error message with a retry button and, when useful, a shortcut to the
/// relevant settings page.
class TranslateErrorView extends StatelessWidget {
  const TranslateErrorView({
    required this.error,
    this.onRetry,
    this.dense = false,
    super.key,
  });

  final Object? error;
  final VoidCallback? onRetry;

  /// Compact variant for compare cards (no settings shortcut).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final info = describeTranslateError(l10n, error);
    final (fixLabel, fixRoute) = switch (info.fix) {
      TranslateErrorFix.instances => (
        l10n.translateManageInstances,
        '/settings/instances',
      ),
      TranslateErrorFix.providers => (
        l10n.translateProvidersAction,
        '/settings/providers',
      ),
      TranslateErrorFix.none => (null, null),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                info.message,
                style:
                    (dense
                            ? theme.textTheme.bodyMedium
                            : theme.textTheme.bodyLarge)
                        ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          ],
        ),
        if (onRetry != null || (!dense && fixRoute != null)) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (onRetry != null)
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.commonRetry),
                ),
              if (!dense && fixRoute != null && fixLabel != null)
                TextButton(
                  onPressed: () => context.go(fixRoute),
                  child: Text(fixLabel),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
