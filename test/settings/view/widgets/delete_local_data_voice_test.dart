import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart';
import 'package:mozhi/voice/voice.dart';

import '../helpers.dart';

class _MockOfflineSpeech extends Mock implements OfflineSpeech;

class _MockSpeechInputService extends Mock implements SpeechInputService;

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(const AppSettings());
  });

  late MockHistoryCubit history;
  late MockSettingsCubit settings;
  late _MockOfflineSpeech offlineSpeech;
  late _MockSpeechInputService speechInput;

  setUp(() {
    history = createHistoryCubit();
    when(history.deleteAll).thenAnswer((_) async {});
    when(() => history.search(any())).thenReturn(null);
    settings = createSettingsCubit();
    offlineSpeech = _MockOfflineSpeech();
    when(offlineSpeech.deleteAll).thenAnswer((_) async {});
    speechInput = _MockSpeechInputService();
  });

  test('deletes the offline speech models', () async {
    await LocalDataEraser(
      history: history,
      settings: settings,
      offlineSpeech: offlineSpeech,
      speechInput: speechInput,
    ).erase();
    verify(offlineSpeech.deleteAll).called(1);
    verify(speechInput.forgetSettings).called(1);
  });

  test('reports a failed deletion after trying the rest', () async {
    when(offlineSpeech.deleteAll).thenThrow(StateError('busy'));
    await expectLater(
      LocalDataEraser(
        history: history,
        settings: settings,
        offlineSpeech: offlineSpeech,
      ).erase(),
      throwsStateError,
    );
    verify(() => settings.update(any())).called(1);
  });

  testWidgets('of reads the offline speech models', (tester) async {
    late LocalDataEraser found;
    await tester.pumpWidget(
      RepositoryProvider<OfflineSpeech>.value(
        value: offlineSpeech,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<HistoryCubit>.value(value: history),
            BlocProvider<SettingsCubit>.value(value: settings),
          ],
          child: Builder(
            builder: (context) {
              found = LocalDataEraser.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(found.offlineSpeech, same(offlineSpeech));
  });
}
