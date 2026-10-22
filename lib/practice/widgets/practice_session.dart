import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/models/phrase.dart';
import 'package:mozhi/practice/cubit/practice_cubit.dart';
import 'package:mozhi/practice/cubit/practice_speech_cubit.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/models/practice_card.dart';
import 'package:mozhi/practice/models/practice_item.dart';
import 'package:mozhi/practice/widgets/answer_comparison.dart';
import 'package:mozhi/practice/widgets/rating_bar.dart';
import 'package:mozhi/practice/widgets/speaking_button.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';

/// A review session of the [PracticeCubit] above it: the current card's
/// front, "Show answer", then the answer with Listen and the four rating
/// buttons. Produce cards add the answer field (when typing answers is
/// on) and the microphone (speaking practice, [PracticeSpeechCubit], where
/// it runs).
///
/// Keys (unless typing in the answer field): Space or Enter shows the
/// answer, 1 to 4 rate it, Z or Ctrl+Z undoes the last rating.
class PracticeSession extends StatelessWidget {
  const new({super.key});

  /// Widest the card gets.
  static const double maxWidth = 640;

  static bool _typing() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  KeyEventResult _onKey(BuildContext context, KeyEvent event) {
    if (event is! KeyDownEvent || _typing()) return KeyEventResult.ignored;
    final cubit = context.read<PracticeCubit>();
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (cubit.state.revealed) return KeyEventResult.ignored;
      cubit.reveal();
      return KeyEventResult.handled;
    }
    final grade = switch (key) {
      LogicalKeyboardKey.digit1 || LogicalKeyboardKey.numpad1 => 1,
      LogicalKeyboardKey.digit2 || LogicalKeyboardKey.numpad2 => 2,
      LogicalKeyboardKey.digit3 || LogicalKeyboardKey.numpad3 => 3,
      LogicalKeyboardKey.digit4 || LogicalKeyboardKey.numpad4 => 4,
      _ => null,
    };
    if (grade != null) {
      if (!cubit.state.revealed) return KeyEventResult.ignored;
      unawaited(cubit.rate(FsrsRating.fromGrade(grade)!));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyZ || key == LogicalKeyboardKey.keyU) {
      if (!cubit.state.canUndo) return KeyEventResult.ignored;
      unawaited(cubit.undo());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final item = context.select<PracticeCubit, PracticeItem?>(
      (cubit) => cubit.state.current,
    );
    final left = context.select<PracticeCubit, int>(
      (cubit) => cubit.state.queue.length,
    );
    final revealed = context.select<PracticeCubit, bool>(
      (cubit) => cubit.state.revealed,
    );
    if (item == null) return const SizedBox.shrink();
    return MultiBlocListener(
      listeners: [
        // A new card (or the same one again): what was heard goes.
        BlocListener<PracticeCubit, PracticeState>(
          listenWhen: (previous, current) =>
              previous.current != current.current ||
              (previous.revealed && !current.revealed),
          listener: (context, state) =>
              unawaited(context.read<PracticeSpeechCubit>().reset()),
        ),
        // What was heard shows with the answer.
        BlocListener<PracticeSpeechCubit, PracticeSpeechState>(
          listenWhen: (previous, current) =>
              current.status == PracticeSpeechStatus.heard &&
              previous.status != PracticeSpeechStatus.heard,
          listener: (context, state) => context.read<PracticeCubit>().reveal(),
        ),
      ],
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) => _onKey(context, event),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  l10n.practiceCardsLeft(left),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: maxWidth),
                    child: PracticeCardView(
                      key: ValueKey('${item.id}/${item.card.reps}'),
                      item: item,
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: maxWidth),
                    child: revealed
                        ? const _Rating()
                        : SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              key: const Key('practice_show_answer'),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(0, 56),
                              ),
                              onPressed: context.read<PracticeCubit>().reveal,
                              child: Text(l10n.practiceShowAnswer),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Rating extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PracticeCubit>().state;
    final spoken = context.select<PracticeSpeechCubit, FsrsRating?>(
      (cubit) => cubit.state.check?.suggestedRating,
    );
    return RatingBar(
      intervals: state.intervals,
      suggested: state.typedCheck?.suggestedRating ?? spoken,
      onRate: (rating) => unawaited(context.read<PracticeCubit>().rate(rating)),
    );
  }
}

/// One card: its front and, once revealed, its answer (see
/// [PracticeSession]).
class PracticeCardView extends StatefulWidget {
  const new({required this.item, super.key});

