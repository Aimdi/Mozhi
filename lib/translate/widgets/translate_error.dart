import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// Where the user can go to fix an error.
enum TranslateErrorFix { none, instances, providers }

/// A readable description of a translation error.
class TranslateErrorInfo {
  const new(
    this.message, {
    this.fix = TranslateErrorFix.none,
    this.details,
    this.offlineModels = false,
  });

  final String message;
  final TranslateErrorFix fix;

  /// The technical message with URLs and credentials removed, for an
  /// expandable "Details" section (null when there is nothing to add).
  final String? details;

  /// The on-device models must be downloaded first (Settings → Offline).
  final bool offlineModels;
}

/// Route of the offline language models page.
const offlineModelsRoute = '/settings/offline';

/// Maps `MozhiApiException` / `LlmApiException` / `LlmRefusalException`,
/// offline engine failures and other errors to friendly text.
///
/// Raw Mozhi messages are Go errors that may embed the upstream request URL
/// (which can contain the user's text), so they are never shown as the
/// message; [TranslateErrorInfo.details] carries a sanitized copy.
TranslateErrorInfo describeTranslateError(
  AppLocalizations l10n,
  Object? error,
) {
  final info = switch (error) {
    OfflineModelMissingException(:final languages) => TranslateErrorInfo(
      languages.isEmpty
          ? l10n.translateErrorOfflineModelMissing
          : l10n.translateErrorOfflineModelMissingFor(
              languages.map(_languageName).join(', '),
            ),
      offlineModels: true,
    ),
    OfflineLanguageUnsupportedException() => TranslateErrorInfo(
      l10n.translateErrorOfflineUnsupported,
    ),
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
    final MozhiApiException mozhi => _describeMozhi(l10n, mozhi),
    TimeoutException() => TranslateErrorInfo(l10n.translateErrorTimeout),
    // The offline engine may wrap the exception (e.g. in a platform error).
    _ when '$error'.contains('OfflineModelMissingException') =>
      TranslateErrorInfo(
        l10n.translateErrorOfflineModelMissing,
        offlineModels: true,
      ),
    _ => TranslateErrorInfo(l10n.translateErrorGeneric),
  };
  final details = sanitizeErrorDetails(error);
  return TranslateErrorInfo(
    info.message,
    fix: info.fix,
    offlineModels: info.offlineModels,
    details: details == null || details == info.message ? null : details,
  );
}

String _languageName(String code) => LanguageCatalog.byCode(code)?.name ?? code;

final _rateLimited = RegExp('rate.?limit', caseSensitive: false);
final _engineUnavailable = RegExp(
  'engine does not exist|not supported or implemented|engine .* disabled',
  caseSensitive: false,
);
final _targetInvalid = RegExp(
  'target language( code)? (is )?invalid',
  caseSensitive: false,
);
final _sourceInvalid = RegExp(
  'source language( code)? (is )?invalid',
  caseSensitive: false,
);
final _crashed = RegExp(
  r'runtime error|\bpanic\b|nil pointer|invalid memory address',
  caseSensitive: false,
);
final _upstream = RegExp(
  r'^\s*(post|get|put)\s+"|errtransport|https?://',
  caseSensitive: false,
);
final _tooLarge = RegExp(
  'too large|entity too large|header fields too large',
  caseSensitive: false,
);
final _emptyResult = RegExp(
  'returned no result|empty (translation|result)',
  caseSensitive: false,
);

TranslateErrorInfo _describeMozhi(
  AppLocalizations l10n,
  MozhiApiException error,
) {
  final message = error.message;
  final status = error.statusCode;
  final host = error.uri?.host ?? '';
  if (status == 429 || _rateLimited.hasMatch(message)) {
    return TranslateErrorInfo(l10n.translateErrorRateLimited);
  }
  if (_engineUnavailable.hasMatch(message)) {
    return TranslateErrorInfo(l10n.translateErrorEngineUnavailable);
  }
  if (_targetInvalid.hasMatch(message)) {
    return TranslateErrorInfo(l10n.translateErrorTargetUnsupported);
  }
  if (_sourceInvalid.hasMatch(message)) {
    return TranslateErrorInfo(l10n.translateErrorSourceUnsupported);
  }
  if (_crashed.hasMatch(message)) {
    return TranslateErrorInfo(l10n.translateErrorEngineCrashed);
  }
  if (status != null && _upstream.hasMatch(message)) {
    return TranslateErrorInfo(
      host.isEmpty
          ? l10n.translateErrorUpstream
          : l10n.translateErrorUpstreamHost(host),
    );
  }
  if (status == 413 ||
      status == 414 ||
      status == 431 ||
      _tooLarge.hasMatch(message)) {
    return TranslateErrorInfo(l10n.translateErrorTooLong);
  }
  if (_emptyResult.hasMatch(message)) {
    return TranslateErrorInfo(l10n.translateErrorEmptyResult);
  }
  if (status == null) {
    return TranslateErrorInfo(
      l10n.translateErrorUnreachableInstance,
      fix: TranslateErrorFix.instances,
    );
  }
  return TranslateErrorInfo(
    l10n.translateErrorInstance('$status'),
    fix: TranslateErrorFix.instances,
  );
}

