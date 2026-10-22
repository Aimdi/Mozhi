import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/practice/cubit/practice_speech_cubit.dart';
import 'package:mozhi/practice/data/answer_check.dart';
import 'package:mozhi/practice/data/practice_speech.dart';

import '../helpers.dart';

void main() {
  group(PracticeSpeechCubit, () {
    late FakeRecognizer recognizer;
    late PracticeSpeechCubit cubit;

    setUp(() {
      recognizer = FakeRecognizer();
      cubit = PracticeSpeechCubit(recognizer: recognizer);
    });

    tearDown(() => cubit.close());

    test('says whether it can run', () async {
      expect(cubit.state.status, PracticeSpeechStatus.checking);
      expect(cubit.state.isOffered, isFalse);
      await cubit.load();
      expect(cubit.state.status, PracticeSpeechStatus.idle);
      expect(cubit.state.isOffered, isTrue);
      expect(cubit.state.canListen, isTrue);
      recognizer.available = PracticeSpeechAvailability.modelMissing;
      await cubit.load();
      expect(cubit.state.status, PracticeSpeechStatus.modelMissing);
      expect(cubit.state.canListen, isFalse);
      recognizer.available = PracticeSpeechAvailability.unsupported;
      await cubit.load();
      expect(cubit.state.status, PracticeSpeechStatus.unsupported);
      expect(cubit.state.isOffered, isFalse);
      expect(cubit.supportsLanguage('pt'), isTrue);
      expect(cubit.supportsLanguage('yue'), isFalse);
    });

    test('listens, transcribes and compares', () async {
      await cubit.load();
      final done = cubit.listen(expected: 'Bom dia', code: 'pt');
      expect(cubit.state.status, PracticeSpeechStatus.listening);
      expect(recognizer.language, 'pt');
      recognizer.onLevel!(0.5);
      expect(cubit.state.level, 0.5);
      // Already listening.
      await cubit.listen(expected: 'x', code: 'pt');
      await cubit.stop();
      expect(cubit.state.status, PracticeSpeechStatus.transcribing);
      expect(recognizer.stops, 1);
      recognizer.onLevel!(0.9);
      expect(cubit.state.status, PracticeSpeechStatus.transcribing);
      recognizer.onTranscribing!();
      recognizer.answer('bom dia');
      await done;
      expect(cubit.state.status, PracticeSpeechStatus.heard);
      expect(cubit.state.check!.isExact, isTrue);
      expect(
        cubit.state.check!.words.first,
        const AnswerWord('Bom', AnswerWordStatus.matched),
      );
      // Stop does nothing unless listening.
      await cubit.stop();
      expect(recognizer.stops, 1);
    });

    test('reports failures', () async {
      await cubit.load();
      var done = cubit.listen(expected: 'Bom dia', code: 'pt');
      recognizer.fail(
        const PracticeSpeechException(PracticeSpeechFailure.noSpeech),
      );
      await done;
      expect(cubit.state.status, PracticeSpeechStatus.failed);
      expect(cubit.state.failure, PracticeSpeechFailure.noSpeech);
      expect(cubit.state.canListen, isTrue);

      done = cubit.listen(expected: 'Bom dia', code: 'pt');
      recognizer.fail(
        const PracticeSpeechException(PracticeSpeechFailure.modelMissing),
      );
      await done;
      expect(cubit.state.status, PracticeSpeechStatus.modelMissing);

      await cubit.load();
      done = cubit.listen(expected: 'Bom dia', code: 'pt');
      recognizer.fail(StateError('boom'));
      await done;
      expect(cubit.state.failure, PracticeSpeechFailure.engine);
    });

    test('reset drops a recording and what was heard', () async {
      await cubit.load();
      final done = cubit.listen(expected: 'Bom dia', code: 'pt');
      await cubit.reset();
      expect(recognizer.cancels, 1);
      await done;
      expect(cubit.state.status, PracticeSpeechStatus.idle);
      // A result of the dropped recording is ignored.
      recognizer.answer('late');

      final next = cubit.listen(expected: 'Bom dia', code: 'pt');
      recognizer.answer('bom');
      await next;
      expect(cubit.state.status, PracticeSpeechStatus.heard);
      await cubit.reset();
      expect(cubit.state.status, PracticeSpeechStatus.idle);
      expect(cubit.state.check, isNull);
      expect(recognizer.cancels, 1);
    });

    test('a cancelled recording goes back to idle', () async {
      await cubit.load();
      final done = cubit.listen(expected: 'Bom dia', code: 'pt');
      recognizer.fail(
        const PracticeSpeechException(PracticeSpeechFailure.cancelled),
      );
      await done;
      expect(cubit.state.status, PracticeSpeechStatus.idle);
    });

    test('reset keeps a missing model', () async {
      recognizer.available = PracticeSpeechAvailability.modelMissing;
      await cubit.load();
      await cubit.reset();
      expect(cubit.state.status, PracticeSpeechStatus.modelMissing);
    });

    test('close releases the recogniser', () async {
      await cubit.close();
      expect(recognizer.disposed, isTrue);
    });
  });
}