  final PracticeItem item;

  @override
  State<PracticeCardView> createState() => _PracticeCardViewState();
}

class _PracticeCardViewState extends State<PracticeCardView> {
  final _answer = TextEditingController();

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  void _check() {
    final text = _answer.text.trim();
    if (text.isEmpty) return;
    context.read<PracticeCubit>().checkTypedAnswer(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final item = widget.item;
    final produce = item.direction == CardDirection.produce;
    final state = context.watch<PracticeCubit>().state;
    final speech = context.watch<PracticeSpeechCubit>();
    final speaking =
        produce &&
        speech.state.isOffered &&
        speech.state.status != PracticeSpeechStatus.modelMissing &&
        speech.supportsLanguage(item.foreignCode);
    final typing = produce && state.settings.typeAnswers;
    final revealed = state.revealed;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final big = MediaQuery.sizeOf(context).width >= 840;
    final textStyle =
        (big ? theme.textTheme.headlineLarge : theme.textTheme.headlineSmall)
            ?.copyWith(fontWeight: FontWeight.w700);
    final typedCheck = state.typedCheck;
    final spokenCheck = speech.state.check;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    produce
                        ? l10n.practiceProducePrompt
                        : l10n.practiceRecognizePrompt,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                if (item.card.isNew)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: Chip(
                      label: Text(l10n.practiceNewCard),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _Side(
              key: const Key('practice_front'),
              text: item.frontText,
              code: item.frontCode,
              style: textStyle,
              listenId: produce ? null : 'practice_front',
            ),
            if (typing && !revealed) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: TextField(
                  key: const Key('practice_answer'),
                  controller: _answer,
                  textDirection: textDirectionForCode(item.foreignCode),
                  textInputAction: TextInputAction.done,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: l10n.practiceAnswerField,
                    suffixIcon: IconButton(
                      tooltip: l10n.practiceCheckAnswer,
                      icon: const Icon(Icons.check),
                      onPressed: _check,
                    ),
                  ),
                  onSubmitted: (_) => _check(),
                ),
              ),
            ],
            if (speaking) ...[
              const SizedBox(height: 16),
              Center(
                child: SpeakingButton(
                  expected: item.foreignText,
                  languageCode: item.foreignCode,
                ),
              ),
            ],
            AnimatedSize(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              alignment: Alignment.topCenter,
              child: !revealed
                  ? const SizedBox(width: double.infinity)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                          padding: EdgeInsetsDirectional.only(
                            top: 16,
                            bottom: 16,
                            end: 8,
                          ),
                          child: Divider(height: 1),
                        ),
                        Semantics(
                          liveRegion: true,
                          child: _Side(
                            key: const Key('practice_back'),
                            text: item.backText,
                            code: item.backCode,
                            style: textStyle,
                            listenId: produce ? 'practice_back' : null,
                          ),
                        ),
                        if (item.pronunciation.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              item.pronunciation,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontStyle: FontStyle.italic,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (item.phrase.note.isNotEmpty)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(
                              top: 12,
                              end: 8,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.sticky_note_2_outlined,
                                  size: 18,
                                  color: colors.onSurfaceVariant,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    item.phrase.note,
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (typedCheck != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: AnswerComparison(
                              check: typedCheck,
                              heard: l10n.practiceTyped(typedCheck.answer),
                              languageCode: item.foreignCode,
                            ),
                          )
                        else if (spokenCheck != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: AnswerComparison(
                              check: spokenCheck,
                              heard: l10n.practiceHeard(spokenCheck.answer),
                              languageCode: item.foreignCode,
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One side of a card: [text] in the language [code], large, with Listen
/// ([listenId]; slow on a long press) when it is the foreign side.
class _Side extends StatelessWidget {
  const new({
    required this.text,
    required this.code,
    required this.style,
    this.listenId,
    super.key,
  });

  final String text;
  final String code;
  final TextStyle? style;
  final String? listenId;

  @override
  Widget build(BuildContext context) {
    final listenId = this.listenId;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: Text(
              text,
              style: style,
              locale: localeForCode(code),
              textDirection: textDirectionForCode(code),
            ),
          ),
        ),
        if (listenId != null)
          ListenButton(
            id: listenId,
            text: text,
            // An unknown language cannot be read aloud.
            languageCode: code == Phrase.unknownLanguage ? null : code,
          ),
      ],
    );
  }
}
