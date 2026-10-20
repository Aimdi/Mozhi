@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/proofread.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/voice/voice.dart' show SpeechInputService;

import '../proofread/helpers/proofread_helpers.dart';
import '../translate/helpers/helpers.dart' show FakeSpeechInput;
import 'helpers/golden_helpers.dart';

/// Pumps [ProofreadView] on a phone with [state], the app's theme and
/// voice input available.
Future<void> _pumpProofread(
  WidgetTester tester, {
  required ProofreadState state,
  Brightness brightness = Brightness.light,
}) async {
  useGoldenDevice(tester, GoldenDevice.phone);
  final proofread = MockProofreadCubit();
  stubProofreadCubit(proofread);
  whenListen(
    proofread,
    const Stream<ProofreadState>.empty(),
    initialState: state,
  );
  final translate = MockTranslateCubit();
  whenListen(
    translate,
    const Stream<TranslateState>.empty(),
    initialState: readyTranslateState,
  );
  final speechInput = FakeSpeechInput();
  await tester.pumpWidget(
    RepositoryProvider<SpeechInputService>.value(
      value: speechInput.service,
      child: MultiBlocProvider(
        providers: [
          BlocProvider<TranslateCubit>.value(value: translate),
          BlocProvider<ProofreadCubit>.value(value: proofread),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: goldenTheme(brightness),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ProofreadView(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  goldenGroup('Proofread screen', () {
    testWidgets('empty on a phone (dark)', (tester) async {
      await _pumpProofread(
        tester,
        state: readyState,
        brightness: Brightness.dark,
      );
      await expectScreenGolden('proofread_empty_phone_dark');
    });

    testWidgets('with a result on a phone (light)', (tester) async {
      await _pumpProofread(tester, state: successState(accepted: {0, 1}));
      await expectScreenGolden('proofread_result_phone_light');
    });
  });
}
