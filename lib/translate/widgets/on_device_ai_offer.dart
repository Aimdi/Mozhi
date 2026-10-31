import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/on_device_ai_access.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/on_device_ai/view/model_size.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/on_device_ai_offer_cubit.dart';

/// The translate screen's one-time card offering on-device AI ("Translate
/// and explain with AI that stays on your phone"), where it can run: on a
/// phone with on-device AI ([models], default the app's,
/// [maybeOnDeviceModels]) where a model fits, none is installed and no AI
/// provider is set up (see [OnDeviceAiOfferCubit]). "See models" opens the
/// On-device AI settings; "Not now" and "Don't show again" put it away
/// ([store], default the app's preferences; without them it is not
/// offered). It never downloads anything.
/// Shows nothing elsewhere (the web, phones that can't run it).
class OnDeviceAiOffer extends StatelessWidget {
  const new({this.models, this.store, super.key});

  final OnDeviceModels? models;
  final KeyValueStore? store;

  @override
  Widget build(BuildContext context) {
    final models = this.models ?? maybeOnDeviceModels(context);
    final store = this.store ?? _maybeStore(context);
    // Without the models, or a place to remember the answer: no offer.
    if (models == null || store == null) return const SizedBox.shrink();
    return BlocProvider(
      create: (context) {
        final cubit = OnDeviceAiOfferCubit(models: models, store: store);
        unawaited(cubit.load());
        return cubit;
      },
      child: const OnDeviceAiOfferView(),
    );
  }

  static KeyValueStore? _maybeStore(BuildContext context) {
    try {
      return context.read<KeyValueStore>();
    } on ProviderNotFoundException {
      return null;
    }
  }
}

/// The card of [OnDeviceAiOffer], while [OnDeviceAiOfferCubit] shows it
/// and no AI provider exists (`AppSettings.providers`).
class OnDeviceAiOfferView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<OnDeviceAiOfferCubit>().state;
    final hasProvider = context.select<SettingsCubit, bool>(
      (cubit) => cubit.state.providers.any((p) => !p.isMtService),
    );
    final shown = state.shown && !hasProvider;
    final child = shown
        ? _Card(smallestDownload: state.smallestDownload)
        : const SizedBox(width: double.infinity);
    // Reduced motion: it just appears and goes.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: child,
    );
  }
}

class _Card extends StatelessWidget {
  const new({required this.smallestDownload});

  final int? smallestDownload;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);
    final cubit = context.read<OnDeviceAiOfferCubit>();
    final size = smallestDownload;
    const buttonSize = Size(48, 48);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: DecoratedBox(
          key: const Key('translate_on_device_ai_offer'),
          decoration: BoxDecoration(
            border: Border.all(color: palette.hairline),
            borderRadius: AppLook.of(context).cardRadius,
          ),
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ExcludeSemantics(
                          child: Icon(Icons.memory, color: scheme.primary),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Semantics(
                                header: true,
                                child: Text(
                                  l10n.translateOnDeviceAiOfferTitle,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                size == null
                                    ? l10n.translateOnDeviceAiOfferBody
                                    : l10n.translateOnDeviceAiOfferBodySize(
                                        formatModelSize(l10n, size),
                                      ),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: palette.secondaryText,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    children: [
                      TextButton(
                        key: const Key('translate_on_device_ai_offer_never'),
                        style: TextButton.styleFrom(minimumSize: buttonSize),
                        onPressed: () => unawaited(cubit.never()),
                        child: Text(l10n.translateOnDeviceAiOfferNever),
                      ),
                      TextButton(
                        key: const Key('translate_on_device_ai_offer_later'),
                        style: TextButton.styleFrom(minimumSize: buttonSize),
                        onPressed: () => unawaited(cubit.notNow()),
                        child: Text(l10n.translateOnDeviceAiOfferNotNow),
                      ),
                      FilledButton.tonal(
                        key: const Key('translate_on_device_ai_offer_open'),
                        style: FilledButton.styleFrom(minimumSize: buttonSize),
                        onPressed: () {
                          unawaited(cubit.opened());
                          openOnDeviceAiSettings(context);
                        },
                        child: Text(l10n.translateOnDeviceAiOfferOpen),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
