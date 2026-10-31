import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/transcribe/transcribe.dart';
import 'package:mozhi/voice/voice.dart';

import '../helpers.dart';

class _MockTranscribeCubit extends MockCubit<TranscribeState>
    implements TranscribeCubit;

void main() {
  late _MockTranscribeCubit cubit;
  late MockSpeechInputService speech;

  setUp(() {
    cubit = _MockTranscribeCubit();
    speech = MockSpeechInputService();
    when(() => cubit.start()).thenAnswer((_) async {});
    when(() => speech.usesBrowserRecognizer).thenReturn(true);
    when(() => speech.needsBrowserNotice()).thenAnswer((_) async => true);
    when(() => speech.acceptBrowserNotice()).thenAnswer((_) async {});
  });

  Future<void> pump(WidgetTester tester, TranscribeMode mode) async {
    when(() => cubit.state).thenReturn(
      TranscribeState(
        source: english,
        target: german,
        mode: mode,
        status: TranscribeStatus.idle,
      ),
    );
    await tester.pumpWidget(
      RepositoryProvider<SpeechInputService>.value(
        value: speech,
        child: BlocProvider<TranscribeCubit>.value(
          value: cubit,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: TranscribeControls()),
          ),
        ),
      ),
    );
  }

  group('the browser speech notice', () {
    testWidgets('comes before the browser recognises speech', (tester) async {
      await pump(tester, TranscribeMode.system);
      await tester.tap(find.byKey(const Key('transcribe_mic')));
      await tester.pumpAndSettle();

      expect(find.byType(BrowserSpeechNoticeDialog), findsOneWidget);
      verifyNever(() => cubit.start());

      await tester.tap(find.byKey(BrowserSpeechNoticeDialog.continueKey));
      await tester.pumpAndSettle();
      verify(() => speech.acceptBrowserNotice()).called(1);
      verify(() => cubit.start()).called(1);
    });

    testWidgets('declined, nothing starts', (tester) async {
      await pump(tester, TranscribeMode.system);
      await tester.tap(find.byKey(const Key('transcribe_mic')));
      await tester.pumpAndSettle();
      final l10n = tester.element(find.byType(TranscribeControls)).l10n;
      await tester.tap(find.text(l10n.commonCancel));
      await tester.pumpAndSettle();

      verifyNever(() => cubit.start());
      verifyNever(() => speech.acceptBrowserNotice());
    });

    testWidgets('is not shown for Whisper', (tester) async {
      await pump(tester, TranscribeMode.whisper);
      await tester.tap(find.byKey(const Key('transcribe_mic')));
      await tester.pumpAndSettle();

      expect(find.byType(BrowserSpeechNoticeDialog), findsNothing);
      verify(() => cubit.start()).called(1);
    });
  });
}
