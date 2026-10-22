import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/view/backup_restore_dialog.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/network.dart'
    show describeNetworkPolicyError;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/unavailable_offline_translator.dart';
import 'package:mozhi/onboarding/cubit/onboarding_cubit.dart';
import 'package:mozhi/onboarding/onboarding_redirect.dart';
import 'package:mozhi/onboarding/widgets/languages_step.dart';
import 'package:mozhi/onboarding/widgets/onboarding_nav_bar.dart';
import 'package:mozhi/onboarding/widgets/privacy_step.dart';
import 'package:mozhi/onboarding/widgets/service_step.dart';
import 'package:mozhi/onboarding/widgets/step_layout.dart';
import 'package:mozhi/onboarding/widgets/welcome_step.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// The first-run flow (route: [onboardingLocation]): welcome, privacy mode,
/// default languages with their offline downloads and the online service.
/// Where the device can't translate on its own (the web) it is three
/// steps: the privacy mode is a switch on the online service step (see
/// [OnboardingCubit]). Needs a [TranslationRepository] and a
/// [SettingsCubit] above it.
///
/// The languages step downloads with [translator] and remembers "Wi-Fi
/// only" in [store] when given, otherwise with the [OfflineTranslator] and
/// [KeyValueStore] provided above (falling back to an
/// [UnavailableOfflineTranslator] and the platform preferences); [details]
/// defaults to [offlineModelDetailsOf] the translator. With a
/// [TranslateCubit] above, the picked languages go through it, so the
/// translator shows them right away.
class OnboardingPage extends StatelessWidget {
  const new({
    this.finishLocation = AppRoutes.translate,
    this.translator,
    this.store,
    this.details,
    super.key,
  });

  /// Where "Start translating" / "Skip" navigate (with `context.go`); "Open
  /// AI provider settings" pushes those above it.
  final String finishLocation;
  final OfflineTranslator? translator;
  final KeyValueStore? store;
  final OfflineModelDetails? details;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) {
            final translate = _maybeRead<TranslateCubit>(context);
            return OnboardingCubit(
              repository: context.read<TranslationRepository>(),
              settings: context.read<SettingsCubit>(),
              // The network policy's refusals (plain http to a public
              // server, .onion without a proxy) say what is wrong. Looked
              // up when a failure is described (not while the cubit is
              // created).
              describeError: (error) =>
                  (context.mounted
                      ? describeNetworkPolicyError(context.l10n, error)
                      : null) ??
                  onboardingErrorMessage(error),
              setLanguages: translate == null
                  ? null
                  : ({source, target}) {
                      if (source != null) translate.setSource(source);
                      if (target != null) translate.setTarget(target);
                    },
            );
          },
        ),
        // Created (and loaded) when the languages step first needs it.
        BlocProvider(
          create: (context) {
            final engine =
                translator ??
                _maybeRead<OfflineTranslator>(context) ??
                const UnavailableOfflineTranslator();
            final cubit = OfflineModelsCubit(
              translator: engine,
              store:
                  store ??
                  _maybeRead<KeyValueStore>(context) ??
                  PreferencesStore(),
              details: details ?? offlineModelDetailsOf(engine),
            );
            unawaited(cubit.load());
            return cubit;
          },
        ),
      ],
      child: OnboardingView(finishLocation: finishLocation),
    );
  }

  static T? _maybeRead<T>(BuildContext context) {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }
}

/// Pages of the onboarding (expects an [OnboardingCubit] and, for the
/// languages step, an [OfflineModelsCubit] above it).
class OnboardingView extends StatefulWidget {
  const new({this.finishLocation = AppRoutes.translate, super.key});

  final String finishLocation;

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  late final PageController _controller = PageController(
    initialPage: _pageOf(context.read<OnboardingCubit>().state),
  );

  /// The page of [state]'s step among its steps.
  static int _pageOf(OnboardingState state) =>
      state.steps.indexOf(state.step).clamp(0, state.steps.length - 1);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Whether a [BackupRegistry] is provided (the app; not every test).
  bool get _hasBackups {
    try {
      context.read<BackupRegistry>();
      return true;
    } on ProviderNotFoundException {
      return false;
    }
  }

  /// Restores a backup; once restored, setup is done.
  Future<void> _restoreBackup() async {
    final restored = await showBackupRestoreDialog(context);
    if (restored && mounted) _finish();
  }

  /// Goes to [OnboardingView.finishLocation]; with [above] (the AI
  /// provider settings) that page is pushed on top of it, so its back
  /// arrow returns to the tabs.
  void _finish([String? above]) {
    context.read<OnboardingCubit>().finish();
    final router = GoRouter.of(context)..go(widget.finishLocation);
    if (above != null) unawaited(router.push<void>(above));
  }

  void _showStep(OnboardingState state) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!_controller.hasClients) return;
    final page = _pageOf(state);
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpToPage(page);
    } else {
      _controller.animateToPage(
        page,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubicEmphasized,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<OnboardingCubit>();
    final step = context.select<OnboardingCubit, OnboardingStep>(
      (c) => c.state.step,
    );
    final steps = context.select<OnboardingCubit, List<OnboardingStep>>(
      (c) => c.state.steps,
    );
    final isLast = step == steps.last;
    return BlocListener<OnboardingCubit, OnboardingState>(
      listenWhen: (previous, current) => previous.step != current.step,
      listener: (context, state) => _showStep(state),
      child: PopScope(
        canPop: step == steps.first,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) cubit.back();
        },
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            actions: [
              if (!isLast)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(64, 48),
                    ),
                    onPressed: _finish,
                    child: Text(l10n.onboardingSkip),
                  ),
                ),
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: false,
            child: PageView(
              controller: _controller,
              // Navigation goes through the buttons so that forms and the
              // horizontal gestures inside them never fight with paging.
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final page in steps)
                  switch (page) {
                    OnboardingStep.welcome => WelcomeStep(
                      onRestore: _hasBackups ? _restoreBackup : null,
                    ),
                    OnboardingStep.privacy => const PrivacyStep(),
                    OnboardingStep.languages => const OnboardingKeepAlive(
                      child: LanguagesStep(),
                    ),
                    OnboardingStep.service => OnboardingKeepAlive(
                      child: ServiceStep(
                        onOpenAiSettings: () => _finish(AppRoutes.providers),
                      ),
                    ),
                  },
              ],
            ),
          ),
          bottomNavigationBar: OnboardingNavBar(
            step: step,
            steps: steps,
            onBack: cubit.back,
            onNext: cubit.next,
            onFinish: _finish,
          ),
        ),
      ),
    );
  }
}
