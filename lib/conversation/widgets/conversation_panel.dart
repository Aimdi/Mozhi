import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/models/conversation_mic.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/widgets/conversation_composer.dart';
import 'package:mozhi/conversation/widgets/conversation_language_button.dart';
import 'package:mozhi/conversation/widgets/conversation_orientation.dart';
import 'package:mozhi/conversation/widgets/conversation_transcript_list.dart';

/// One person's half of the face-to-face layout: their language, the
/// transcript from their point of view and their composer (at the edge of
/// the screen nearest to them).
///
/// Side B's panel is turned by 180° so it reads the right way up for the
/// person across the table; dialogs opened from it are turned as well.
class ConversationPanel extends StatelessWidget {
  const ConversationPanel({required this.side, this.micBuilder, super.key});

  final ConversationSide side;
  final ConversationMicBuilder? micBuilder;

  bool get upsideDown => side == ConversationSide.b;

  @override
  Widget build(BuildContext context) {
    final panel = Column(
      key: Key('conversation_panel_${side.name}'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: ConversationLanguageButton(side: side),
        ),
        Expanded(child: ConversationTranscriptList(viewer: side)),
        ConversationComposer(side: side, micBuilder: micBuilder),
      ],
    );
    return ConversationOrientation(
      upsideDown: upsideDown,
      child: upsideDown
          ? RotatedBox(
              key: const Key('conversation_rotated_half'),
              quarterTurns: 2,
              child: panel,
            )
          : panel,
    );
  }
}
