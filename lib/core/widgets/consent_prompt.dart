import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

// ---------------------------------------------------------------------------
// Describing destinations
// ---------------------------------------------------------------------------

/// The display name of a Mozhi upstream engine id (`google` -> Google).
String upstreamEngineName(String engine) => switch (engine.toLowerCase()) {
  'google' => 'Google',
  'deepl' => 'DeepL',
  'duckduckgo' => 'DuckDuckGo',
  'yandex' => 'Yandex',
  'libre' || 'libretranslate' => 'LibreTranslate',
  'reverso' => 'Reverso',
  'mymemory' => 'MyMemory',
  'bing' => 'Bing',
  _ when engine.isEmpty => engine,
  _ => '${engine[0].toUpperCase()}${engine.substring(1)}',
};

/// The Mozhi upstream engine of [engineId] (`mozhi:google` -> `google`).
String? _mozhiEngineOf(String? engineId) {
  if (engineId == null || !engineId.startsWith('mozhi:')) return null;
  final engine = engineId.substring('mozhi:'.length);
  return engine.isEmpty ? null : engine;
}

/// The upstream engine text sent to [destination] reaches, if any: the
/// public instance's engine, or the Mozhi engine of [engineId] (a
/// self-hosted Mozhi passes the text on too).
String? _upstreamOf(DataDestination destination, String? engineId) =>
    switch (destination) {
      PublicInstanceDestination(:final engine?) => engine,
      SelfHostedDestination() => _mozhiEngineOf(engineId),
      _ => null,
    };

/// A short name for where text goes, as used in prompts and on the
/// destination chip: "On device", "your server (192.168.1.10)", "Google via
/// mozhi.example.org", "Claude". [engineId] adds the upstream engine of a
/// self-hosted Mozhi server.
String destinationLabel(
  AppLocalizations l10n,
  DataDestination destination, {
  String? engineId,
}) {
  final upstream = _upstreamOf(destination, engineId);
  return switch (destination) {
    OnDeviceDestination() => l10n.commonDestinationOnDevice,
    SelfHostedDestination(:final host) =>
      upstream == null
          ? l10n.commonDestinationOwnServer(host)
          : l10n.commonDestinationVia(upstreamEngineName(upstream), host),
    PublicInstanceDestination(:final host) => _hostOrPublic(
      l10n,
      host,
      upstream,
    ),
    CloudProviderDestination(:final name) => name,
  };
}

String _hostOrPublic(AppLocalizations l10n, String host, String? upstream) {
  final server = host.isEmpty ? l10n.commonDestinationPublicServer : host;
  return upstream == null
      ? server
      : l10n.commonDestinationVia(upstreamEngineName(upstream), server);
}

/// What the party behind [destination] can see, in plain language.
String destinationDescription(
  AppLocalizations l10n,
  DataDestination destination, {
  String? engineId,
}) {
  final upstream = _upstreamOf(destination, engineId);
  return switch (destination) {
    OnDeviceDestination() => l10n.commonDestinationOnDeviceBody,
    SelfHostedDestination(:final host) =>
      upstream == null
          ? l10n.commonDestinationSelfHostedBody(host)
          : l10n.commonDestinationSelfHostedUpstreamBody(
              host,
              upstreamEngineName(upstream),
            ),
    PublicInstanceDestination(:final host) =>
      upstream == null
          ? l10n.commonDestinationPublicBody(
              host.isEmpty ? l10n.commonDestinationPublicServer : host,
            )
          : l10n.commonDestinationPublicUpstreamBody(
              host.isEmpty ? l10n.commonDestinationPublicServer : host,
              upstreamEngineName(upstream),
            ),
    CloudProviderDestination(:final name) => l10n.commonDestinationCloudBody(
      name,
    ),
  };
}

/// The icon of [destination]: a phone for the device, a server for the
/// user's own, a globe for public servers and a cloud for cloud providers.
IconData destinationIcon(DataDestination destination) => switch (destination) {
  OnDeviceDestination() => Icons.phone_android,
  SelfHostedDestination() => Icons.dns_outlined,
  PublicInstanceDestination() => Icons.public,
  CloudProviderDestination() => Icons.cloud_outlined,
};

/// "German → English" for the language codes [source] and [target]
/// (`auto` is "Detect language").
String consentPairLabel(AppLocalizations l10n, String source, String target) {
  String name(String code) => code == Language.auto.code
      ? l10n.translateDetectLanguage
      : LanguageCatalog.nameOf(code);
  return l10n.commonConsentPair(name(source), name(target));
}

