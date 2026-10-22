import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/widgets/conversation_turn_bubble.dart';

import '../../helpers/helpers.dart';
import '../helpers.dart';

void main() {
  testWidgets('names the guest who wrote a turn', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpApp(
      Scaffold(
        body: ConversationTurnBubble(
          turn: ConversationTurn(
            id: 0,
            side: ConversationSide.b,
            original: 'Bonjour',
            source: french,
            target: english,
            translation: 'Hello',
            createdAt: sentAt,
            status: ConversationTurnStatus.complete,
            engineName: 'DeepL',
            guest: 2,
          ),
        ),
      ),
    );

    expect(find.textContaining('Guest 2 · '), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^Guest 2, French: Bonjour\.')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('names nobody for turns said on this device', (tester) async {
    await tester.pumpApp(
      Scaffold(body: ConversationTurnBubble(turn: turnOf())),
    );

    expect(find.textContaining('Guest'), findsNothing);
  });
}
