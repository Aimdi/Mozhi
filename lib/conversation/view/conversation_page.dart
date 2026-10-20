import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_mic.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/widgets/widgets.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/speech/widgets/speech_error_snack_bar.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/engine_selector.dart';
import 'package:mozhi/translate/widgets/no_engines_view.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:translation_repository/translation_repository.dart';

/// Conversation mode. Creates a [ConversationCubit] for the page's
/// lifetime: languages default from the app-wide [TranslateCubit] (its
/// source, or the detected language, and its target), translations use
/// its current engine and options.
///
/// Requires [TranslationRepository], [SpeechService], [TranslateCubit] and
/// `SettingsCubit` above it (all provided app-wide by `App`); a
/// [UsageTracker] above it (optional) counts AI requests. A tab of the
/// app: face-to-face mode is pushed as a full-screen route on the root
/// navigator, above the tabs.
class ConversationPage extends StatelessWidget {
  const new({this.micBuilder, this.share = shareConversationText, super.key});

  /// Builds each side's microphone button; null hides voice input.
  final ConversationMicBuilder? micBuilder;

  /// Shares the transcript (defaults to the platform share sheet).
  final ConversationShareCallback share;

  @override
  Widget build(BuildContext context) {
    // The device language is a fallback for side A (read here: providers
    // must not depend on inherited widgets in `create`).
    final deviceLanguageCode = Localizations.maybeLocaleOf(context)
        ?.languageCode;
    return BlocProvider(
      create: (context) {
        final translate = context.read<TranslateCubit>();
        final languages = ConversationCubit.defaultLanguages(
          translate.state,
          deviceLanguageCode: deviceLanguageCode,
        );
        return ConversationCubit(
          repository: context.read<TranslationRepository>(),
          speech: context.read<SpeechService>(),
          engine: () => translate.state.engine,
          options: () => translate.state.options,
          availableLanguages: () => translate.state.targetLanguages,
          languageA: languages.a,
          languageB: languages.b,
          usageTracker: _usageTracker(context),
        );
      },
      child: ConversationView(micBuilder: micBuilder, share: share),
    );
  }
}

/// The standard layout of the [ConversationCubit] above it: the
/// transcript (an empty conversation shows [ConversationHero]), the
/// language pair ([ConversationLanguagePill]) and one composer per side.
///
/// Face-to-face mode ([ConversationState.faceToFace]) is pushed as a
/// full-screen route ([ConversationFaceToFaceView]) on the root navigator,
/// above the tabs; leaving it (its toggle or back) pops it.
class ConversationView extends StatelessWidget {
  const new({this.micBuilder, this.share = shareConversationText, super.key});

  /// At and above this width the two composers sit side by side.
  static const double wideBreakpoint = 840;

  /// Below this width the app bar shows only the engine selector, and
  /// "Read translations aloud" moves into the overflow menu.
  static const double compactBreakpoint = 600;

  final ConversationMicBuilder? micBuilder;
  final ConversationShareCallback share;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final noEngines = _noEngines(context);
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < compactBreakpoint;

    return BlocListener<ConversationCubit, ConversationState>(
      // Every failure is kept in `lastSpeechFailure`.
      listenWhen: (previous, current) =>
          current.speechFailures > previous.speechFailures &&
          current.lastSpeechFailure != null,
      listener: (context, state) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        final failure = state.lastSpeechFailure!;
        final cubit = context.read<ConversationCubit>();
        showSpeechErrorSnackBar(
          context,
          failure.error,
          // Asked once: a refusal after consent only says why.
          onListenOnline: failure.asked
              ? null
              : (consent) => unawaited(
                  cubit.speak(
                    failure.turnId,
                    slow: failure.slow,
                    allowOnline: consent,
                  ),
                ),
        );
      },
      child: _FaceToFacePresenter(
        micBuilder: micBuilder,
        share: share,
        child: Scaffold(
          appBar: AppBar(
            titleSpacing: noEngines || !compact ? null : 8,
            title: noEngines
                ? Text(l10n.conversationTitle)
                : !compact
                ? Row(
                    children: [
                      Text(l10n.conversationTitle),
                      const SizedBox(width: 16),
                      const Flexible(child: EngineSelectorButton()),
                    ],
                  )
                : const EngineSelectorButton(),
            actions: noEngines
                ? const [TopLevelActions(), SizedBox(width: 4)]
                : [
                    const ConversationLayoutButton(),
                    if (!compact) const ConversationAutoSpeakButton(),
                    const TopLevelActions(),
                    ConversationMenuButton(
                      share: share,
                      showAutoSpeak: compact,
                    ),
                    const SizedBox(width: 4),
                  ],
          ),
          body: noEngines
              ? const NoEnginesView()
              : _StandardLayout(
                  micBuilder: micBuilder,
                  wide: width >= wideBreakpoint,
                ),
        ),
      ),
    );
  }
}