/// The "Always" button label for [consent]: "Always for German → English",
/// "Always into English" (detected source), "Always for Japanese" (one
/// language), or just "Always" (proofreading, detection).
String consentAlwaysLabel(
  AppLocalizations l10n,
  ConsentRequiredException consent,
) {
  final source = consent.source ?? Language.auto.code;
  final target = consent.target ?? Language.auto.code;
  if (source == Language.auto.code && target == Language.auto.code) {
    return l10n.commonConsentAlways;
  }
  if (source == target) {
    return l10n.commonConsentAlwaysFor(LanguageCatalog.nameOf(source));
  }
  // An auto-detected source approves every source language into [target]
  // (the pair key is `auto>target`): "Always into French".
  if (source == Language.auto.code) {
    return l10n.commonConsentAlwaysInto(LanguageCatalog.nameOf(target));
  }
  return l10n.commonConsentAlwaysFor(consentPairLabel(l10n, source, target));
}

/// Why the privacy settings stopped a request ([consent]), in one line.
String consentMessage(AppLocalizations l10n, ConsentRequiredException consent) {
  final destination = destinationLabel(
    l10n,
    consent.destination,
    engineId: consent.engineId,
  );
  return switch (consent.kind) {
    ConsentKind.offlineOnly => l10n.commonConsentErrorOfflineOnly,
    ConsentKind.cloudProvider => l10n.commonConsentErrorCloud(destination),
    ConsentKind.pair => l10n.commonConsentErrorPair(destination),
  };
}

/// Whether [consent] stopped an engine or language list (offline-first
/// mode loads them only once the user lets it), not a request with text.
bool isListConsent(ConsentRequiredException consent) =>
    consent.kind == ConsentKind.pair &&
    consent.source == null &&
    consent.target == null;

// ---------------------------------------------------------------------------
// Recording consent
// ---------------------------------------------------------------------------

/// What the user answered to a consent prompt.
enum ConsentChoice {
  /// This request only ([TranslationRepository.allowOnce]).
  once,

  /// From now on: the language pair (offline first), the provider (cloud
  /// providers) or the lists (offline first).
  always,
}

/// Records [choice] for [consent] in [settings] and [repository]; returns
/// whether the stopped request may be retried now. [ConsentKind
/// .offlineOnly] cannot be granted (false).
///
/// "Always" is saved in the settings (`approveNetworkPair`,
/// `consentToProvider`), which the app pushes to the repository, and also
/// lets the very next request through so that the retry does not depend on
/// when the settings arrive there.
///
/// [requests] is how many requests the stopped job makes (a web page or a
/// document asked once for all its parts); see
/// `TranslationRepository.allowOnce`.
bool grantConsent({
  required SettingsCubit settings,
  required TranslationRepository repository,
  required ConsentRequiredException consent,
  required ConsentChoice choice,
  int requests = 1,
}) {
  if (consent.kind == ConsentKind.offlineOnly) return false;
  if (isListConsent(consent)) {
    repository.allowMetadataRequests();
    return true;
  }
  if (choice == ConsentChoice.always) {
    if (consent.kind == ConsentKind.cloudProvider) {
      final provider = TranslationRepository.providerIdOf(consent.engineId);
      if (provider != null) settings.consentToProvider(provider);
    } else {
      settings.approveNetworkPair(
        TranslationRepository.pairKey(
          consent.source ?? Language.auto.code,
          consent.target ?? Language.auto.code,
        ),
      );
    }
  }
  repository.allowOnce(consent, requests: requests);
  return true;
}

/// An offer to translate on the device instead: `language` is the one to
/// download, `onDownload` opens the offline languages.
typedef OfflineOffer = ({String language, VoidCallback onDownload});

/// The [OfflineOffer] for [consent] when the device's offline engine
/// (an [OfflineTranslator] provided above [context]) supports its language
/// pair, else null.
OfflineOffer? offlineOfferFor(
  BuildContext context,
  ConsentRequiredException consent,
) {
  final OfflineTranslator translator;
  try {
    translator = context.read<OfflineTranslator>();
  } on ProviderNotFoundException {
    return null;
  }
  if (!translator.isAvailable) return null;
  final source = consent.source;
  final target = consent.target;
  if (target == null || target == Language.auto.code) return null;
  String primary(String code) =>
      LanguageMatcher.normalize(code).split('-').first.toLowerCase();
  final supported = {
    for (final code in translator.supportedLanguages) primary(code),
  };
  final languages = [
    if (source != null && source != Language.auto.code) source,
    target,
  ];
  if (!languages.every((code) => supported.contains(primary(code)))) {
    return null;
  }
  // English is the pivot language, which the device always has first.
  final download = languages.firstWhere(
    (code) => primary(code) != 'en',
    orElse: () => target,
  );
  final router = GoRouter.maybeOf(context);
  return (
    language: LanguageCatalog.nameOf(download),
    // Settings pages sit above the tabs: back returns here.
    onDownload: () => unawaited(router?.push<void>(AppRoutes.offline)),
  );
}

