import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_mic.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/recognizer/speech_input_conversation_recognizer.dart';
import 'package:mozhi/conversation/widgets/widgets.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/speech/widgets/speech_error_snack_bar.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/engine_selector.dart';
import 'package:mozhi/translate/widgets/no_engines_view.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/voice/widgets/voice_error_message.dart';
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
///
/// With voice input ([micBuilder]) and a recogniser from [recognizer]
/// (default: the app-wide `SpeechInputService`), the large microphone runs
/// a hands-free conversation ([ConversationCubit.toggleSession]).
class ConversationPage extends StatelessWidget {
  const new({
    this.micBuilder,
    this.share = shareConversationText,
    this.recognizer = speechInputConversationRecognizer,
    super.key,
  });

  /// Builds each side's microphone button; null hides voice input (the
  /// hands-free conversation too).
  final ConversationMicBuilder? micBuilder;

  /// Shares the transcript (defaults to the platform share sheet).
  final ConversationShareCallback share;

  /// Creates the hands-free conversation's recogniser (owned by the
  /// cubit); null from it means no hands-free conversation.
  final ConversationRecognizerBuilder recognizer;

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
          recognizer: micBuilder == null ? null : recognizer(context),
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
/// With a hands-free conversation ([ConversationState.handsFree]) the
/// large microphone and its status are docked above the language pair
/// ([ConversationSessionDock]); on phones the composers then hide behind
/// its keyboard button. A conversation that is running stops when the
/// app goes to the background or the page is covered (another tab, a
/// pushed page); voice input failures are explained in a snack bar, and
/// new translations are announced to screen readers (unless they are read
/// aloud anyway).
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
    final handsFree = context.select<ConversationCubit, bool>(
      (cubit) => cubit.state.handsFree,
    );
    final title = [
      Text(l10n.conversationTitle),
      if (handsFree) ...[
        const SizedBox(width: 8),
        const ConversationBetaBadge(),
      ],
    ];

    final scaffold = Scaffold(
      appBar: AppBar(
        titleSpacing: noEngines || !compact ? null : 8,
        title: noEngines
            ? Text(l10n.conversationTitle)
            : !compact
            ? Row(
                children: [
                  ...title,
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
                ConversationMenuButton(share: share, showAutoSpeak: compact),
                const SizedBox(width: 4),
              ],
      ),
      body: noEngines
          ? const NoEnginesView()
          : _StandardLayout(
              micBuilder: micBuilder,
              wide: width >= wideBreakpoint,
            ),
    );

    return MultiBlocListener(
      listeners: [
        BlocListener<ConversationCubit, ConversationState>(
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
        ),
        BlocListener<ConversationCubit, ConversationState>(
          // Voice input of the hands-free conversation failed.
          listenWhen: (previous, current) =>
              current.session is ConversationSessionFailed &&
              previous.session != current.session,
          listener: (context, state) {
            final failed = state.session as ConversationSessionFailed;
            showVoiceInputErrorSnackBar(
              context,
              failed.failure,
              onDevice: failed.onDevice,
              offlineSupported: failed.offlineSupported,
            );
          },
        ),
      ],
      child: _SessionGuard(
        child: _TranslationAnnouncer(
          child: _FaceToFacePresenter(
            micBuilder: micBuilder,
            share: share,
            child: scaffold,
          ),
        ),
      ),
    );
  }
}

/// Stops a running hands-free conversation when the app is hidden (another
/// app, screen off) or [child] is no longer shown (another tab, a page
/// pushed above it: its tickers are disabled), so the microphone is never
/// left open.
class _SessionGuard extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_SessionGuard> createState() => _SessionGuardState();
}

