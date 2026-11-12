import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/data/leave_warning.dart';
import 'package:mozhi/conversation/models/conversation_mic.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/recognizer/speech_input_conversation_recognizer.dart';
import 'package:mozhi/conversation/share/cubit/conversation_share_cubit.dart';
import 'package:mozhi/conversation/share/widgets/conversation_share_banner.dart';
import 'package:mozhi/conversation/share/widgets/conversation_share_guard.dart';
import 'package:mozhi/conversation/widgets/widgets.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/android_device.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/conversation_preferences.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/speech/widgets/speech_error_snack_bar.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/engine_selector.dart';
import 'package:mozhi/translate/widgets/no_engines_view.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/widgets/voice_model_offer.dart';
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
///
/// With [networkShare] (the Android app) the conversation can also be
/// shared on the local network ([ConversationShareCubit], from the menu).
class ConversationPage extends StatelessWidget {
  const new({
    this.micBuilder,
    this.share = shareConversationText,
    this.recognizer = speechInputConversationRecognizer,
    this.networkShare,
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

  /// Whether the conversation can be shared on the local network
  /// (default: on Android, [runsOnAndroid]).
  final bool? networkShare;

  @override
  Widget build(BuildContext context) {
    // The device language is a fallback for side A (read here: providers
    // must not depend on inherited widgets in `create`).
    final deviceLanguageCode = Localizations.maybeLocaleOf(context)
        ?.languageCode;
    return BlocProvider(
      create: (context) {
        final translate = context.read<TranslateCubit>();
        final kept = _settingsOf(context)?.state.conversation;
        final defaults = ConversationCubit.defaultLanguages(
          translate.state,
          deviceLanguageCode: deviceLanguageCode,
        );
        // The pair chosen last time, else the defaults.
        final languages = switch (kept) {
          ConversationPreferences(languageA: final a?, languageB: final b?)
              when a != b =>
            (a: a, b: b),
          _ => defaults,
        };
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
          detectSpeaker: kept?.detectSpeaker ?? true,
          turnPause:
              kept?.turnPause ?? ConversationPreferences.defaultTurnPause,
        );
      },
      // While the app is locked the turns stay, hidden behind the lock
      // (AppLockGate: not drawn, not in the accessibility tree): leaving
      // the app must not end a conversation, shared ones included.
      child: _ConversationKeeper(
        child: (networkShare ?? runsOnAndroid)
            ? BlocProvider(
                create: (context) => ConversationShareCubit.withTranslate(
                  conversation: context.read<ConversationCubit>(),
                  translate: context.read<TranslateCubit>(),
                  repository: context.read<TranslationRepository>(),
                  usageTracker: _usageTracker(context),
                ),
                child: ConversationView(micBuilder: micBuilder, share: share),
              )
            : ConversationView(micBuilder: micBuilder, share: share),
      ),
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
/// pushed page); voice input failures are explained like on the translate
/// screen (the offline speech model is offered where it helps, else a
/// snack bar says why and what to do), and
/// new translations (unless they are read aloud anyway) and why a
/// hands-free conversation paused are announced to screen readers.
///
/// Face-to-face mode ([ConversationState.faceToFace]) is pushed as a
/// full-screen route ([ConversationFaceToFaceView]) on the root navigator,
/// above the tabs; leaving it (its toggle or back) pops it.
class ConversationView extends StatefulWidget {
  const new({this.micBuilder, this.share = shareConversationText, super.key});

  /// At and above this width the two composers sit side by side.
  static const double wideBreakpoint = 840;

  /// Below this width the app bar shows only the engine selector, and
  /// "Read translations aloud" moves into the overflow menu.
  static const double compactBreakpoint = 600;

  final ConversationMicBuilder? micBuilder;
  final ConversationShareCallback share;

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  /// The hands-free conversation's dock (the large microphone and its
  /// status): snack bars stay above it ([_SnackBarClearance]).
  final GlobalKey _controls = GlobalKey(debugLabel: 'conversationControls');

  @override
  Widget build(BuildContext context) {
    final micBuilder = widget.micBuilder;
    final share = widget.share;
    final l10n = context.l10n;
    final noEngines = _noEngines(context);
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < ConversationView.compactBreakpoint;
    final handsFree = context.select<ConversationCubit, bool>(
      (cubit) => cubit.state.handsFree,
    );
    // "Beta" once: the empty hands-free conversation's greeting shows it
    // ([ConversationHero]), so the title only does once there are turns.
    final heroShowsBeta = context.select<ConversationCubit, bool>(
      (cubit) => cubit.state.turns.isEmpty && micBuilder != null,
    );
    final title = [
      Text(l10n.conversationTitle),
      if (handsFree && !heroShowsBeta) ...[
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
              wide: width >= ConversationView.wideBreakpoint,
              controlsKey: _controls,
            ),
    );

    // Its own messenger: snack bars of the conversation are shown above its
    // controls, never over the microphone.
    return ScaffoldMessenger(
      child: _SnackBarClearance(
        controls: _controls,
        child: _listeners(scaffold),
      ),
    );
  }

  Widget _listeners(Widget scaffold) {
    final micBuilder = widget.micBuilder;
    final share = widget.share;
    return MultiBlocListener(
      listeners: [
        BlocListener<ConversationCubit, ConversationState>(
          // Every failure is kept in `lastSpeechFailure`.
          listenWhen: (previous, current) =>
              current.speechFailures > previous.speechFailures &&
              current.lastSpeechFailure != null,
          listener: (context, state) {
            // Face-to-face mode covers the page: its snack bars are the
            // app's.
            final shown = state.faceToFace
                ? Navigator.of(context, rootNavigator: true).context
                : context;
            ScaffoldMessenger.of(shown).hideCurrentSnackBar();
            final failure = state.lastSpeechFailure!;
            final cubit = context.read<ConversationCubit>();
            showSpeechErrorSnackBar(
              shown,
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
              // The servers failed: the same turn once more.
              onRetry: () =>
                  unawaited(cubit.speak(failure.turnId, slow: failure.slow)),
            );
          },
        ),
      ],
      child: _VoiceFailureHandler(
        child: _SessionGuard(
          child: _ConversationAnnouncer(
            child: _FaceToFacePresenter(
              micBuilder: micBuilder,
              share: share,
              child: ConversationShareGuard(child: scaffold),
            ),
          ),
        ),
      ),
    );
  }
}

/// Explains why the voice input of the hands-free conversation failed
/// ([ConversationSessionFailed]) the way the translate screen's microphone
/// (`VoiceInputButton`) does: where the offline speech model fixes it (a
/// phone without a speech recognition service, Whisper or Offline only
/// without a model) and Whisper runs here, it offers the download right
/// away ([offerVoiceModel]) and the conversation goes on listening once
/// the model is installed (not when the app is in the background
/// meanwhile); everything else, and a model that still does not work
/// after the offer, is explained once, by the status line above the
/// microphone (`ConversationSessionStatus`, with "Open settings" for a
/// denied microphone or "Download model"), not in a snack bar too, which
/// would cover the microphone.
class _VoiceFailureHandler extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_VoiceFailureHandler> createState() => _VoiceFailureHandlerState();
}

class _VoiceFailureHandlerState extends State<_VoiceFailureHandler> {
  /// The model offer is open (one at a time).
  bool _offering = false;

  /// The conversation goes on after the offer installed a model: should
  /// it fail again before it listens, that is explained, not offered
  /// again.
  bool _afterOffer = false;

  void _onSession(BuildContext context, ConversationState state) {
    final session = state.session;
    if (session is ConversationSessionFailed) {
      unawaited(_explain(session));
    } else if (session is! ConversationSessionListening ||
        session.stage != ConversationListenStage.starting) {
      // It listened (or ended): a later failure is offered again.
      _afterOffer = false;
    }
  }

  Future<void> _explain(ConversationSessionFailed failed) async {
    final afterOffer = _afterOffer;
    _afterOffer = false;
    final service = _speechInputOf(context);
    final offline = offlineSpeechOf(context);
    if (_offering ||
        afterOffer ||
        service == null ||
        offline == null ||
        !canOfferVoiceModel(
          failed.failure,
          service: service,
          offline: offline,
        )) {
      // The status line explains it.
      return;
    }
    final cubit = context.read<ConversationCubit>();
    _offering = true;
    final bool installed;
    try {
      installed = await offerVoiceModel(
        context,
        service: service,
        offline: offline,
        failure: failed.failure,
      );
    } finally {
      _offering = false;
    }
    if (!installed || !mounted || cubit.isClosed) return;
    // A download that finished while the app was in the background must
    // not open the microphone behind the user's back.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    // The user tapped the microphone to talk: now they can.
    switch (cubit.state.session) {
      case ConversationSessionFailed():
        _afterOffer = true;
        await cubit.toggleSession();
      case ConversationSessionIdle():
        _afterOffer = true;
        cubit.startSession(side: failed.next);
      case ConversationSessionListening() ||
          ConversationSessionTranslating() ||
          ConversationSessionSpeaking() ||
          ConversationSessionPaused():
        // Something else goes on already.
        break;
    }
  }

  @override
  Widget build(BuildContext context) =>
      BlocListener<ConversationCubit, ConversationState>(
        listenWhen: (previous, current) => previous.session != current.session,
        listener: _onSession,
        child: widget.child,
      );
}

/// The app-wide [SpeechInputService], or null without one (tests).
SpeechInputService? _speechInputOf(BuildContext context) {
  try {
    return context.read<SpeechInputService>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// Stops a running hands-free conversation when the app is hidden (another
/// app, screen off) or [child] is no longer shown (another tab, a page
/// pushed above it: its tickers are disabled), so the microphone is never
/// left open.
///
/// When [child] is shown (the tab opened, a page above it closed) it
/// closes the snack bar of the screen before: a floating snack bar sits
/// over the bottom of the page, where the large microphone is, and one
/// with an action does not go away on its own while accessibility
/// services run, so a tap on the microphone would land on it instead.
class _SessionGuard extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_SessionGuard> createState() => _SessionGuardState();
}

class _SessionGuardState extends State<_SessionGuard> {
  late final AppLifecycleListener _lifecycle;

  /// Whether the child was shown at the last check (null before the first).
  bool? _shown;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: _stop);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shown = TickerMode.valuesOf(context).enabled;
    if (!shown) _stop();
    if (shown && _shown != true) {
      // After the frame: the messenger cannot change while building.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // The app's messenger: the conversation has its own, whose snack
        // bars stay above the microphone.
        context
            .findRootAncestorStateOfType<ScaffoldMessengerState>()
            ?.hideCurrentSnackBar();
      });
    }
    _shown = shown;
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

/// Tells screen readers, politely and once ([StatusAnnouncer]):
/// * each new translation, "Spanish: Hola"; not while translations are
///   read aloud ([ConversationState.autoSpeak]), as the announcement would
///   talk over them. With a screen reader on, a hands-free conversation
///   keeps its microphone closed until the announcement was probably said
///   ([ConversationCubit.announced]), so it does not hear it;
/// * why a hands-free conversation paused and how to go on
///   ([conversationSessionStatus]), unless something of the conversation
///   is read aloud. A pause because a translation may only be read aloud
///   online is explained by its snack bar, which screen readers announce
///   already;
/// * why voice input failed (the status line above the microphone says it,
///   not a snack bar).
class _ConversationAnnouncer extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_ConversationAnnouncer> createState() => _ConversationAnnouncerState();
}

class _ConversationAnnouncerState extends State<_ConversationAnnouncer> {
  final Set<int> _announced = {};
  String? _message;