// ---------------------------------------------------------------------------
// The prompt
// ---------------------------------------------------------------------------

enum _Answer { once, always, download, changeMode }

/// Asks whether the text of the request [consent] stopped may leave the
/// device, in plain language (a dialog on wide windows, a bottom sheet on
/// phones), and records the answer (see [grantConsent]). Returns whether
/// the request may be retried now.
///
/// * [ConsentKind.pair]: "Send this text to …?" with what that party can
///   see (a public server's operator and its upstream engine, a cloud
///   provider under its privacy policy, the user's own server), and
///   **Once** / **Always for German → English** / **Cancel**. For Mozhi,
///   the other servers of the user's list are mentioned (the failover may
///   use them). With [onDownloadOffline], a secondary action "Download
///   [offlineLanguage] for offline use" (see [offlineOfferFor]).
/// * [ConsentKind.cloudProvider]: "Your text will be sent to …", **Allow**
///   (recorded with `SettingsCubit.consentToProvider`) / **Cancel**.
/// * [ConsentKind.offlineOnly]: an explanation with **Change privacy
///   mode** (opens the settings) / **Cancel**.
/// * A list request deferred in offline-first mode ([isListConsent]):
///   **Allow** loads the lists for this session.
///
/// Reads the [SettingsCubit] and [TranslationRepository] above [context].
/// [requests] as for [grantConsent].
Future<bool> requestConsent(
  BuildContext context,
  ConsentRequiredException consent, {
  VoidCallback? onDownloadOffline,
  String? offlineLanguage,
  int requests = 1,
}) async {
  final settings = context.read<SettingsCubit>();
  final repository = context.read<TranslationRepository>();
  final router = GoRouter.maybeOf(context);
  final instances = repository.instances.length;
  final wide = MediaQuery.sizeOf(context).width >= 600;

  Widget content(BuildContext routeContext) => _ConsentContent(
    consent: consent,
    otherInstances: consent.engineId.startsWith('mozhi:') ? instances - 1 : 0,
    offlineLanguage: onDownloadOffline == null ? null : offlineLanguage ?? '',
    canChangeMode: router != null,
    dialog: wide,
  );

  final answer = wide
      ? await showDialog<_Answer>(context: context, builder: content)
      : await showModalBottomSheet<_Answer>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          useSafeArea: true,
          builder: content,
        );
  switch (answer) {
    case _Answer.once:
      return grantConsent(
        settings: settings,
        repository: repository,
        consent: consent,
        choice: ConsentChoice.once,
        requests: requests,
      );
    case _Answer.always:
      return grantConsent(
        settings: settings,
        repository: repository,
        consent: consent,
        choice: ConsentChoice.always,
        requests: requests,
      );
    case _Answer.download:
      onDownloadOffline?.call();
      return false;
    case _Answer.changeMode:
      unawaited(router?.push<void>(AppRoutes.settings));
      return false;
    case null:
      return false;
  }
}

/// [requestConsent] with the offer to translate on the device instead
/// ([offlineOfferFor]) when the offline engine supports the pair.
Future<bool> askConsent(
  BuildContext context,
  ConsentRequiredException consent, {
  int requests = 1,
}) {
  final offer = consent.kind == ConsentKind.cloudProvider
      ? null
      : offlineOfferFor(context, consent);
  return requestConsent(
    context,
    consent,
    onDownloadOffline: offer?.onDownload,
    offlineLanguage: offer?.language,
    requests: requests,
  );
}

class _ConsentContent extends StatelessWidget {
  const new({
    required this.consent,
    required this.otherInstances,
    required this.offlineLanguage,
    required this.canChangeMode,
    required this.dialog,
  });

  final ConsentRequiredException consent;
  final int otherInstances;

  /// Non-null when the offline download is offered (empty: no name).
  final String? offlineLanguage;
  final bool canChangeMode;
  final bool dialog;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final destination = destinationLabel(
      l10n,
      consent.destination,
      engineId: consent.engineId,
    );
    void answer(_Answer value) => Navigator.of(context).pop(value);

