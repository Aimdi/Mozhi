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

    test('sampling options default to the provider defaults', () {
      expect(request.topP, isNull);
      expect(request.topK, isNull);
      expect(request.repeatPenalty, isNull);
      expect(request.stop, isEmpty);
    });

    test('copyWith keeps or replaces the sampling options', () {
      final sampled = request.copyWith(
        topP: 0.6,
        topK: 20,
        repeatPenalty: 1.05,
        stop: ['END'],
      );
      expect(sampled.topP, 0.6);
      expect(sampled.topK, 20);
      expect(sampled.repeatPenalty, 1.05);
      expect(sampled.stop, ['END']);
      final kept = sampled.copyWith(model: 'n');
      expect(kept.topP, 0.6);
      expect(kept.topK, 20);
      expect(kept.repeatPenalty, 1.05);
      expect(kept.stop, ['END']);
    });

    test('compares by every field', () {
      const full = LlmRequest(
        model: 'm',
        messages: [LlmMessage.system('s'), LlmMessage.user('Hi')],
        temperature: 0.7,
        maxTokens: 10,
        jsonOutput: true,
        effort: 'low',
        contextWindow: 4096,
        topP: 0.6,
        topK: 20,
        repeatPenalty: 1.05,
        stop: ['a', 'b'],
      );
      final copy = full.copyWith(
        messages: [const LlmMessage.system('s'), const LlmMessage.user('Hi')],
        stop: ['a', 'b'],
      );
      expect(copy, full);
      expect(copy.hashCode, full.hashCode);
      expect(full, isNot(request));
      for (final other in [
        full.copyWith(model: 'n'),
        full.copyWith(messages: [const LlmMessage.user('Hi')]),
        full.copyWith(
          messages: [const LlmMessage.system('s'), const LlmMessage.user('Ho')],
        ),
        full.copyWith(temperature: 0.1),
        full.copyWith(maxTokens: 11),
        full.copyWith(jsonOutput: false),
        full.copyWith(effort: 'high'),
        full.copyWith(contextWindow: 8192),
        full.copyWith(topP: 0.9),
        full.copyWith(topK: 40),
        full.copyWith(repeatPenalty: 1.1),
        full.copyWith(stop: ['a']),
        full.copyWith(stop: ['a', 'c']),
      ]) {
        expect(other, isNot(full));
      }
      expect(full, isNot('m'));
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
