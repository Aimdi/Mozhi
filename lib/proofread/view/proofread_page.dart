import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';
import 'package:mozhi/proofread/widgets/widgets.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

/// Kagi-style proofreading. Uses the AI engines known to [TranslateCubit]
/// (defaulting to its assist engine).
///
/// [initialText] (from a link such as `/proofread?text=…`) is put into the
/// input, cut to [maxLinkTextLength]; it is never proofread without the
/// user asking. A different [initialText] later (another link while the
/// tab is alive) replaces the input again.
class ProofreadPage extends StatelessWidget {
  const new({this.initialText, super.key});

  /// Text handed over by a link; null or blank leaves the input alone.
  final String? initialText;

  /// Longest text a link may put into the input (the limit for text from
  /// outside the app, [TranslateCubit.maxExternalInputLength]).
  static const int maxLinkTextLength = TranslateCubit.maxExternalInputLength;

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
          usageTracker: _usageTracker(context),
        );
      },
      child: _LinkedText(text: initialText, child: const ProofreadView()),
    );
  }
}

/// Puts link text into the [ProofreadCubit]'s input when it first arrives
/// and whenever it changes.
class _LinkedText extends StatefulWidget {
  const new({required this.text, required this.child});

  final String? text;
  final Widget child;

  @override
  State<_LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<_LinkedText> {
  @override
  void initState() {
    super.initState();
    _apply(widget.text);
  }

  @override
  void didUpdateWidget(_LinkedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) _apply(widget.text);
  }

  void _apply(String? text) {
    if (text == null || text.trim().isEmpty) return;
    context.read<ProofreadCubit>().setInput(
      _cut(text, ProofreadPage.maxLinkTextLength),
    );
  }

  /// [text] cut to [length] UTF-16 units without splitting a surrogate
  /// pair.
  static String _cut(String text, int length) {
    if (text.length <= length) return text;
    var end = length;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return text.substring(0, end);
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
    final hasEngines = context.select<ProofreadCubit, bool>(
      (cubit) => cubit.state.availableEngines.isNotEmpty,
    );
    final enginesStatus = context.select<TranslateCubit, EnginesStatus>(
      (cubit) => cubit.state.enginesStatus,
    );

    final Widget body;
    if (hasEngines) {
      body = LayoutBuilder(
        builder: (context, constraints) =>
            constraints.maxWidth >= wideBreakpoint
            ? const _WideLayout()
            : const _NarrowLayout(),
      );
    } else if (enginesStatus == EnginesStatus.loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (enginesStatus == EnginesStatus.failure) {
      // Loading failed, which says nothing about configured AI providers.
      body = ProofreadEnginesError(
        onRetry: () => unawaited(
          context.read<TranslateCubit>().loadEngines(refresh: true),
        ),
      );
    } else {
      body = const ProofreadEmptyState();
    }

    return BlocListener<TranslateCubit, TranslateState>(
      // Engine equality ignores details such as the model, so compare
      // instances to pick up edited providers.
      listenWhen: (previous, current) =>
          !identical(previous.engines, current.engines) ||
          !identical(previous.assistEngine, current.assistEngine),
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
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(24, 16, 12, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                ProofreadInputCard(),
                ProofreadControls(initiallyExpanded: true),
                ProofreadButton(),
              ],
            ),
          ),
        ),
        // The panes are divided by a hairline, not boxed.
        Hairline(vertical: true),
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

/// The app's usage tracker, or null when none is provided (e.g. in tests).
UsageTracker? _usageTracker(BuildContext context) {
  try {
    return context.read<UsageTracker>();
  } on ProviderNotFoundException {
    return null;
  }
}