    final String title;
    final paragraphs = <String>[];
    final actions = <Widget>[];
    Widget cancel() => TextButton(
      onPressed: () => Navigator.of(context).pop(),
      child: Text(l10n.commonCancel),
    );

    switch (consent.kind) {
      case ConsentKind.offlineOnly:
        title = l10n.commonConsentOfflineOnlyTitle;
        paragraphs.add(l10n.commonConsentOfflineOnlyBody(destination));
        actions.addAll([
          cancel(),
          if (canChangeMode)
            FilledButton(
              onPressed: () => answer(_Answer.changeMode),
              child: Text(l10n.commonConsentChangePrivacyMode),
            ),
        ]);
      case ConsentKind.cloudProvider:
        title = l10n.commonConsentCloudTitle(destination);
        paragraphs.add(l10n.commonConsentCloudBody(destination));
        actions.addAll([
          cancel(),
          FilledButton(
            onPressed: () => answer(_Answer.always),
            child: Text(l10n.commonConsentAllow),
          ),
        ]);
      case ConsentKind.pair when isListConsent(consent):
        title = l10n.commonConsentListsTitle(destination);
        paragraphs.add(l10n.commonConsentListsBody);
        actions.addAll([
          cancel(),
          FilledButton(
            onPressed: () => answer(_Answer.once),
            child: Text(l10n.commonConsentAllow),
          ),
        ]);
      case ConsentKind.pair:
        title = l10n.commonConsentSendTitle(destination);
        paragraphs
          ..add(
            destinationDescription(
              l10n,
              consent.destination,
              engineId: consent.engineId,
            ),
          )
          ..addAll([
            if (otherInstances > 0)
              l10n.commonConsentMozhiListNote(otherInstances),
            l10n.commonConsentPairHint,
          ]);
        actions.addAll([
          cancel(),
          OutlinedButton(
            onPressed: () => answer(_Answer.once),
            child: Text(l10n.commonConsentOnce),
          ),
          FilledButton(
            onPressed: () => answer(_Answer.always),
            child: Text(consentAlwaysLabel(l10n, consent)),
          ),
        ]);
    }

    final language = offlineLanguage;
    final download = language == null
        ? null
        : Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => answer(_Answer.download),
              icon: const Icon(Icons.download_for_offline_outlined),
              label: Text(l10n.commonConsentDownloadOffline(language)),
            ),
          );

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, paragraph) in paragraphs.indexed)
          Padding(
            padding: EdgeInsets.only(top: index == 0 ? 0 : 12),
            child: Text(
              paragraph,
              style: index == 0
                  ? theme.textTheme.bodyLarge
                  : theme.textTheme.bodyMedium?.copyWith(
                      color: AppPalette.of(context).secondaryText,
                    ),
            ),
          ),
        if (download != null) ...[const SizedBox(height: 8), download],
      ],
    );
    final icon = Icon(destinationIcon(consent.destination));

    if (dialog) {
      return AlertDialog(
        icon: icon,
        title: Text(title),
        content: SingleChildScrollView(child: body),
        actions: actions,
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IconTheme.merge(
            data: IconThemeData(color: theme.colorScheme.primary, size: 32),
            child: icon,
          ),
          const SizedBox(height: 12),
          Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          body,
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: actions,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Inline prompt
// ---------------------------------------------------------------------------

/// A quiet prompt shown in place of a result when a request that started
/// by itself (instant translation, text from another app) needs consent:
/// it never opens a dialog by itself. Its actions record the answer like
/// [requestConsent]; [onGranted] then retries the request. **Details**
/// opens the full prompt.
class ConsentInlinePrompt extends StatelessWidget {
  const new({
    required this.consent,
    required this.onGranted,
    this.requests = 1,
    super.key,
  });

  final ConsentRequiredException consent;

  /// The request may be retried.
  final VoidCallback onGranted;

  /// How many requests the stopped job makes (see [grantConsent]).
  final int requests;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final destination = destinationLabel(
      l10n,
      consent.destination,
      engineId: consent.engineId,
    );
    final message = switch (consent.kind) {
      ConsentKind.offlineOnly => l10n.commonConsentInlineOfflineOnly,
      ConsentKind.cloudProvider => l10n.commonConsentInlineCloud(destination),
      ConsentKind.pair when isListConsent(consent) =>
        l10n.commonConsentInlineLists(destination),
      ConsentKind.pair => l10n.commonConsentInline(destination),
    };

    void grant(ConsentChoice choice) {
      final granted = grantConsent(
        settings: context.read<SettingsCubit>(),
        repository: context.read<TranslationRepository>(),
        consent: consent,
        choice: choice,
        requests: requests,
      );
      if (granted) onGranted();
    }

    Future<void> details() async {
      if (await askConsent(context, consent, requests: requests)) {
        onGranted();
      }
    }

    final scheme = theme.colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: AppPalette.of(context).hairline),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 12),
                    child: Icon(
                      destinationIcon(consent.destination),
                      size: 20,
                      color: scheme.primary,
                    ),
                  ),
                  Expanded(
                    child: Text(message, style: theme.textTheme.bodyMedium),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: () => unawaited(details()),
                    child: Text(l10n.commonConsentDetails),
                  ),
                  ...switch (consent.kind) {
                    ConsentKind.offlineOnly => const <Widget>[],
                    ConsentKind.cloudProvider => [
                      TextButton(
                        onPressed: () => grant(ConsentChoice.always),
                        child: Text(l10n.commonConsentAllow),
                      ),
                    ],
                    ConsentKind.pair when isListConsent(consent) => [
                      TextButton(
                        onPressed: () => grant(ConsentChoice.once),
                        child: Text(l10n.commonConsentAllow),
                      ),
                    ],
                    ConsentKind.pair => [
                      TextButton(
                        onPressed: () => grant(ConsentChoice.once),
                        child: Text(l10n.commonConsentOnce),
                      ),
                      TextButton(
                        onPressed: () => grant(ConsentChoice.always),
                        child: Text(consentAlwaysLabel(l10n, consent)),
                      ),
                    ],
                  },
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Destination chip
// ---------------------------------------------------------------------------

