import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/engine_selector.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens the consent prompt ([askConsent]) when a translation the user
/// asked for (Translate, Ctrl+Enter, a language change) stopped for the
/// privacy settings (`TranslateState.consent`), and translates again once
/// consent is given (`TranslateCubit.retryAfterConsent`).
///
/// Instant translations (`ConsentRequest.automatic`) never open it: the
/// output shows an inline prompt instead, so typing is never interrupted.
/// After Cancel the inline prompt stays.
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
      listener: (context, state) =>
          unawaited(_ask(context, state.consent!.exception)),
      child: child,
    );
  }

  static Future<void> _ask(
    BuildContext context,
    ConsentRequiredException consent,
  ) async {
    final cubit = context.read<TranslateCubit>();
    if (await askConsent(context, consent)) {
      await cubit.retryAfterConsent();
    }
  }
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