/// Whether no engine is configured (or loading them failed).
bool _noEngines(BuildContext context) =>
    context.select<TranslateCubit, bool>((cubit) {
      final state = cubit.state;
      return state.engines.isEmpty &&
          (state.enginesStatus == EnginesStatus.ready ||
              state.enginesStatus == EnginesStatus.failure);
    });

/// Pushes [ConversationFaceToFaceView] on the root navigator while the
/// [ConversationCubit]'s face-to-face mode is on, and turns the mode off
/// when that route is popped (back, or the layout toggle in it).
class _FaceToFacePresenter extends StatefulWidget {
  const new({
    required this.micBuilder,
    required this.share,
    required this.child,
  });

  final ConversationMicBuilder? micBuilder;
  final ConversationShareCallback share;
  final Widget child;

  @override
  State<_FaceToFacePresenter> createState() => _FaceToFacePresenterState();
}

class _FaceToFacePresenterState extends State<_FaceToFacePresenter> {
  Route<void>? _route;

  @override
  void initState() {
    super.initState();
    if (context.read<ConversationCubit>().state.faceToFace) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _show());
    }
  }

  @override
  void dispose() {
    // The route cannot outlive the page (it shares its cubit); the
    // navigator cannot change while the tree is being torn down.
    final route = _route;
    _route = null;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
    super.dispose();
  }

  void _show() {
    if (!mounted || _route != null) return;
    final cubit = context.read<ConversationCubit>();
    final route = _route = MaterialPageRoute<void>(
      builder: (_) => BlocProvider<ConversationCubit>.value(
        value: cubit,
        child: ConversationFaceToFaceView(
          micBuilder: widget.micBuilder,
          share: widget.share,
        ),
      ),
    );
    unawaited(
      Navigator.of(context, rootNavigator: true).push(route).then((_) {
        if (identical(_route, route)) _route = null;
        if (!cubit.isClosed && cubit.state.faceToFace) {
          cubit.setFaceToFace(enabled: false);
        }
      }),
    );
  }

  void _hide() {
    final route = _route;
    _route = null;
    if (route == null || !route.isActive) return;
    final navigator = route.navigator!;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) =>
      BlocListener<ConversationCubit, ConversationState>(
        listenWhen: (previous, current) =>
            previous.faceToFace != current.faceToFace,
        listener: (context, state) => state.faceToFace ? _show() : _hide(),
        child: widget.child,
      );
}

/// Face-to-face mode on its own full-screen route (see [ConversationView]):
/// the split screen, or the no-engines view should the engines go away.
class ConversationFaceToFaceView extends StatelessWidget {
  const new({this.micBuilder, this.share = shareConversationText, super.key});

  final ConversationMicBuilder? micBuilder;
  final ConversationShareCallback share;

  @override
  Widget build(BuildContext context) {
    if (_noEngines(context)) {
      return Scaffold(
        appBar: AppBar(title: Text(context.l10n.conversationTitle)),
        body: const NoEnginesView(),
      );
    }
    return Scaffold(
      body: _FaceToFaceLayout(micBuilder: micBuilder, share: share),
    );
  }
}

/// Shared layout: the transcript (or, while empty, the hero with the large
/// microphone), the language pair, one composer per side.
class _StandardLayout extends StatelessWidget {
  const new({required this.micBuilder, required this.wide});

  final ConversationMicBuilder? micBuilder;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final empty = context.select<ConversationCubit, bool>(
      (cubit) => cubit.state.turns.isEmpty,
    );
    final composerA = ConversationComposer(
      side: ConversationSide.a,
      micBuilder: micBuilder,
    );
    final composerB = ConversationComposer(
      side: ConversationSide.b,
      micBuilder: micBuilder,
    );
    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          key: const Key('conversation_standard_layout'),
          constraints: const BoxConstraints(maxWidth: 1040),
          child: Column(
            children: [
              Expanded(
                child: empty
                    ? ConversationHero(micBuilder: micBuilder)
                    : const ConversationTranscriptList(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: const ConversationLanguagePill(),
                  ),
                ),
              ),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: composerA),
                    Expanded(child: composerB),
                  ],
                )
              else ...[
                composerA,
                composerB,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Split screen: side B's half on top, upside down; controls in the middle;
/// side A's half at the bottom.
class _FaceToFaceLayout extends StatelessWidget {
  const new({required this.micBuilder, required this.share});

  final ConversationMicBuilder? micBuilder;
  final ConversationShareCallback share;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        key: const Key('conversation_face_to_face_layout'),
        children: [
          Expanded(
            child: ConversationPanel(
              side: ConversationSide.b,
              micBuilder: micBuilder,
            ),
          ),
          BlurBar(
            top: true,
            bottom: true,
            sigma: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const ConversationLayoutButton(),
                  const ConversationSwapButton(),
                  const ConversationAutoSpeakButton(),
                  ConversationMenuButton(share: share),
                ],
              ),
            ),
          ),
          Expanded(
            child: ConversationPanel(
              side: ConversationSide.a,
              micBuilder: micBuilder,
            ),
          ),
        ],
      ),
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
