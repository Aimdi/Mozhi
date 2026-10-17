import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
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
/// [UsageTracker] above it (optional) counts AI requests. Best pushed as
/// a full-screen route (outside the tab shell) so face-to-face mode gets
/// the whole screen.
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

/// Builds the standard or the face-to-face layout of the
/// [ConversationCubit] above it.
class ConversationView extends StatelessWidget {
  const new({this.micBuilder, this.share = shareConversationText, super.key});

  /// At and above this width the two composers sit side by side.
  static const double wideBreakpoint = 840;

  /// Below this width the app bar shows only the engine selector.
  static const double compactBreakpoint = 600;

  final ConversationMicBuilder? micBuilder;
  final ConversationShareCallback share;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final faceToFace = context.select<ConversationCubit, bool>(
      (cubit) => cubit.state.faceToFace,
    );
    final noEngines = context.select<TranslateCubit, bool>((cubit) {
      final state = cubit.state;
      return state.engines.isEmpty &&
          (state.enginesStatus == EnginesStatus.ready ||
              state.enginesStatus == EnginesStatus.failure);
    });
    final width = MediaQuery.sizeOf(context).width;

    final Widget body;
    if (noEngines) {
      body = const NoEnginesView();
    } else if (faceToFace) {
      body = _FaceToFaceLayout(micBuilder: micBuilder, share: share);
    } else {
      body = _StandardLayout(
        micBuilder: micBuilder,
        wide: width >= wideBreakpoint,
      );
    }

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
      child: Scaffold(
        appBar: faceToFace && !noEngines
            ? null
            : AppBar(
                titleSpacing: width >= compactBreakpoint ? null : 0,
                title: noEngines
                    ? Text(l10n.conversationTitle)
                    : width >= compactBreakpoint
                    ? Row(
                        children: [
                          Text(l10n.conversationTitle),
                          const SizedBox(width: 16),
                          const Flexible(child: EngineSelectorButton()),
                        ],
                      )
                    : const EngineSelectorButton(),
                actions: noEngines
                    ? null
                    : [
                        const ConversationLayoutButton(),
                        const ConversationAutoSpeakButton(),
                        ConversationMenuButton(share: share),
                        const SizedBox(width: 4),
                      ],
              ),
        body: body,
      ),
    );
  }
}

/// Shared layout: languages on top, transcript, one composer per side.
class _StandardLayout extends StatelessWidget {
  const new({required this.micBuilder, required this.wide});

  final ConversationMicBuilder? micBuilder;
  final bool wide;

  @override
  Widget build(BuildContext context) {
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
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: ConversationLanguageButton(
                        side: ConversationSide.a,
                      ),
                    ),
                    ConversationSwapButton(),
                    Expanded(
                      child: ConversationLanguageButton(
                        side: ConversationSide.b,
                      ),
                    ),
                  ],
                ),
              ),
              const Hairline(),
              const Expanded(child: ConversationTranscriptList()),
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