  /// What [_message] is about: `('turn', id)` or `('pause', count)`.
  Object? _announcementId;
  int _pauses = 0;

  void _say(Object id, String message) => setState(() {
    _announcementId = id;
    _message = message;
  });

  void _onTurns(BuildContext context, ConversationState state) {
    final completed = _newlyCompleted(state);
    if (completed == null || state.autoSpeak) return;
    final message = context.l10n.conversationTranslationAnnouncement(
      context.languageName(completed.target),
      completed.translation.trim(),
    );
    _say(('turn', completed.id), message);
    if (MediaQuery.accessibleNavigationOf(context)) {
      context.read<ConversationCubit>().announced(message);
    }
  }

  void _onPaused(BuildContext context, ConversationState state) {
    final session = state.session;
    if (session is! ConversationSessionPaused ||
        session.reason == ConversationPauseReason.speechConsent ||
        state.speakingTurnId != null) {
      return;
    }
    _say(('pause', ++_pauses), conversationSessionStatus(context.l10n, state));
  }

  void _onFailed(BuildContext context, ConversationState state) => _say((
    'pause',
    ++_pauses,
  ), conversationSessionStatus(context.l10n, state));

  @override
  Widget build(BuildContext context) => MultiBlocListener(
    listeners: [
      BlocListener<ConversationCubit, ConversationState>(
        listenWhen: (previous, current) => previous.turns != current.turns,
        listener: _onTurns,
      ),
      BlocListener<ConversationCubit, ConversationState>(
        listenWhen: (previous, current) =>
            current.session is ConversationSessionPaused &&
            previous.session != current.session,
        listener: _onPaused,
      ),
      BlocListener<ConversationCubit, ConversationState>(
        listenWhen: (previous, current) =>
            current.session is ConversationSessionFailed &&
            previous.session != current.session,
        listener: _onFailed,
      ),
    ],
    child: StatusAnnouncer(
      message: _message,
      announcementId: _announcementId,
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

  /// The face-to-face page opened through the router (until it closes).
  ConversationFaceToFaceLaunch? _launch;

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
    if (!mounted || _route != null || _launch != null) return;
    final cubit = context.read<ConversationCubit>();
    final shareCubit = maybeConversationShare(context);
    if (GoRouter.maybeOf(context) case final router?) {
      // A location of its own: back (the browser's too) closes it.
      late final ConversationFaceToFaceLaunch launch;
      launch = _launch = ConversationFaceToFaceLaunch(
        conversation: cubit,
        share: shareCubit,
        micBuilder: widget.micBuilder,
        shareText: widget.share,
        onRoute: (route) {
          if (identical(_launch, launch)) _route = route;
        },
        onClosed: () {
          if (!identical(_launch, launch)) return;
          _launch = null;
          _route = null;
          // Not while the navigator removes the page.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!cubit.isClosed && cubit.state.faceToFace) {
              cubit.setFaceToFace(enabled: false);
            }
          });
        },
      );
      unawaited(
        router.push<void>(AppRoutes.conversationFaceToFace, extra: launch),
      );
      return;
    }
    final route = _route = MaterialPageRoute<void>(
      builder: (_) {
        final view = BlocProvider<ConversationCubit>.value(
          value: cubit,
          child: ConversationFaceToFaceView(
            micBuilder: widget.micBuilder,
            share: widget.share,
          ),
        );
        return shareCubit == null
            ? view
            : BlocProvider<ConversationShareCubit>.value(
                value: shareCubit,
                child: view,
              );
      },
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
    _launch = null;
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

/// What the face-to-face page ([ConversationFaceToFacePage]) shows, as the
/// navigation's `extra` of [AppRoutes.conversationFaceToFace]: the
/// conversation's cubits and microphones, and whom to tell about the page.
class ConversationFaceToFaceLaunch {
  const new({
    required this.conversation,
    this.share,
    this.micBuilder,
    this.shareText = shareConversationText,
    this.onRoute,
    this.onClosed,
  });

  final ConversationCubit conversation;
  final ConversationShareCubit? share;
  final ConversationMicBuilder? micBuilder;
  final ConversationShareCallback shareText;

  /// Receives the page's route once it is shown.
  final ValueChanged<Route<dynamic>>? onRoute;

  /// Called when the page is gone (back, or face-to-face mode ended).
  final VoidCallback? onClosed;
}

/// Face-to-face mode at [AppRoutes.conversationFaceToFace]: the
/// [ConversationFaceToFaceView] of the launch's cubits. Leaving the page
/// (back) ends face-to-face mode (`ConversationLaunch.onClosed`).
class ConversationFaceToFacePage extends StatefulWidget {
  const new({required this.launch, super.key});

  /// The page for the navigation's [extra] (a
  /// [ConversationFaceToFaceLaunch]); an empty page for anything else (the
  /// router sends a link without one to the conversation).
  static Widget fromExtra(Object? extra) =>
      extra is ConversationFaceToFaceLaunch
      ? ConversationFaceToFacePage(launch: extra)
      : const Scaffold(body: SizedBox.shrink());

  final ConversationFaceToFaceLaunch launch;

  @override
  State<ConversationFaceToFacePage> createState() =>
      _ConversationFaceToFacePageState();
}

class _ConversationFaceToFacePageState
    extends State<ConversationFaceToFacePage> {
  bool _reported = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reported) return;
    if (ModalRoute.of(context) case final route?) {
      _reported = true;
      widget.launch.onRoute?.call(route);
    }
  }

