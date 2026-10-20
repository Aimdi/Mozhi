import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/network/network.dart'
    show describeNetworkPolicyError;
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart'
    show offlineModelDetailsOf;
import 'package:mozhi/translate/widgets/offline_offer.dart';
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
    this.chooseSourceLanguage = false,
    this.consent,
  });

  final String message;
  final TranslateErrorFix fix;

  /// The privacy settings stopped the request before anything was sent:
  /// ask for consent (e.g. with `askConsent`) instead of retrying.
  final ConsentRequiredException? consent;

  /// The technical message with URLs and credentials removed, for an
  /// expandable "Details" section (null when there is nothing to add).
  final String? details;

  /// The on-device models must be downloaded first (Settings → Offline).
  final bool offlineModels;

  /// The engine can't detect the source language ("Detect language" with
  /// the offline engine and text too short to detect): let the user pick it
  /// instead of retrying.
  final bool chooseSourceLanguage;
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
  if (error is ConsentRequiredException) {
    return TranslateErrorInfo(consentMessage(l10n, error), consent: error);
  }
  // Refused by the network policy before anything was sent: say why.
  final policy = describeNetworkPolicyError(l10n, error);
  if (policy != null) return TranslateErrorInfo(policy);
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
    SourceLanguageRequiredException() => TranslateErrorInfo(
      l10n.translateErrorSourceLanguageRequired,
      chooseSourceLanguage: true,
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
    _ when '$error'.contains('SourceLanguageRequiredException') =>
      TranslateErrorInfo(
        l10n.translateErrorSourceLanguageRequired,
        chooseSourceLanguage: true,
      ),
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
    chooseSourceLanguage: info.chooseSourceLanguage,
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
  final raw = error.message;
  // Match against the message without URLs: upstream URLs carry the user's
  // text, which must not be mistaken for a server message.
  final message = raw.replaceAll(_url, ' ');
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
  if (status != null && _upstream.hasMatch(raw)) {
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
/// relevant settings page and an expandable "Details" section. A
/// [ConsentRequiredException] is shown as a [ConsentInlinePrompt] instead
/// (its actions record the consent, then `onRetry` runs).
///
/// Missing offline models are offered as "Download German (25 MB)" (the
/// size when the device's offline engine knows it), which opens the
/// offline languages. A Mozhi instance error offers "Switch instance"
/// instead of "Manage instances" when [onSwitchInstance] is given.
///
/// When the engine cannot detect the source language
/// ([TranslateErrorInfo.chooseSourceLanguage]) and [onChooseSourceLanguage]
/// is given, the main action is "Translate from German"
/// ([suggestedSourceLanguage] with [onUseSourceLanguage]) or else "Choose
/// language"; Retry becomes a secondary action, and is left out when the
/// detection had nothing to go on (it would fail the same way again).
///
/// The message is a live region, so screen readers announce it when it
/// appears.
class TranslateErrorView extends StatelessWidget {
  const new({
    required this.error,
    this.onRetry,
    this.dense = false,
    this.retrySemanticsLabel,
    this.onSwitchInstance,
    this.onChooseSourceLanguage,
    this.suggestedSourceLanguage,
    this.onUseSourceLanguage,
    super.key,
  });

  final Object? error;
  final VoidCallback? onRetry;

  /// Lets the user pick another Mozhi instance (e.g. with
  /// `showInstanceSwitcher`); shown for instance errors only.
  final VoidCallback? onSwitchInstance;

  /// Opens the source language picker (e.g. with `pickTranslateLanguage`);
  /// shown as "Choose language" when the engine needs the source language
  /// ([TranslateErrorInfo.chooseSourceLanguage]) only.
  final VoidCallback? onChooseSourceLanguage;

  /// A likely source language (e.g. `TranslateState.recentSourceSuggestion`)
  /// offered as "Translate from German" next to "Choose language"; needs
  /// [onChooseSourceLanguage] and [onUseSourceLanguage].
  final Language? suggestedSourceLanguage;

  /// Translates from [suggestedSourceLanguage] (e.g.
  /// `TranslateCubit.setSource`).
  final ValueChanged<Language>? onUseSourceLanguage;

  /// What screen readers call the Retry button (it shows "Retry"), e.g.
  /// "Retry German" when several can fail on one screen.
  final String? retrySemanticsLabel;

  /// Compact variant for compare cards (no settings shortcut).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final consent = error;
    if (consent is ConsentRequiredException) {
      // Nothing failed: the user decides (Retry runs once consent is given).
      return ConsentInlinePrompt(
        key: const Key('translate_error_consent'),
        consent: consent,
        onGranted: onRetry ?? () {},
      );
    }
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final info = describeTranslateError(l10n, error);
    final (fixLabel, fixRoute, push) = switch (info.fix) {
      _ when info.offlineModels => (
        _offlineFixLabel(context, l10n) ?? l10n.translateOfflineModelsAction,
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
    final switchInstance = info.fix == TranslateErrorFix.instances && !dense
        ? onSwitchInstance
        : null;
    final showFix =
        fixRoute != null &&
        fixLabel != null &&
        !dense &&
        switchInstance == null;
    final chooseSource = info.chooseSourceLanguage
        ? onChooseSourceLanguage
        : null;
    // "Translate from German": one tap instead of the language picker.
    final useSuggested = switch ((
      suggestedSourceLanguage,
      onUseSourceLanguage,
    )) {
      (final language?, final use?) when chooseSource != null => (
        label: l10n.translateUseSourceLanguage(language.name),
        onPressed: () => use(language),
      ),
      _ => null,
    };
    // Retrying a detection that found nothing to go on (no failed request
    // behind it) fails the same way: choosing the language is the way out.
    final retry = switch (error) {
      SourceLanguageRequiredException(cause: null) when chooseSource != null =>
        null,
      _ => onRetry,
    };
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
        if (retry != null ||
            chooseSource != null ||
            showFix ||
            switchInstance != null ||
            details != null) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (chooseSource != null) ...[
                if (useSuggested != null)
                  FilledButton.tonalIcon(
                    key: const Key('translate_error_use_source'),
                    onPressed: useSuggested.onPressed,
                    icon: const Icon(Icons.translate),
                    label: Text(useSuggested.label),
                  ),
                if (useSuggested == null)
                  FilledButton.tonalIcon(
                    key: const Key('translate_error_choose_source'),
                    onPressed: chooseSource,
                    icon: const Icon(Icons.language),
                    label: Text(l10n.translateChooseSourceLanguage),
                  )
                else
                  TextButton.icon(
                    key: const Key('translate_error_choose_source'),
                    onPressed: chooseSource,
                    icon: const Icon(Icons.language),
                    label: Text(l10n.translateChooseSourceLanguage),
                  ),
                if (retry != null)
                  TextButton.icon(
                    key: const Key('translate_error_retry'),
                    onPressed: retry,
                    icon: const Icon(Icons.refresh),
                    label: Text(
                      l10n.commonRetry,
                      semanticsLabel: retrySemanticsLabel,
                    ),
                  ),
              ] else if (retry != null)
                FilledButton.tonalIcon(
                  key: const Key('translate_error_retry'),
                  onPressed: retry,
                  icon: const Icon(Icons.refresh),
                  label: Text(
                    l10n.commonRetry,
                    semanticsLabel: retrySemanticsLabel,
                  ),
                ),
              if (switchInstance != null)
                TextButton.icon(
                  key: const Key('translate_error_switch_instance'),
                  onPressed: switchInstance,
                  icon: const Icon(Icons.swap_vert),
                  label: Text(l10n.translateSwitchInstance),
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
        if (details != null) TranslateErrorDetails(details: details),
      ],
    );
  }

  /// "Download German (25 MB)" for the languages of an
  /// [OfflineModelMissingException] (English needs no download), or null
  /// when it names none.
  String? _offlineFixLabel(BuildContext context, AppLocalizations l10n) {
    final error = this.error;
    if (error is! OfflineModelMissingException) return null;
    final translator = maybeOfflineTranslator(context);
    final codes = {
      for (final code in error.languages)
        if (offlineLanguageKey(code) != 'en') code,
    };
    if (codes.isEmpty) return null;
    final details = translator == null
        ? null
        : offlineModelDetailsOf(translator);
    return offlineDownloadLabel(l10n, [
      for (final code in codes)
        (
          code: code,
          name: _languageName(code),
          bytes: details?.downloadSize(code),
        ),
    ]);
  }
}

/// "Details" toggle revealing the sanitized technical message.
class TranslateErrorDetails extends StatefulWidget {
  const new({required this.details, super.key});

  final String details;

  @override
  State<TranslateErrorDetails> createState() => _TranslateErrorDetailsState();
}

class _TranslateErrorDetailsState extends State<TranslateErrorDetails> {
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
