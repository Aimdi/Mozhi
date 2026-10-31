import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/offline_offer.dart';
import 'package:translation_repository/translation_repository.dart';

/// Why the privacy mode "Offline only" leaves nothing to translate with on
/// this device.
enum OfflineOnlyGap {
  /// The web app's on-device engine can't run in this browser (the
  /// Offline languages screen says why: no WebAssembly SIMD, plain http,
  /// no storage...).
  unsupportedBrowser,

  /// The Android app's on-device engine can't run on this device (its
  /// processor).
  unsupportedDevice,

  /// The on-device engine runs, but no language pack is downloaded yet.
  noLanguagePacks,
}

/// Whether this is the Android app, where the on-device engine is always
/// built in (so only the device can keep it from running).
bool get _androidApp =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// What keeps the device's offline engine [translator] (null: none) from
/// translating anything, at once: no engine
/// ([OfflineOnlyGap.unsupportedBrowser] or, in the Android app,
/// [OfflineOnlyGap.unsupportedDevice]); null when it
/// is available (its language packs are checked by [offlineOnlyGap]).
OfflineOnlyGap? offlineEngineGap(OfflineTranslator? translator) {
  if (translator != null && translator.isAvailable) return null;
  return _androidApp
      ? OfflineOnlyGap.unsupportedDevice
      : OfflineOnlyGap.unsupportedBrowser;
}

/// What keeps the device's offline engine [translator] (null: none) from
/// translating anything: [offlineEngineGap], else
/// [OfflineOnlyGap.noLanguagePacks] while no language is downloaded
/// ([offlineReadyLanguages]); null when it can translate something.
Future<OfflineOnlyGap?> offlineOnlyGap(OfflineTranslator? translator) async {
  final gap = offlineEngineGap(translator);
  if (gap != null || translator == null) return gap;
  final ready = await offlineReadyLanguages(translator);
  return ready.isEmpty ? OfflineOnlyGap.noLanguagePacks : null;
}

/// In place of the prompt for a request that the privacy mode "Offline
/// only" stopped ([consent], [ConsentKind.offlineOnly]): when nothing on
/// this device can translate either ([offlineOnlyGap]), says so with the
/// way out, instead of blaming the engine for needing the network:
///
/// * Android before any language pack is downloaded: "No language packs on
///   this device yet…" with "Download German (25 MB)" (the pair of
///   [consent], when the engine supports it) or "Download languages", which
///   opens the offline languages; back here, the device is checked again.
/// * A browser (or an Android device) that can't run the engine: offline
///   translation can't run here, switch the privacy mode, with
///   "Change privacy mode", which opens the settings.
///
/// Otherwise (some language pack is downloaded) it shows [fallback], the
/// usual prompt. Shows nothing while the device is being checked.
///
/// The message is a live region, so screen readers announce it.
class OfflineOnlyNotice extends StatefulWidget {
  const new({
    required this.consent,
    required this.fallback,
    this.translator,
    super.key,
  });

  /// The stopped request (its language pair names the download).
  final ConsentRequiredException consent;

  /// Shown when the device can translate offline.
  final Widget fallback;

  /// The offline engine; defaults to the one provided above.
  final OfflineTranslator? translator;

  @override
  State<OfflineOnlyNotice> createState() => _OfflineOnlyNoticeState();
}

class _OfflineOnlyNoticeState extends State<OfflineOnlyNotice> {
  OfflineTranslator? _translator;
  bool _checked = false;
  OfflineOnlyGap? _gap;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_checked || _translator != null) return;
    _translator = widget.translator ?? maybeOfflineTranslator(context);
    // Without an engine there is nothing to wait for.
    final gap = offlineEngineGap(_translator);
    if (gap != null) {
      _gap = gap;
      _checked = true;
    } else {
      unawaited(_check());
    }
  }

  Future<void> _check() async {
    final gap = await offlineOnlyGap(_translator);
    if (!mounted) return;
    setState(() {
      _gap = gap;
      _checked = true;
    });
  }

  Future<void> _openOfflineModels() async {
    await GoRouter.of(context).push<void>(AppRoutes.offline);
    // A language pack may have been downloaded meanwhile.
    if (mounted) await _check();
  }

  /// "Download German (25 MB)" for the language pair of the stopped
  /// request when the engine supports it, else "Download languages".
  String _downloadLabel(AppLocalizations l10n) {
    final translator = _translator;
    final target = widget.consent.target;
    final downloads = translator == null || target == null
        ? null
        : offlineDownloadsFor(
            translator,
            source: widget.consent.source,
            target: target,
            ready: const {},
          );
    return downloads == null || downloads.isEmpty
        ? l10n.translateOfflineModelsAction
        : offlineDownloadLabel(l10n, downloads);
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) return const SizedBox.shrink();
    final gap = _gap;
    if (gap == null) return widget.fallback;
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final message = switch (gap) {
      OfflineOnlyGap.noLanguagePacks =>
        l10n.translateOfflineOnlyNoLanguagePacks,
      OfflineOnlyGap.unsupportedBrowser =>
        l10n.translateOfflineOnlyBrowserUnsupported,
      OfflineOnlyGap.unsupportedDevice =>
        l10n.translateOfflineOnlyDeviceUnsupported,
    };
    final action = gap == OfflineOnlyGap.noLanguagePacks
        ? TextButton.icon(
            key: const Key('translate_offline_only_download'),
            onPressed: () => unawaited(_openOfflineModels()),
            icon: const Icon(Icons.download_for_offline_outlined),
            label: Text(_downloadLabel(l10n)),
          )
        : TextButton.icon(
            key: const Key('translate_offline_only_privacy'),
            // Settings pages sit above the tabs: back returns here.
            onPressed: () =>
                unawaited(GoRouter.of(context).push<void>(AppRoutes.settings)),
            icon: const Icon(Icons.privacy_tip_outlined),
            label: Text(l10n.commonConsentChangePrivacyMode),
          );
    return Semantics(
      key: const Key('translate_offline_only_notice'),
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: AppPalette.of(context).hairline),
          borderRadius: AppLook.of(context).cardRadius,
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.only(top: 2, end: 12),
                    child: Icon(
                      Icons.wifi_off_outlined,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      message,
                      key: const Key('translate_offline_only_message'),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Align(alignment: AlignmentDirectional.centerEnd, child: action),
            ],
          ),
        ),
      ),
    );
  }
}