  @override
  void dispose() {
    widget.launch.onClosed?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final launch = widget.launch;
    final view = BlocProvider<ConversationCubit>.value(
      value: launch.conversation,
      child: ConversationFaceToFaceView(
        micBuilder: launch.micBuilder,
        share: launch.shareText,
      ),
    );
    return switch (launch.share) {
      final share? => BlocProvider<ConversationShareCubit>.value(
        value: share,
        child: view,
      ),
      null => view,
    };
  }
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
    // Sharing on the local network goes on in face-to-face mode.
    return ConversationShareGuard(
      child: Scaffold(
        body: _FaceToFaceLayout(micBuilder: micBuilder, share: share),
      ),
    );
  }
}

/// Shared layout: the transcript (or, while empty, the hero), the
/// hands-free conversation's dock (status and large microphone), the
/// language pair, one composer per side.
///
/// With a hands-free conversation the composers hide behind the dock's
/// keyboard button on phones (side by side on wide screens they stay), and
/// their microphones while the conversation is active; while they are
/// shown on a phone, or with little height, the dock is a single row.
class _StandardLayout extends StatefulWidget {
  const new({
    required this.micBuilder,
    required this.wide,
    required this.controlsKey,
  });

  /// The key of the hands-free conversation's dock (its microphone), which
  /// snack bars stay above ([_SnackBarClearance]).
  final GlobalKey controlsKey;

