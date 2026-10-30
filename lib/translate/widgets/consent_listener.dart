import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/engine_selector.dart';
import 'package:mozhi/translate/widgets/first_use_hint.dart';
import 'package:mozhi/translate/widgets/offline_offer.dart';
import 'package:mozhi/translate/widgets/offline_only_notice.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens the consent prompt ([askConsent]) when a translation the user
/// asked for (Translate, Ctrl+Enter, a language change) stopped for the
/// privacy settings (`TranslateState.consent`), and translates again once
/// consent is given (`TranslateCubit.retryAfterConsent`).
///
/// Instant translations (`ConsentRequest.automatic`) never open it: the
/// output shows an inline prompt instead, so typing is never interrupted.
/// After Cancel the inline prompt stays.
///
/// When the on-device engine tried first and lacks the language
/// (`ConsentRequest.fromOnDevice`), the dialog offers the download of the
/// language it recognised ([onDeviceDownloadLanguage]), and an answer puts
/// the first-use hint away ([TranslateFirstUseHint.markSeen]).
///
/// Nor does a request "Offline only" stopped while the device has nothing
/// to translate with either ([offlineOnlyGap]): the prompt would offer the
/// on-device engine, and the output's [OfflineOnlyNotice] already says
/// what to do.
class TranslateConsentListener extends StatelessWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BlocListener<TranslateCubit, TranslateState>(
      listenWhen: (previous, current) {
        final consent = current.consent;
        return consent != null &&
            !consent.automatic &&
            consent.id != previous.consent?.id;
      },
      listener: (context, state) => unawaited(_ask(context, state.consent!)),
      child: child,
    );
  }

  static Future<void> _ask(BuildContext context, ConsentRequest request) async {
    final consent = request.exception;
    final cubit = context.read<TranslateCubit>();
    if (consent.kind == ConsentKind.offlineOnly) {
      final gap = await offlineOnlyGap(maybeOfflineTranslator(context));
      if (gap != null || !context.mounted) return;
    }
    if (!request.fromOnDevice) {
      if (await askConsent(context, consent)) await cubit.retryAfterConsent();
      return;
    }
    // The device tried first: offer the language it recognised.
    final language = onDeviceDownloadLanguage(
      maybeOfflineTranslator(context),
      source: request.onDeviceSource ?? consent.source,
      target: consent.target,
    );
    final router = GoRouter.maybeOf(context);
    final granted = await requestConsent(
      context,
      consent,
      offlineLanguage: language,
      onDownloadOffline: language == null || router == null
          ? null
          : () => unawaited(router.push<void>(AppRoutes.offline)),
    );
    if (!granted) return;
    if (context.mounted) unawaited(TranslateFirstUseHint.markSeen(context));
    await cubit.retryAfterConsent();
  }
}

/// The name of the language to download so that [translator] translates
/// [source] (a code; null or `auto` while detecting) into [target] on the
/// device: the first of them that is not English (built in), when the
/// engine supports both. Null otherwise (also without an engine).
String? onDeviceDownloadLanguage(
  OfflineTranslator? translator, {
  required String? source,
  required String? target,
}) {
  if (translator == null || !translator.isAvailable || target == null) {
    return null;
  }
  final supported = {
    for (final code in translator.supportedLanguages) offlineLanguageKey(code),
  };
  final codes = [
    if (source != null && source != Language.auto.code) source,
    target,
  ];
  if (!codes.every((code) => supported.contains(offlineLanguageKey(code)))) {
    return null;
  }
  for (final code in codes) {
    if (offlineLanguageKey(code) != 'en') return LanguageCatalog.nameOf(code);
  }
  return null;
}

/// Shown when the engines are listed but none is selected: the engine that
/// was used is gone and the app does not pick another destination by
/// itself.
class ChooseEngineView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            key: const Key('translate_choose_engine'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.alt_route, size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Semantics(
                header: true,
                child: Text(
                  l10n.translateChooseEngineTitle,
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.translateChooseEngineBody,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: AppPalette.of(context).secondaryText,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => unawaited(showEngineSheet(context)),
                icon: const Icon(Icons.translate),
                label: Text(l10n.translateChooseEngineAction),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