final _url = RegExp(
  r'''[a-z][a-z0-9+.-]*://[^\s"'<>\[\]]+''',
  caseSensitive: false,
);

/// Longest details text shown.
const maxErrorDetailsLength = 300;

/// The technical message of [error] for a "Details" section, with every URL
/// reduced to its scheme and host (upstream URLs carry the user's text in
/// their path or query, and instance URLs may carry credentials), whitespace
/// collapsed and the length capped. Null when there is nothing to show.
String? sanitizeErrorDetails(Object? error) {
  if (error == null) return null;
  final raw = switch (error) {
    MozhiApiException(:final message, statusCode: final int status) =>
      'HTTP $status: $message',
    MozhiApiException(:final message) => message,
    LlmApiException(:final message, statusCode: final int status) =>
      'HTTP $status: $message',
    LlmApiException(:final message) => message,
    _ => error.toString(),
  };
  final redacted = raw
      .replaceAllMapped(_url, (match) => _redactUrl(match[0]!))
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (redacted.isEmpty) return null;
  if (redacted.length <= maxErrorDetailsLength) return redacted;
  return '${redacted.substring(0, maxErrorDetailsLength).trimRight()}…';
}

String _redactUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return '…';
  final rest = url.length > '${uri.scheme}://'.length + uri.authority.length;
  return '${uri.scheme}://${uri.host}${rest ? '/…' : ''}';
}

/// Error message with a retry button and, when useful, a shortcut to the
/// relevant settings page and an expandable "Details" section.
///
/// The message is a live region, so screen readers announce it when it
/// appears.
class TranslateErrorView extends StatelessWidget {
  const new({required this.error, this.onRetry, this.dense = false, super.key});

  final Object? error;
  final VoidCallback? onRetry;

  /// Compact variant for compare cards (no settings shortcut).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final info = describeTranslateError(l10n, error);
    final (fixLabel, fixRoute, push) = switch (info.fix) {
      _ when info.offlineModels => (
        l10n.translateOfflineModelsAction,
        offlineModelsRoute,
        true,
      ),
      TranslateErrorFix.instances => (
        l10n.translateManageInstances,
        '/settings/instances',
        false,
      ),
      TranslateErrorFix.providers => (
        l10n.translateProvidersAction,
        '/settings/providers',
        false,
      ),
      TranslateErrorFix.none => (null, null, false),
    };
    final showFix = fixRoute != null && fixLabel != null && !dense;
    final details = info.details;
    return Column(
      key: const Key('translate_error_view'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  info.message,
                  key: const Key('translate_error_message'),
                  style:
                      (dense
                              ? theme.textTheme.bodyMedium
                              : theme.textTheme.bodyLarge)
                          ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ),
          ],
        ),
        if (onRetry != null || showFix || details != null) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (onRetry != null)
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.commonRetry),
                ),
              if (showFix)
                TextButton(
                  key: const Key('translate_error_fix'),
                  onPressed: () => push
                      ? unawaited(context.push<void>(fixRoute))
                      : context.go(fixRoute),
                  child: Text(fixLabel),
                ),
            ],
          ),
        ],
        if (details != null) ErrorDetails(details: details),
      ],
    );
  }
}

/// "Details" toggle revealing the sanitized technical message.
class ErrorDetails extends StatefulWidget {
  const new({required this.details, super.key});

  final String details;

  @override
  State<ErrorDetails> createState() => _ErrorDetailsState();
}

class _ErrorDetailsState extends State<ErrorDetails> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          expanded: _open,
          child: TextButton.icon(
            key: const Key('translate_error_details'),
            onPressed: () => setState(() => _open = !_open),
            icon: Icon(_open ? Icons.expand_less : Icons.expand_more),
            label: Text(
              _open
                  ? l10n.translateErrorHideDetails
                  : l10n.translateErrorDetails,
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, end: 12),
            child: SelectableText(
              widget.details,
              key: const Key('translate_error_details_text'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
            ),
          ),
      ],
    );
  }
}