  /// Below this height the dock is a single row.
  static const double compactDockHeight = 560;

  /// The largest share of the height the controls below the transcript
  /// take; beyond it they scroll.
  static const double maxControlsShare = 0.7;

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
            builder: (context, constraints) {
              final height = constraints.maxHeight;
              final controls = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (handsFree)
                    KeyedSubtree(
                      key: widget.controlsKey,
                      child: ConversationSessionDock(
                        composersShown: composersShown,
                        onToggleComposers: wide ? null : _toggleComposers,
                        // One row while typing on a phone or when short.
                        compact:
                            (composersShown && !wide) ||
                            height < _StandardLayout.compactDockHeight,
                      ),
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
                  if (composersShown && wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(child: composerA),
                        Expanded(child: composerB),
                      ],
                    )
                  else if (composersShown) ...[
                    composerA,
                    composerB,
                  ],
                ],
              );
              return Column(
                children: [
                  const ConversationShareBanner(),
                  Expanded(
                    child: empty
                        ? ConversationHero(micBuilder: micBuilder)
                        : const ConversationTranscriptList(),
                  ),
                  // The transcript keeps some room; with large text or an
                  // open keyboard the controls scroll instead.
                  SizeChangedLayoutNotifier(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: height * _StandardLayout.maxControlsShare,
                      ),
                      child: SingleChildScrollView(
                        reverse: true,
                        child: controls,
                      ),
                    ),
                  ),
                ],
              );
            },
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

