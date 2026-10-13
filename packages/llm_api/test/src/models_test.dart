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