class _SessionGuardState extends State<_SessionGuard> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: _stop);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TickerMode.valuesOf(context).enabled) _stop();
  }

  void _stop() {
    if (!mounted) return;
    final cubit = context.read<ConversationCubit>();
    if (cubit.state.session.isActive) unawaited(cubit.stopSession());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Announces each new translation to screen readers, politely and once
/// ([StatusAnnouncer]): "Spanish: Hola". Not while translations are read
/// aloud ([ConversationState.autoSpeak]): the announcement would talk over
/// them (and a hands-free conversation's microphone could hear it).
class _TranslationAnnouncer extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_TranslationAnnouncer> createState() => _TranslationAnnouncerState();
}

class _TranslationAnnouncerState extends State<_TranslationAnnouncer> {
  final Set<int> _announced = {};
  String? _message;
  int? _turnId;

  @override
  Widget build(BuildContext context) =>
      BlocListener<ConversationCubit, ConversationState>(
        listenWhen: (previous, current) => previous.turns != current.turns,
        listener: (context, state) {
          final completed = _newlyCompleted(state);
          if (completed == null || state.autoSpeak) return;
          setState(() {
            _turnId = completed.id;
            _message = context.l10n.conversationTranslationAnnouncement(
              completed.target.name,
              completed.translation.trim(),
            );
          });
        },
        child: StatusAnnouncer(
          message: _message,
          announcementId: _turnId,
          child: widget.child,
        ),
      );

  /// The newest turn that completed since the last check, if any.
  ConversationTurn? _newlyCompleted(ConversationState state) {
    for (final turn in state.turns.reversed) {
      if (!turn.isComplete || turn.translation.trim().isEmpty) continue;
      if (_announced.contains(turn.id)) return null;
      _announced.add(turn.id);
      return turn;
    }
    return null;
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

/// Shared layout: the transcript (or, while empty, the hero), the
/// hands-free conversation's dock (status and large microphone), the
/// language pair, one composer per side.
///
/// With a hands-free conversation the composers hide behind the dock's
/// keyboard button on phones (side by side on wide screens they stay), and
/// their microphones while the conversation is active; with little height
/// (an open keyboard) the dock is a single row.
class _StandardLayout extends StatefulWidget {
  const new({required this.micBuilder, required this.wide});

  /// Below this height the dock is a single row.
  static const double compactDockHeight = 560;

  final ConversationMicBuilder? micBuilder;
  final bool wide;

  @override
  State<_StandardLayout> createState() => _StandardLayoutState();
}

class _StandardLayoutState extends State<_StandardLayout> {
  /// The user showed the composers (hands-free, phones).
  bool _composers = false;

  void _toggleComposers() => setState(() => _composers = !_composers);

  @override
  Widget build(BuildContext context) {
    final micBuilder = widget.micBuilder;
    final wide = widget.wide;
    final (:empty, :handsFree, :active) = context
        .select<ConversationCubit, ({bool empty, bool handsFree, bool active})>(
          (cubit) {
            final state = cubit.state;
            return (
              empty: state.turns.isEmpty,
              handsFree: state.handsFree && micBuilder != null,
              active: state.session.isActive,
            );
          },
        );
    final composersShown = !handsFree || wide || _composers;
    // The large microphone is the voice input of an active conversation.
    final composerMic = active ? null : micBuilder;
    final composerA = ConversationComposer(
      side: ConversationSide.a,
      micBuilder: composerMic,
    );
    final composerB = ConversationComposer(
      side: ConversationSide.b,
      micBuilder: composerMic,
    );
    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          key: const Key('conversation_standard_layout'),
          constraints: const BoxConstraints(maxWidth: 1040),
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              children: [
                Expanded(
                  child: empty
                      ? ConversationHero(micBuilder: micBuilder)
                      : const ConversationTranscriptList(),
                ),
                if (handsFree)
                  ConversationSessionDock(
                    composersShown: composersShown,
                    onToggleComposers: wide ? null : _toggleComposers,
                    compact:
                        constraints.maxHeight <
                        _StandardLayout.compactDockHeight,
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
                if (!composersShown)
                  const SizedBox.shrink()
                else if (wide)
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