/// Keeps the floating snack bars of the page's messenger above [controls]
/// (the hands-free conversation's dock with the large microphone, and all
/// below it): their bottom inset is raised by that height, measured after
/// each layout change. Without a dock, and with little room (a short
/// window, the keyboard open), they stay at the bottom, where they fit.
class _SnackBarClearance extends StatefulWidget {
  const new({required this.controls, required this.child});

  final GlobalKey controls;
  final Widget child;

  /// The most of the page's height the controls may take for snack bars
  /// to go above them.
  static const double maxShare = 0.6;

  @override
  State<_SnackBarClearance> createState() => _SnackBarClearanceState();
}

class _SnackBarClearanceState extends State<_SnackBarClearance> {
  double _clearance = 0;
  bool _scheduled = false;

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final clearance = _measure();
      if ((clearance - _clearance).abs() >= 1) {
        setState(() => _clearance = clearance);
      }
    });
  }

  double _measure() {
    final page = context.findRenderObject();
    final controls = widget.controls.currentContext?.findRenderObject();
    if (page is! RenderBox ||
        controls is! RenderBox ||
        !page.hasSize ||
        !controls.hasSize) {
      return 0;
    }
    final bottom = page.localToGlobal(Offset(0, page.size.height)).dy;
    final top = controls.localToGlobal(Offset.zero).dy;
    final clearance = bottom - top;
    if (clearance <= 0 ||
        clearance > page.size.height * _SnackBarClearance.maxShare) {
      return 0;
    }
    return clearance;
  }

  @override
  Widget build(BuildContext context) {
    // A new size or inset moves the controls.
    MediaQuery.sizeOf(context);
    MediaQuery.viewInsetsOf(context);
    _schedule();
    final theme = Theme.of(context);
    final inset =
        theme.snackBarTheme.insetPadding ??
        const EdgeInsets.fromLTRB(15, 5, 15, 10);
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _schedule();
        return false;
      },
      child: Theme(
        data: theme.copyWith(
          snackBarTheme: theme.snackBarTheme.copyWith(
            // Only floating snack bars can be lifted (the app's are).
            behavior: SnackBarBehavior.floating,
            insetPadding: inset.copyWith(bottom: inset.bottom + _clearance),
          ),
        ),
        child: widget.child,
      ),
    );
  }
}

