import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Opens the hands-free conversation's voice options
/// ([ConversationVoiceOptions]) for the [ConversationCubit] above
/// [context], in a bottom sheet.
Future<void> showConversationVoiceOptions(BuildContext context) {
  final cubit = context.read<ConversationCubit>();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => BlocProvider.value(
      value: cubit,
      child: const ConversationVoiceOptions(),
    ),
  );
}

/// "Detect the speaker" and the pause that ends a turn (0.5 to 2 s, in
/// steps of 0.1 s), for the [ConversationCubit] above it. Both matter with
/// offline speech (Whisper), which the texts say.
class ConversationVoiceOptions extends StatelessWidget {
  const new({super.key});

  /// Slider steps between the shortest and the longest pause (0.1 s each).
  static final int _steps =
      (ConversationState.maxTurnPause - ConversationState.minTurnPause)
          .inMilliseconds ~/
      100;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<ConversationCubit>();
    final (:detectSpeaker, :turnPause) = context
        .select<ConversationCubit, ({bool detectSpeaker, Duration turnPause})>(
          (cubit) => (
            detectSpeaker: cubit.state.detectSpeaker,
            turnPause: cubit.state.turnPause,
          ),
        );
    final locale = Localizations.localeOf(context).toLanguageTag();
    final format = NumberFormat.decimalPatternDigits(
      locale: locale,
      decimalDigits: 1,
    );
    String seconds(double value) =>
        l10n.conversationTurnPauseValue(format.format(value));
    final value = turnPause.inMilliseconds / 1000;
    return SingleChildScrollView(
      key: const Key('conversation_voice_options'),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l10n.conversationVoiceOptions,
              style: theme.textTheme.titleLarge,
            ),
          ),
          SwitchListTile(
            key: const Key('conversation_detect_speaker'),
            title: Text(l10n.conversationDetectSpeaker),
            subtitle: Text(l10n.conversationDetectSpeakerHint),
            value: detectSpeaker,
            onChanged: (enabled) => cubit.setDetectSpeaker(enabled: enabled),
          ),
          ListTile(
            title: Text(l10n.conversationTurnPause),
            subtitle: Text(l10n.conversationTurnPauseHintAny),
            trailing: Text(
              seconds(value),
              key: const Key('conversation_turn_pause_value'),
              style: theme.textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Slider(
              key: const Key('conversation_turn_pause'),
              value: value,
              min: ConversationState.minTurnPause.inMilliseconds / 1000,
              max: ConversationState.maxTurnPause.inMilliseconds / 1000,
              divisions: _steps,
              label: seconds(value),
              semanticFormatterCallback: seconds,
              onChanged: (seconds) => cubit.setTurnPause(
                Duration(milliseconds: (seconds * 1000).round()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
