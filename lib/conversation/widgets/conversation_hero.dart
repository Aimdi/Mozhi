import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_mic.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/widgets/conversation_session_dock.dart';
import 'package:mozhi/core/widgets/tab_hero.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// The empty conversation: "Let's talk!".
///
/// With a hands-free conversation ([ConversationState.handsFree]) it is a
/// "Beta" badge above the title: the microphone and how to start sit in
/// the dock below ([ConversationSessionDock]). Otherwise it adds how to
/// start and a large microphone ([ConversationMicRequest.prominent]) that
/// dictates in side A's language (the first of the pair) and sends what
/// was said, like side A's composer; what is being said replaces the hint
/// until it is sent. Without a [micBuilder] (no voice input) it explains
/// how to type instead.
class ConversationHero extends StatefulWidget {
  const new({this.micBuilder, super.key});

  /// Builds the large microphone; null leaves it out.
  final ConversationMicBuilder? micBuilder;

  /// The side the large microphone dictates for.
  static const ConversationSide side = ConversationSide.a;

  @override
  State<ConversationHero> createState() => _ConversationHeroState();
}

class _ConversationHeroState extends State<ConversationHero> {
  /// The utterance so far while dictating.
  String _heard = '';

  void _onResult(String text, {required bool isFinal}) {
    if (!mounted) return;
    setState(() => _heard = isFinal ? '' : text);
    if (!isFinal || text.trim().isEmpty) return;
    // Nothing to send it with yet (engines still loading).
    if (context.read<TranslateCubit>().state.engine == null) return;
    unawaited(
      context.read<ConversationCubit>().submit(ConversationHero.side, text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final micBuilder = widget.micBuilder;
    final language = context.select<ConversationCubit, Language>(
      (cubit) => cubit.state.languageOf(ConversationHero.side),
    );
    final handsFree = context.select<ConversationCubit, bool>(
      (cubit) => cubit.state.handsFree,
    );
    final Widget hero;
    if (handsFree && micBuilder != null) {
      hero = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ConversationBetaBadge(),
          const SizedBox(height: 16),
          TabHero(icon: Icons.forum_rounded, title: l10n.conversationHeroTitle),
        ],
      );
    } else if (micBuilder == null) {
      hero = TabHero(
        icon: Icons.forum_rounded,
        title: l10n.conversationHeroTitle,
        body: l10n.conversationEmptyBody,
      );
    } else {
      final heard = _heard.trim();
      hero = TabHero(
        icon: Icons.forum_rounded,
        title: l10n.conversationHeroTitle,
        body: heard.isEmpty ? l10n.conversationHeroHint : heard,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            micBuilder(
              context,
              ConversationMicRequest(
                side: ConversationHero.side,
                language: language,
                onResult: _onResult,
                prominent: true,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.conversationHeroMicLanguage(language.name),
              textAlign: TextAlign.center,
              style: theme.textTheme.labelLarge?.copyWith(
                color: AppPalette.of(context).secondaryText,
              ),
            ),
          ],
        ),
      );
    }
    return Center(
      key: const Key('conversation_hero'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: hero,
        ),
      ),
    );
  }
}
