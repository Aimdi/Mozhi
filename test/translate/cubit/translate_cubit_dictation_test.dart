import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

import 'translate_cubit_helpers.dart';

/// Voice input hands the input card partial results while the user speaks
/// and then the final one (`VoiceInputButton` -> `setInput(dictated:)`):
/// what is said gets translated, once it is said.
void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() => mocks = TranslateMocks()..stubTranslate());

  const said = 'Ask not what your country can do for you';

  blocTest<TranslateCubit, TranslateState>(
    'a dictated utterance is translated once, with the final words',
    build: () => mocks.build(),
    seed: readyState,
    act: (cubit) async {
      cubit
        ..setInput('Ask not', dictated: true)
        ..setInput('Ask not what your', dictated: true)
        ..setInput(said, dictated: true);
      await Future<void>.delayed(afterDebounce);
    },
    verify: (cubit) {
      expect(mocks.translateRequests().single.text, said);
      expect(cubit.state.output, '$said->en');
      expect(cubit.state.instantResult, isTrue);
    },
  );

  blocTest<TranslateCubit, TranslateState>(
    'with an AI engine too',
    build: () => mocks.build(),
    seed: () => readyState(engine: claude),
    act: (cubit) async {
      cubit.setInput(said, dictated: true);
      await Future<void>.delayed(afterDebounce);
    },
    verify: (cubit) => expect(mocks.translateRequests().single.text, said),
  );

  blocTest<TranslateCubit, TranslateState>(
    'with instant translation off it waits for Translate',
    setUp: () => mocks.stubSettings(const AppSettings(instantTranslate: false)),
    build: () => mocks.build(),
    seed: readyState,
    act: (cubit) async {
      cubit.setInput(said, dictated: true);
      await Future<void>.delayed(afterDebounce);
      verifyNever(() => mocks.repository.translate(any(), any()));
      await cubit.translate();
    },
    verify: (cubit) => expect(mocks.translateRequests().single.text, said),
  );
}
