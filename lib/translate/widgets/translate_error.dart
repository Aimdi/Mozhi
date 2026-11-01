import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/network/network.dart'
    show describeNetworkPolicyError;
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart'
    show offlineModelDetailsOf;
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/engine_selector.dart'
    show showEngineSheet;
import 'package:mozhi/translate/widgets/instance_switcher.dart'
    show currentInstanceUrl;
import 'package:mozhi/translate/widgets/offline_download_action.dart'
    show OfflineDownloadAction;
import 'package:mozhi/translate/widgets/offline_offer.dart';
import 'package:mozhi/translate/widgets/offline_only_notice.dart';
import 'package:mozhi/translate/widgets/translate_error_offline_io.dart'
    if (dart.library.js_interop) 'package:mozhi/translate/widgets/translate_error_offline_web.dart'
    as platform;
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
    this.title,
    this.anotherInstanceMayHelp = false,
  });

  final String message;
  final TranslateErrorFix fix;

  /// A short title above [message] (e.g. "Couldn't connect"); null when
  /// the message says it all.
  final String? title;

  /// A Mozhi instance failed in a way another instance of the user's list
  /// may not (it is down, overloaded, its engine broke).
  final bool anotherInstanceMayHelp;

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
const String offlineModelsRoute = AppRoutes.offline;

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
              languages.map((code) => _languageName(l10n, code)).join(', '),
            ),
      offlineModels: true,
    ),
    OfflineLanguageUnsupportedException() => TranslateErrorInfo(
      l10n.translateErrorOfflineUnsupported,
    ),
    // The detection needed the servers, and none of them answered.
    SourceLanguageRequiredException(cause: AllInstancesFailedException()) =>
      TranslateErrorInfo(
        l10n.translateErrorDetectionServersFailed,
        chooseSourceLanguage: true,
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
    // The engine is limiting the servers' requests (Google answering them
    // with 429): say that, in plain words, never the server's own text.
    AllInstancesFailedException(rateLimited: true, :final engine) =>
      TranslateErrorInfo(
        l10n.translateErrorAllServersRateLimited(engine.name),
        fix: TranslateErrorFix.instances,
      ),
    // Every server failed: say so in plain words (never "HTTP 500").
    AllInstancesFailedException(:final instances, :final engine) =>
      TranslateErrorInfo(
        l10n.translateErrorAllServersFailed(instances.length, engine.name),
        fix: TranslateErrorFix.instances,
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
  final details = _detailsOf(l10n, error);
  return TranslateErrorInfo(
    info.message,
    fix: info.fix,
    offlineModels: info.offlineModels,
    chooseSourceLanguage: info.chooseSourceLanguage,
    details: details == null || details == info.message ? null : details,
    title: _titleOf(l10n, error, info),
    anotherInstanceMayHelp: info.anotherInstanceMayHelp,
  );
}

/// [sanitizeErrorDetails] of [error], after the servers tried (their host
/// names only) for an [AllInstancesFailedException] (also one that kept the
/// source language from being detected).
String? _detailsOf(AppLocalizations l10n, Object? error) {
  if (error case SourceLanguageRequiredException(
    :final AllInstancesFailedException cause,
  )) {
    return _detailsOf(l10n, cause);
  }
  final details = sanitizeErrorDetails(error);
  if (error is! AllInstancesFailedException) return details;
  final hosts = {
    for (final instance in error.instances)
      if (Uri.tryParse(instance.url)?.host case final host?
          when host.isNotEmpty)
        host,
  };
  if (hosts.isEmpty) return details;
  final tried = l10n.translateErrorServersTried(hosts.join(', '));
  return details == null ? tried : '$tried $details';
}

/// The short title of [error] described by [info]: what kind of problem
/// it is, so the message can say what to do.
String? _titleOf(
  AppLocalizations l10n,
  Object? error,
  TranslateErrorInfo info,
) {
  if (error
      case AllInstancesFailedException() ||
          SourceLanguageRequiredException(
            cause: AllInstancesFailedException(),
          )) {
    return l10n.translateErrorTitleAllServers;
  }
  if (info.chooseSourceLanguage) return l10n.translateErrorTitleLanguage;
  if (info.offlineModels) return l10n.translateErrorTitleDownload;
  if (isNetworkFailure(error)) return l10n.translateErrorTitleConnection;
  return switch (error) {
    LlmApiException() ||
    LlmRefusalException() ||
    MtApiException() => l10n.translateErrorTitleProvider,
    MozhiApiException() => l10n.translateErrorTitleInstance,
    _ => null,
  };
}

/// The name of the language [code] in the UI language.
String _languageName(AppLocalizations l10n, String code) =>
    languageDisplayNameOf(code, l10n.localeName);

/// Whether [error] says the server could not be reached or failed: no
/// answer (DNS, TLS, connection), a timeout or a 5xx status, from a Mozhi
/// instance, an AI provider or a machine translation service. The
/// on-device engine may still translate then. A cancelled request, a
/// refusal or a truncated answer is not one.
bool isNetworkFailure(Object? error) => switch (error) {
  // Every server failed (down, overloaded, blocked upstream).
  AllInstancesFailedException() => true,
  // isRetryable is false for a request the user cancelled.
  MozhiApiException(statusCode: null, isRetryable: true) => true,
  MozhiApiException(:final int statusCode) => statusCode >= 500,
  LlmRefusalException() || LlmApiException(isTruncated: true) => false,
  LlmApiException(statusCode: null) => true,
  LlmApiException(:final int statusCode) => statusCode >= 500,
  MtApiException(
    kind: MtErrorKind.network || MtErrorKind.timeout || MtErrorKind.server,
  ) =>
    true,
  TimeoutException() => true,
  _ => false,
};

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
    return TranslateErrorInfo(
      l10n.translateErrorRateLimited,
      anotherInstanceMayHelp: true,
    );
  }
  if (_engineUnavailable.hasMatch(message)) {
    return TranslateErrorInfo(
      l10n.translateErrorEngineUnavailable,
      anotherInstanceMayHelp: true,
    );
  }
  if (_targetInvalid.hasMatch(message)) {
    return TranslateErrorInfo(l10n.translateErrorTargetUnsupported);
  }
  if (_sourceInvalid.hasMatch(message)) {
    return TranslateErrorInfo(l10n.translateErrorSourceUnsupported);
  }
  if (_crashed.hasMatch(message)) {
    return TranslateErrorInfo(
      l10n.translateErrorEngineCrashed,
      anotherInstanceMayHelp: true,
    );
  }
  if (status != null && _upstream.hasMatch(raw)) {
    return TranslateErrorInfo(
      host.isEmpty
          ? l10n.translateErrorUpstream
          : l10n.translateErrorUpstreamHost(host),
      anotherInstanceMayHelp: true,
    );
  }
  if (status == 413 ||
      status == 414 ||
      status == 431 ||
      _tooLarge.hasMatch(message)) {
    return TranslateErrorInfo(l10n.translateErrorTooLong);
  }
  if (_emptyResult.hasMatch(message)) {
    return TranslateErrorInfo(
      l10n.translateErrorEmptyResult,
      anotherInstanceMayHelp: true,
    );
  }
  if (status == null) {
    return TranslateErrorInfo(
      l10n.translateErrorUnreachableInstance,
      fix: TranslateErrorFix.instances,
      anotherInstanceMayHelp: true,
    );
  }
  return TranslateErrorInfo(
    l10n.translateErrorInstance('$status'),
    fix: TranslateErrorFix.instances,
    anotherInstanceMayHelp: true,
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

/// Whether the device has no network connection right now: the browser's
/// `navigator.onLine`, else none of the device's network interfaces has
/// an address. Asks the platform only (nothing is sent); tests replace it.
@visibleForTesting
Future<bool> Function() deviceOfflineCheck = platform.deviceSeemsOffline;

/// The engine to offer after the Translate screen's translation with
/// `state.engine` failed: the first other engine of [state] that the
/// automatic fallback of `TranslateCubit` could use too, so text never
/// goes anywhere the user has not already allowed for this language
/// pair. That is an engine that is not the on-device one (it has its own
/// offer, [OfflinePairOffer]), not a cloud provider, and that the privacy
/// settings allow for the pair without a new consent
/// ([TranslationRepository.needsConsent]). Null when there is none, or
/// without a [repository] to ask.
TranslationEngine? translateAlternativeEngine(
  TranslateState state,
  TranslationRepository? repository,
) {
  final failed = state.engine;
  if (failed == null || repository == null) return null;
  bool cloud(TranslationEngine engine) {
    try {
      return repository.destinationOf(engine.id) is CloudProviderDestination;
    } on Object {
      return (engine.isAi || engine.isMt) && !engine.isLocal;
    }
  }

  bool allowed(TranslationEngine engine) {
    try {
      return !repository.needsConsent(
        engine,
        source: state.source,
        target: state.target,
      );
    } on Object {
      return false;
    }
  }

  for (final engine in state.engines) {
    if (engine.id == failed.id || engine.isOffline) continue;
    if (!cloud(engine) && allowed(engine)) return engine;
  }
  return null;
}

/// The instance after the one in use ([current]) in [instances], wrapping
/// around; null with fewer than two.
String? nextInstanceUrl(String? current, List<MozhiInstance> instances) {
  if (instances.length < 2) return null;
  final index = instances.indexWhere((i) => i.url == current);
  return instances[(index + 1) % instances.length].url;
}

/// An error with a way forward: a short error-coloured title ("Couldn't
/// connect", "AI provider problem", [TranslateErrorInfo.title]) above the
/// message in normal text, then the actions. When the device has no
/// network ([deviceOfflineCheck], checked for network failures) it says
/// "You're offline" instead.
///
/// A [ConsentRequiredException] is shown as a [ConsentInlinePrompt]
/// instead (its actions record the consent, then `onRetry` runs); one of
/// [ConsentKind.offlineOnly] as an [OfflineOnlyNotice] when the device has
/// nothing to translate with either (no on-device engine, no language
/// pack).
///
/// For the Translate screen's own translation (the [TranslateCubit]
/// above has [error]; not [dense]) the main action is a one-tap
/// alternative when there is one, with Retry next to it:
///
/// * an AI provider or translation service failed: "Translate with
///   Google", an engine the user already allowed for the language pair
///   ([translateAlternativeEngine], chosen with
///   `TranslateCubit.selectEngine`);
/// * a Mozhi instance failed in a way another may not
///   ([TranslateErrorInfo.anotherInstanceMayHelp]) and the user has more
///   than one: "Try next instance", which makes the next instance of
///   their list the preferred one (`SettingsCubit.preferInstance`) and
///   translates again. Their consent covers every instance of the list.
///
/// When every Mozhi server failed for the chosen engine
/// ([AllInstancesFailedException]; [describeTranslateError] is shared with
/// the other features that ask the servers, such as image translation),
/// the message says the volunteer servers failed (also when they failed to
/// detect the source language: then it asks for the language), or, when
/// the engine is limiting their requests
/// ([AllInstancesFailedException.rateLimited]), that it is ("Google is
/// limiting requests from the volunteer servers right now."), and the
/// Translate screen's own error offers, in this order:
/// "Translate on this device" (or the download of the pair, see
/// [OfflinePairOffer]), "Use DuckDuckGo when Google fails" (for Google
/// while that fallback is off and could take over,
/// `TranslateCubit.duckDuckGoFallbackApplies`: it turns the fallback on
/// and translates with DuckDuckGo, `TranslateCubit
/// .useDuckDuckGoWhenGoogleFails`), "Try another engine" (the engine
/// picker, [showEngineSheet]: the engine is never switched on its own,
/// another engine sends the text somewhere else) and "Choose another
/// server" (the instance settings), then Retry.
///
/// Missing offline models are offered as "Download German (25 MB)" (the
/// size when the device's offline engine knows it): for the Translate
/// screen's own translation it downloads them right there and then
/// translates on the device ([OfflineDownloadAction], with "Manage
/// languages"); elsewhere it opens the offline languages. A Mozhi instance
/// error offers "Switch instance"
/// instead of "Manage instances" when [onSwitchInstance] is given.
///
/// When the Translate screen's translation failed on the network
/// ([isNetworkFailure]: no answer, a timeout, a 5xx) with an engine that
/// is not the on-device one, an [OfflinePairOffer] for its language pair
/// follows: "Translate on this device" when the models are installed,
/// "Download German (25 MB)" when they can be downloaded (not [dense]).
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
      final prompt = ConsentInlinePrompt(
        key: const Key('translate_error_consent'),
        consent: consent,
        onGranted: onRetry ?? () {},
      );
      // "Offline only" with nothing on the device to translate with: say
      // that instead of "this engine needs the network".
      return consent.kind == ConsentKind.offlineOnly
          ? OfflineOnlyNotice(consent: consent, fallback: prompt)
          : prompt;
    }
    if (!isNetworkFailure(error)) return _build(context, offline: false);
    return _DeviceOffline(key: ObjectKey(error), builder: _build);
  }

  Widget _build(BuildContext context, {required bool offline}) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final info = describeTranslateError(l10n, error);
    // Every server failed: the ways on that need no Mozhi server.
    final allFailed =
        error is AllInstancesFailedException &&
        !dense &&
        _translateOf(context) != null;
    final anotherEngine = allFailed && !offline
        ? _anotherEngine(context)
        : null;
    final anotherServer = allFailed && !offline;
    final useDuckDuckGo = allFailed && !offline
        ? _useDuckDuckGo(context)
        : null;
    // Every fix is pushed above the tabs, so back returns here.
    final (fixLabel, fixRoute) = switch (info.fix) {
      _ when info.offlineModels => (
        _offlineFixLabel(context, l10n) ?? l10n.translateOfflineModelsAction,
        offlineModelsRoute,
      ),
      TranslateErrorFix.instances => (
        l10n.translateManageInstances,
        AppRoutes.instances,
      ),
      TranslateErrorFix.providers => (
        l10n.translateProvidersAction,
        AppRoutes.providers,
      ),
      TranslateErrorFix.none => (null, null),
    };
    final switchInstance =
        info.fix == TranslateErrorFix.instances && !dense && !allFailed
        ? onSwitchInstance
        : null;
    // Missing offline models of the Translate screen's translation: the
    // download right here (W8-B), then the text is translated on the
    // device.
    final downloadHere = info.offlineModels && !dense && !offline
        ? _offlineDownload(context)
        : null;
    final showFix =
        fixRoute != null &&
        fixLabel != null &&
        !dense &&
        !allFailed &&
        switchInstance == null &&
        !offline &&
        downloadHere == null;
    final chooseSource = info.chooseSourceLanguage
        ? onChooseSourceLanguage
        : null;
    // "Translate from German": one tap instead of the language picker.
    final useSuggested = switch ((
      suggestedSourceLanguage,
      onUseSourceLanguage,
    )) {
      (final language?, final use?) when chooseSource != null => (
        label: l10n.translateUseSourceLanguage(context.languageName(language)),
        onPressed: () => use(language),
      ),
      _ => null,
    };
    // Another engine or instance (none while the device is offline: they
    // need the network too; the on-device engine has its own offer).
    final alternative = chooseSource != null || offline || dense || allFailed
        ? null
        : _alternative(context, info);
    // Retrying a detection that found nothing to go on (no failed request
    // behind it) fails the same way: choosing the language is the way out.
    final retry = switch (error) {
      SourceLanguageRequiredException(cause: null) when chooseSource != null =>
        null,
      _ => onRetry,
    };
    final title = offline ? l10n.translateErrorTitleOffline : info.title;
    final message = offline ? l10n.translateErrorOfflineBody : info.message;
    final details = info.details;
    final offlineOffer = _offlineOffer(context);
    final retryButton = retry == null
        ? null
        : chooseSource != null || alternative != null || allFailed
        ? TextButton.icon(
            key: const Key('translate_error_retry'),
            onPressed: retry,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.commonRetry, semanticsLabel: retrySemanticsLabel),
          )
        : FilledButton.tonalIcon(
            key: const Key('translate_error_retry'),
            onPressed: retry,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.commonRetry, semanticsLabel: retrySemanticsLabel),
          );
    return Column(
      key: const Key('translate_error_view'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              offline ? Icons.wifi_off_rounded : Icons.error_outline,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    if (title != null && !dense)
                      Text(
                        title,
                        key: const Key('translate_error_title'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    Text(
                      message,
                      key: const Key('translate_error_message'),
                      style:
                          (dense
                                  ? theme.textTheme.bodyMedium
                                  : theme.textTheme.bodyLarge)
                              ?.copyWith(color: theme.colorScheme.onSurface),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        // First of the ways on when every server failed.
        if (allFailed) ?offlineOffer,
        if (retry != null ||
            chooseSource != null ||
            alternative != null ||
            useDuckDuckGo != null ||
            anotherEngine != null ||
            anotherServer ||
            showFix ||
            switchInstance != null ||
            details != null) ...[
          SizedBox(height: allFailed && offlineOffer != null ? 4 : 8),
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
              ] else if (alternative != null)
                FilledButton.tonalIcon(
                  key: alternative.key,
                  onPressed: alternative.onPressed,
                  icon: Icon(alternative.icon),
                  label: Text(alternative.label),
                ),
              if (useDuckDuckGo != null)
                TextButton.icon(
                  key: const Key('translate_error_use_duckduckgo'),
                  onPressed: useDuckDuckGo,
                  icon: const Icon(Icons.alt_route),
                  label: Text(l10n.translateErrorUseDuckDuckGo),
                ),
              if (anotherEngine != null)
                TextButton.icon(
                  key: const Key('translate_error_another_engine'),
                  onPressed: anotherEngine,
                  icon: const Icon(Icons.translate),
                  label: Text(l10n.translateErrorTryAnotherEngine),
                ),
              if (anotherServer)
                TextButton.icon(
                  key: const Key('translate_error_another_server'),
                  onPressed: () =>
                      unawaited(context.push<void>(AppRoutes.instances)),
                  icon: const Icon(Icons.dns_outlined),
                  label: Text(l10n.translateErrorChooseAnotherServer),
                ),
              ?retryButton,
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
                  onPressed: () => unawaited(context.push<void>(fixRoute)),
                  child: Text(fixLabel),
                ),
            ],
          ),
        ],
        ?downloadHere,
        if (!allFailed) ?offlineOffer,
        if (details != null) TranslateErrorDetails(details: details),
      ],
    );
  }

  /// The [TranslateCubit] above when its translation failed with [error]
  /// (the Translate screen's own error), else null.
  TranslateCubit? _translateOf(BuildContext context) {
    try {
      final cubit = context.read<TranslateCubit>();
      return identical(cubit.state.error, error) ? cubit : null;
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// "Translate with Google" or "Try next instance" for the Translate
  /// screen's failed translation (see the class docs), or null.
  ({Key key, String label, IconData icon, VoidCallback onPressed})?
  _alternative(BuildContext context, TranslateErrorInfo info) {
    final cubit = _translateOf(context);
    final failed = cubit?.state.engine;
    if (cubit == null || failed == null) return null;
    final l10n = context.l10n;
    if (error is MozhiApiException && failed.isMozhi) {
      if (!info.anotherInstanceMayHelp) return null;
      final SettingsCubit settings;
      try {
        settings = context.read<SettingsCubit>();
      } on ProviderNotFoundException {
        return null;
      }
      final instances = settings.state.instances;
      final next = nextInstanceUrl(
        currentInstanceUrl(context, instances),
        instances,
      );
      if (next == null) return null;
      return (
        key: const Key('translate_error_next_instance'),
        label: l10n.translateErrorTryNextInstance,
        icon: Icons.dns_outlined,
        onPressed: () => unawaited(
          _tryInstance(settings, cubit, next, _repositoryOf(context)),
        ),
      );
    }
    if (!failed.isAi && !failed.isMt) return null;
    final engine = translateAlternativeEngine(
      cubit.state,
      _repositoryOf(context),
    );
    if (engine == null) return null;
    return (
      key: const Key('translate_error_use_engine'),
      label: l10n.translateErrorUseEngine(engine.name),
      icon: Icons.translate,
      onPressed: () => unawaited(cubit.selectEngine(engine)),
    );
  }

  /// "Use DuckDuckGo when Google fails" for the Translate screen's own
  /// translation that failed with Google on every server, while that
  /// fallback is off and could take over
  /// (`TranslateCubit.duckDuckGoFallbackApplies` with it on), else null.
  /// The tap is the user's permission: it turns the fallback on and
  /// translates with DuckDuckGo (`TranslateCubit
  /// .useDuckDuckGoWhenGoogleFails`).
  VoidCallback? _useDuckDuckGo(BuildContext context) {
    final error = this.error;
    final cubit = _translateOf(context);
    if (error is! AllInstancesFailedException || cubit == null) return null;
    final AppSettings settings;
    try {
      settings = context.read<SettingsCubit>().state;
    } on ProviderNotFoundException {
      return null;
    }
    if (settings.fallbackToDuckDuckGo) return null;
    PrivacyMode? mode;
    try {
      mode = _repositoryOf(context)?.privacyMode;
    } on Object {
      // A repository test double without privacy settings.
      mode = null;
    }
    final applies = TranslateCubit.duckDuckGoFallbackApplies(
      error,
      engine: error.engine,
      settings: settings.copyWith(fallbackToDuckDuckGo: true),
      privacyMode: mode,
    );
    if (!applies) return null;
    return () => unawaited(cubit.useDuckDuckGoWhenGoogleFails());
  }

  /// Opens the engine picker when the Translate screen has another engine
  /// than the one that failed (not the on-device one: it has its own
  /// offer), else null. Picking one is the user's choice.
  VoidCallback? _anotherEngine(BuildContext context) {
    final state = _translateOf(context)?.state;
    if (state == null) return null;
    final failed = state.engine?.id;
    if (!state.engines.any((e) => e.id != failed && !e.isOffline)) return null;
    return () => unawaited(showEngineSheet(context));
  }

  /// Makes [url] the preferred instance and translates again once the app
  /// handed the new order to the repository (like `switchInstanceAndRetry`).
  /// The [repository] starts there and forgets its recent failure, also
  /// when it is first in the list already
  /// (`TranslationRepository.preferInstance`).
  static Future<void> _tryInstance(
    SettingsCubit settings,
    TranslateCubit cubit,
    String url,
    TranslationRepository? repository,
  ) async {
    settings.preferInstance(url);
    repository?.preferInstance(url);
    // The app applies the new order to the repository when the settings
    // stream delivers it (a microtask): retry after that.
    await Future<void>.delayed(Duration.zero);
    if (cubit.isClosed) return;
    await cubit.translate();
  }

  static TranslationRepository? _repositoryOf(BuildContext context) {
    try {
      return context.read<TranslationRepository>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// The [OfflinePairOffer] for a network failure of the translation of
  /// the [TranslateCubit] above (its [TranslateState.error] is [error]),
  /// or null: not a network failure, no Translate screen, the on-device
  /// engine failed, or [dense].
  Widget? _offlineOffer(BuildContext context) {
    if (dense || !isNetworkFailure(error)) return null;
    final TranslateState state;
    try {
      state = context.read<TranslateCubit>().state;
    } on ProviderNotFoundException {
      return null;
    }
    if (!identical(state.error, error) || (state.engine?.isOffline ?? false)) {
      return null;
    }
    return OfflinePairOffer.pair(
      key: const Key('translate_error_offline'),
      source: state.source.code,
      target: state.target.code,
    );
  }

  /// "Download German (25 MB)" for the languages of an
  /// [OfflineModelMissingException] (English needs no download), or null
  /// when it names none.
  /// For the Translate screen's own translation that failed for missing
  /// offline models ([OfflineModelMissingException]): their download right
  /// here ([OfflineDownloadAction]: "Download French (49.6 MB)" and
  /// "Manage languages"), or null (no Translate screen, no offline engine,
  /// only English named).
  Widget? _offlineDownload(BuildContext context) {
    final error = this.error;
    if (error is! OfflineModelMissingException) return null;
    if (_translateOf(context) == null) return null;
    final translator = maybeOfflineTranslator(context);
    if (translator == null || !translator.isAvailable) return null;
    final codes = {
      for (final code in error.languages)
        if (offlineLanguageKey(code) != 'en') code,
    };
    if (codes.isEmpty) return null;
    final details = offlineModelDetailsOf(translator);
    return Padding(
      key: const Key('translate_error_download'),
      padding: const EdgeInsets.only(top: 4),
      child: OfflineDownloadAction(
        translator: translator,
        downloads: [
          for (final code in codes)
            (
              code: code,
              name: context.languageNameOf(code),
              bytes: details?.downloadSize(code),
            ),
        ],
      ),
    );
  }

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
          name: _languageName(l10n, code),
          bytes: details?.downloadSize(code),
        ),
    ]);
  }
}

/// Builds with whether the device is offline ([deviceOfflineCheck], asked
/// once when it is first built; false until it answers).
class _DeviceOffline extends StatefulWidget {
  const new({required this.builder, super.key});

  final Widget Function(BuildContext context, {required bool offline}) builder;

  @override
  State<_DeviceOffline> createState() => _DeviceOfflineState();
}

class _DeviceOfflineState extends State<_DeviceOffline> {
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    bool offline;
    try {
      offline = await deviceOfflineCheck();
    } on Object {
      offline = false;
    }
    if (mounted && offline != _offline) setState(() => _offline = offline);
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, offline: _offline);
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
