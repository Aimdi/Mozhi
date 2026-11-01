import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/quick_improve/quick_improve.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  group('ImproveEngines', () {
    test('keeps only the engines that can proofread', () {
      expect(proofreadEngines([google, claude, hyMt, ollama]), [
        claude,
        ollama,
      ]);
    });

    test('prefers the assist engine, else the first engine', () {
      expect(pickProofreadEngine([claude, ollama], preferred: ollama), ollama);
      expect(pickProofreadEngine([claude, ollama]), claude);
      // An assist engine that cannot proofread is not used.
      expect(pickProofreadEngine([claude], preferred: hyMt), claude);
      expect(pickProofreadEngine(const [], preferred: claude), isNull);
    });

    test('reads the engines of the translate screen', () {
      final engines = ImproveEngines.fromTranslateState(
        const TranslateState(
          enginesStatus: EnginesStatus.ready,
          engines: [google, claude, hyMt, ollama],
          assistEngine: ollama,
        ),
      );

      expect(engines.engines, [claude, ollama]);
      expect(engines.preferred, ollama);
      expect(engines.engine, ollama);
      expect(engines.status, ImproveEnginesStatus.ready);
    });

    test('maps the status of the engine list', () {
      ImproveEnginesStatus statusOf(EnginesStatus status) =>
          ImproveEngines.fromTranslateState(
            TranslateState(enginesStatus: status),
          ).status;

      expect(statusOf(EnginesStatus.initial), ImproveEnginesStatus.loading);
      expect(statusOf(EnginesStatus.loading), ImproveEnginesStatus.loading);
      expect(statusOf(EnginesStatus.ready), ImproveEnginesStatus.ready);
      expect(statusOf(EnginesStatus.failure), ImproveEnginesStatus.failure);
    });

    test('compares every engine detail', () {
      // Same id and name, another model.
      const edited = TranslationEngine(
        id: 'ai:claude',
        kind: EngineKind.ai,
        name: 'Claude',
        subtitle: 'claude-sonnet',
        providerId: 'claude',
      );
      expect(
        const ImproveEngines(engines: [claude]),
        const ImproveEngines(engines: [claude]),
      );
      expect(
        const ImproveEngines(engines: [claude]),
        isNot(const ImproveEngines(engines: [edited])),
      );
      expect(improveEngineKey(null), isNull);
    });
  });
}