/// A small outlined pill naming where a result's text went (phone for the
/// device, server for the user's own, globe for a public server — "Google
/// via mozhi.example.org" —, cloud for a cloud provider). Tapping it
/// explains what that party can see ([showDestinationSheet]).
class DestinationChip extends StatelessWidget {
  const new({required this.destination, this.engineId, super.key});

  final DataDestination destination;

  /// The engine that produced the result (names a self-hosted Mozhi's
  /// upstream engine).
  final String? engineId;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final label = destinationLabel(l10n, destination, engineId: engineId);
    return Semantics(
      button: true,
      label: l10n.commonDestinationChipSemantics(label),
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => unawaited(
            showDestinationSheet(context, destination, engineId: engineId),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Center(
              widthFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: palette.hairline),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        destinationIcon(destination),
                        size: 14,
                        color: palette.secondaryText,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: palette.secondaryText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Explains what the party behind [destination] can see.
Future<void> showDestinationSheet(
  BuildContext context,
  DataDestination destination, {
  String? engineId,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.commonDestinationSheetTitle,
              style: theme.textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(destinationIcon(destination)),
            title: Text(
              destinationLabel(l10n, destination, engineId: engineId),
            ),
            subtitle: Text(
              destinationDescription(l10n, destination, engineId: engineId),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.commonClose),
            ),
          ),
        ],
      ),
    );
  },
);

// ---------------------------------------------------------------------------
// Opening the prompt for explicit actions
// ---------------------------------------------------------------------------

/// Opens the consent prompt ([askConsent]) whenever [consentOf] reports a
/// new `ConsentRequiredException` in the state of [B] (one the user's own
/// action ran into: Proofread, Look up, Translate, ...), and calls
/// [onGranted] once consent is recorded, to retry. Each refusal is a new
/// exception, so the same refusal never opens the prompt twice.
class ConsentDialogListener<B extends StateStreamable<S>, S>
    extends StatelessWidget {
  const new({
    required this.consentOf,
    required this.onGranted,
    required this.child,
    this.requestsOf,
    super.key,
  });

  /// The refusal in a state, or null.
  final ConsentRequiredException? Function(S state) consentOf;

  /// How many requests the stopped job makes (see [grantConsent]; 1 by
  /// default).
  final int Function(S state)? requestsOf;

  /// Retries the stopped action.
  final void Function(BuildContext context) onGranted;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BlocListener<B, S>(
      listenWhen: (previous, current) {
        final consent = consentOf(current);
        return consent != null && !identical(consent, consentOf(previous));
      },
      listener: (context, state) async {
        final consent = consentOf(state);
        if (consent == null) return;
        final requests = requestsOf?.call(state) ?? 1;
        if (await askConsent(context, consent, requests: requests) &&
            context.mounted) {
          onGranted(context);
        }
      },
      child: child,
    );
  }
}
