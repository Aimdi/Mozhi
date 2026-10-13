import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

void main() {
  group(LlmMessage, () {
    test('named constructors set the role', () {
      expect(const LlmMessage.system('s').role, LlmRole.system);
      expect(const LlmMessage.user('u').role, LlmRole.user);
      expect(const LlmMessage.assistant('a').role, LlmRole.assistant);
      expect(const LlmMessage.assistant('a').images, isEmpty);
    });

    test('compares by role and content', () {
      expect(
        const LlmMessage(LlmRole.user, 'x'),
        const LlmMessage.user(
          'x',
          images: [
            LlmImage(bytes: [1]),
          ],
        ),
      );
      expect(
        const LlmMessage.user('x').hashCode,
        const LlmMessage(LlmRole.user, 'x').hashCode,
      );
      expect(const LlmMessage.user('x'), isNot(const LlmMessage.system('x')));
    });
  });

  group(LlmRequest, () {
    const request = LlmRequest(
      model: 'm',
      messages: [LlmMessage.user('Hi')],
      contextWindow: 4096,
    );

    test('contextWindow defaults to null', () {
      expect(const LlmRequest(model: 'm', messages: []).contextWindow, isNull);
    });

    test('copyWith keeps or replaces contextWindow', () {
      expect(request.copyWith(model: 'n').contextWindow, 4096);
      expect(request.copyWith(model: 'n').model, 'n');
      expect(request.copyWith(contextWindow: 16384).contextWindow, 16384);
    });
  });

  group(LlmModel, () {
    test('label prefers a non-empty display name', () {
      expect(const LlmModel(id: 'a', displayName: 'Alpha').label, 'Alpha');
      expect(const LlmModel(id: 'a', displayName: '').label, 'a');
      expect(const LlmModel(id: 'a').label, 'a');
    });

    test('compares by id', () {
      expect(
        const LlmModel(id: 'a', displayName: 'x'),
        const LlmModel(id: 'a', contextWindow: 1),
      );
      expect(
        const LlmModel(id: 'a').hashCode,
        const LlmModel(id: 'a', displayName: 'x').hashCode,
      );
      expect(const LlmModel(id: 'a'), isNot(const LlmModel(id: 'b')));
    });
  });
}
