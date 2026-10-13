import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/conversation/conversation.dart';

import '../helpers.dart';

void main() {
  group(ConversationSide, () {
    test('other is the opposite side', () {
      expect(ConversationSide.a.other, ConversationSide.b);
      expect(ConversationSide.b.other, ConversationSide.a);
    });
  });

  group(ConversationTurn, () {
    test('status getters', () {
      expect(
        turnOf(status: ConversationTurnStatus.translating).isTranslating,
        isTrue,
      );
      expect(turnOf().isComplete, isTrue);
      expect(turnOf(status: ConversationTurnStatus.failed).isFailed, isTrue);
    });

    test('copyWith replaces the given fields only', () {
      final turn = turnOf(status: ConversationTurnStatus.translating);
      final error = StateError('x');
      final changed = turn.copyWith(
        translation: 'Buenas',
        engineId: () => 'ai:claude',
        engineName: () => 'Claude',
        status: ConversationTurnStatus.failed,
        error: () => error,
      );
      expect(changed.translation, 'Buenas');
      expect(changed.engineId, 'ai:claude');
      expect(changed.engineName, 'Claude');
      expect(changed.status, ConversationTurnStatus.failed);
      expect(changed.error, error);
      expect(changed.original, turn.original);
      expect(changed.createdAt, turn.createdAt);
      expect(turn.copyWith(), turn);
      expect(
        changed.copyWith(engineName: () => null, error: () => null).engineName,
        isNull,
      );
    });

    test('supports value equality', () {
      expect(turnOf(), turnOf());
      expect(turnOf(), isNot(turnOf(translation: 'Buenas')));
    });
  });

  group(ConversationMicRequest, () {
    test('owner is the side', () {
      final request = ConversationMicRequest(
        side: ConversationSide.b,
        language: spanish,
        onResult: (_, {required isFinal}) {},
      );
      expect(request.owner, same(ConversationSide.b));
    });
  });

  group(ConversationTranscript, () {
    test('formats a title and one block per turn', () {
      final text = ConversationTranscript.format(
        [
          turnOf(),
          turnOf(
            id: 1,
            side: ConversationSide.b,
            original: ' Muy bien ',
            translation: 'Very well',
          ),
        ],
        title: 'Conversation: English ↔ Spanish',
        formatTime: (time) => '${time.hour}:${time.minute}',
      );
      expect(
        text,
        'Conversation: English ↔ Spanish\n\n'
        '[14:5] English: Hello\n'
        '→ Spanish: Hola\n\n'
        '[14:5] Spanish: Muy bien\n'
        '→ English: Very well',
      );
    });

    test('leaves out empty translations, blank titles and times', () {
      final text = ConversationTranscript.format([
        turnOf(translation: '', status: ConversationTurnStatus.failed),
      ], title: '  ');
      expect(text, 'English: Hello');
    });

    test('is empty without turns', () {
      expect(ConversationTranscript.format(const []), isEmpty);
    });
  });

  group(ConversationState, () {
    test('languageOf, turnById, isEmpty and isTranslating', () {
      final translating = turnOf(
        id: 1,
        status: ConversationTurnStatus.translating,
      );
      final state = ConversationState(
        languageA: english,
        languageB: spanish,
        turns: [turnOf(), translating],
      );
      expect(state.languageOf(ConversationSide.a), english);
      expect(state.languageOf(ConversationSide.b), spanish);
      expect(state.turnById(1), translating);
      expect(state.turnById(7), isNull);
      expect(state.isEmpty, isFalse);
      expect(state.isTranslating, isTrue);
      expect(
        const ConversationState(languageA: english, languageB: spanish).isEmpty,
        isTrue,
      );
    });

    test('copyWith', () {
      const state = ConversationState(languageA: english, languageB: spanish);
      final changed = state.copyWith(
        languageA: french,
        languageB: german,
        turns: [turnOf()],
        autoSpeak: true,
        faceToFace: true,
        speakingTurnId: () => 0,
        speechFailures: 2,
      );
      expect(
        changed,
        ConversationState(
          languageA: french,
          languageB: german,
          turns: [turnOf()],
          autoSpeak: true,
          faceToFace: true,
          speakingTurnId: 0,
          speechFailures: 2,
        ),
      );
      expect(changed.copyWith(), changed);
      expect(changed.copyWith(speakingTurnId: () => null).speakingTurnId, null);
    });
  });
}
