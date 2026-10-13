import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';
import 'package:mozhi/proofread/widgets/widgets.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// Kagi-style proofreading. Uses the AI engines known to [TranslateCubit]
/// (defaulting to its assist engine).
class ProofreadPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final uiLanguage = proofreadUiLanguage(Localizations.localeOf(context));
    return BlocProvider(
      create: (context) {
        final translate = context.read<TranslateCubit>().state;
        return ProofreadCubit(
          repository: context.read<TranslationRepository>(),
          engines: translate.engines,
          engine: translate.assistEngine,
          uiLanguage: uiLanguage,
        );
      },
      child: const ProofreadView(),
    );
  }
}

/// English name of the UI language, used for edit explanations.
String proofreadUiLanguage(Locale locale) {
  if (locale.languageCode == 'en') return 'English';
  return LanguageCatalog.byCode(locale.languageCode)?.name ?? 'English';
}

class ProofreadView extends StatelessWidget {
  const new({super.key});

  /// Width from which input and result are shown side by side.
  static const wideBreakpoint = 840.0;

  @override
  Widget build(BuildContext context) {
    final hasEngines = context.select(
      (cubit) => cubit.state.availableEngines.isNotEmpty,
    );
    final enginesLoading = context.select(
      (cubit) =>
          cubit.state.enginesStatus == EnginesStatus.loading,
    );

    final Widget body;
    if (hasEngines) {
      body = LayoutBuilder(
        builder: (context, constraints) =>
            constraints.maxWidth >= wideBreakpoint
            ? const _WideLayout()
            : const _NarrowLayout(),
      );
    } else if (enginesLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = const ProofreadEmptyState();
    }

    return BlocListener<TranslateCubit, TranslateState>(
      listenWhen: (previous, current) =>
          previous.engines != current.engines ||
          previous.assistEngine != current.assistEngine,
      listener: (context, state) => context.read<ProofreadCubit>().setEngines(
        state.engines,
        preferred: state.assistEngine,
      ),
      child: Scaffold(
        appBar: AppBar(title: Text(context.l10n.proofreadTitle)),
        body: SafeArea(top: false, child: body),
      ),
    );
  }
}

class _NarrowLayout extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              ProofreadInputCard(),
              ProofreadControls(),
              ProofreadButton(),
              ProofreadResultSection(),
            ],
          ),
        ),
      ),
    );
  }
}

class _WideLayout extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(24, 16, 12, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                ProofreadInputCard(),
                ProofreadControls(),
                ProofreadButton(),
              ],
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(12, 16, 24, 24),
            child: ProofreadResultSection(showPlaceholder: true),
          ),
        ),
      ],
    );
  }
}
