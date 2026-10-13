import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/cubit/onboarding_cubit.dart';
import 'package:mozhi/onboarding/onboarding_redirect.dart';
import 'package:mozhi/onboarding/widgets/ai_step.dart';
import 'package:mozhi/onboarding/widgets/done_step.dart';
import 'package:mozhi/onboarding/widgets/onboarding_nav_bar.dart';
import 'package:mozhi/onboarding/widgets/service_step.dart';
import 'package:mozhi/onboarding/widgets/step_layout.dart';
import 'package:mozhi/onboarding/widgets/welcome_step.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// The first-run flow (route: [onboardingLocation]). Needs a
/// [TranslationRepository] and a [SettingsCubit] above it.
class OnboardingPage extends StatelessWidget {
  const new({this.finishLocation = '/translate', super.key});

  /// Where "Start translating" / "Skip" navigate (with `context.go`).
  final String finishLocation;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => OnboardingCubit(
        repository: context.read<TranslationRepository>(),
        settings: context.read<SettingsCubit>(),
      ),
      child: OnboardingView(finishLocation: finishLocation),
    );
  }
}

/// Pages of the onboarding (expects an [OnboardingCubit] above it).
class OnboardingView extends StatefulWidget {
  const new({this.finishLocation = '/translate', super.key});

  final String finishLocation;

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  late final PageController _controller = PageController(
    initialPage: context.read<OnboardingCubit>().state.step.index,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish() {
    context.read<OnboardingCubit>().finish();
    context.go(widget.finishLocation);
  }

  void _showStep(OnboardingStep step) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!_controller.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpToPage(step.index);
    } else {
      _controller.animateToPage(
        step.index,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubicEmphasized,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<OnboardingCubit>();
    final step = context.select((OnboardingCubit c) => c.state.step);
    final isLast = step == OnboardingStep.values.last;
    return BlocListener<OnboardingCubit, OnboardingState>(
      listenWhen: (previous, current) => previous.step != current.step,
      listener: (context, state) => _showStep(state.step),
      child: PopScope(
        canPop: step.index == 0,
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
              children: const [
                WelcomeStep(),
                OnboardingKeepAlive(child: ServiceStep()),
                OnboardingKeepAlive(child: AiStep()),
                DoneStep(),
              ],
            ),
          ),
          bottomNavigationBar: OnboardingNavBar(
            step: step,
            onBack: cubit.back,
            onNext: cubit.next,
            onFinish: _finish,
          ),
        ),
      ),
    );
  }
}