/// Keeps what the [ConversationCubit] above it should not lose:
/// * its language pair and voice options ("Detect the speaker", the pause
///   that ends a turn) in the settings
///   ([SettingsCubit.setConversationPreferences], restored by
///   [ConversationPage]);
/// * its turns, which live in memory only: while there are any, the web
///   app asks before the page is reloaded or closed ([setLeaveWarning]).
class _ConversationKeeper extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_ConversationKeeper> createState() => _ConversationKeeperState();
}

class _ConversationKeeperState extends State<_ConversationKeeper> {
  bool _warning = false;

  @override
  void initState() {
    super.initState();
    _warn(context.read<ConversationCubit>().state.turns.isNotEmpty);
  }

  @override
  void dispose() {
    _warn(false);
    super.dispose();
  }

  void _warn(bool enabled) {
    if (enabled == _warning) return;
    _warning = enabled;
    setLeaveWarning(enabled: enabled);
  }

  void _keep(BuildContext context, ConversationState state) =>
      _settingsOf(context)?.setConversationPreferences(
        ConversationPreferences(
          languageA: state.languageA,
          languageB: state.languageB,
          detectSpeaker: state.detectSpeaker,
          turnPause: state.turnPause,
        ),
      );

  @override
  Widget build(BuildContext context) => MultiBlocListener(
    listeners: [
      BlocListener<ConversationCubit, ConversationState>(
        listenWhen: (previous, current) =>
            previous.languageA != current.languageA ||
            previous.languageB != current.languageB ||
            previous.detectSpeaker != current.detectSpeaker ||
            previous.turnPause != current.turnPause,
        listener: _keep,
      ),
      BlocListener<ConversationCubit, ConversationState>(
        listenWhen: (previous, current) =>
            previous.turns.isEmpty != current.turns.isEmpty,
        listener: (context, state) => _warn(state.turns.isNotEmpty),
      ),
    ],
    child: widget.child,
  );
}

/// The app-wide settings, or null without them (tests).
SettingsCubit? _settingsOf(BuildContext context) {
  try {
    return context.read<SettingsCubit>();
  } on ProviderNotFoundException {
    return null;
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
