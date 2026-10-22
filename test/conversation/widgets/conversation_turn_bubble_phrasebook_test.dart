import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/widgets/conversation_turn_bubble.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';

import '../../phrasebook/pump.dart';
import '../helpers.dart';

class _MockConversationCubit extends MockCubit<ConversationState>
    implements ConversationCubit;

void main() {
  late _MockConversationCubit cubit;

  setUp(() => cubit = _MockConversationCubit());

  Future<void> pump(
    WidgetTester tester,
    ConversationTurn turn, {
    PhrasebookRepository? repository,
  }) => tester.pumpPhrasebook(
    BlocProvider<ConversationCubit>.value(
      value: cubit,
      child: Scaffold(body: ConversationTurnBubble(turn: turn)),
    ),
    repository: repository,
  );

  Future<void> openMore(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('conversation_more_0')));
    // A translating turn's progress never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('adds a translated message to a phrasebook', (tester) async {
    final repository = createPhrasebook();
    final collection = await repository.createCollection('Trip');
    await pump(tester, turnOf(), repository: repository);
    await openMore(tester);

    await tester.tap(find.text('Add to phrasebook…'));
    await tester.pumpAndSettle();
    expect(find.text('Add to phrasebook'), findsOneWidget);
    await tester.tap(find.text('Trip'));
    await tester.pumpAndSettle();

    expect(find.text('Added to Trip'), findsOneWidget);
    final phrases = await repository.phrases(collectionId: collection.id);
    final phrase = phrases.single;
    expect(phrase.text, 'Hello');
    expect(phrase.translation, 'Hola');
    expect(phrase.sourceCode, 'en');
    expect(phrase.targetCode, 'es');
    expect(phrase.origin, PhraseOrigin.history);
  });

  testWidgets('is not offered without a phrasebook', (tester) async {
    await pump(tester, turnOf());
    await openMore(tester);
    expect(find.text('Copy translation'), findsOneWidget);
    expect(find.text('Add to phrasebook…'), findsNothing);
  });

  testWidgets('is not offered while translating or after a failure', (
    tester,
  ) async {
    final repository = createPhrasebook();
    await pump(
      tester,
      turnOf(status: ConversationTurnStatus.translating, translation: 'Ho'),
      repository: repository,
    );
    await openMore(tester);
    expect(find.text('Copy original'), findsOneWidget);
    expect(find.text('Add to phrasebook…'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 500));

    await pump(
      tester,
      turnOf(status: ConversationTurnStatus.failed, translation: ''),
      repository: repository,
    );
    await openMore(tester);
    expect(find.text('Add to phrasebook…'), findsNothing);
  });
}
