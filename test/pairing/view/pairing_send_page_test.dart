import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/pairing/cubit/pairing_send_cubit.dart';
import 'package:mozhi/pairing/data/pairing_environment.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/models/pairing_failure.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/pairing/view/pairing_send_page.dart';

import '../../helpers/helpers.dart';

class _MockSendCubit extends MockCubit<PairingSendState>
    implements PairingSendCubit;

void main() {
  late _MockSendCubit cubit;

  final packs = [
    const PairingOutgoingItem(
      PairingItem(
        kind: PairingItemKind.translation,
        key: 'de',
        files: [PairingFile(name: 'de-en/model.bin', size: 3 << 20)],
      ),
      {},
      language: 'de',
    ),
    const PairingOutgoingItem(
      PairingItem(
        kind: PairingItemKind.speech,
        key: 'silero-vad',
        files: [PairingFile(name: 'ggml-silero.bin', size: 900)],
      ),
      {},
    ),
    const PairingOutgoingItem(
      PairingItem(
        kind: PairingItemKind.speech,
        key: 'tiny',
        files: [PairingFile(name: 'ggml-tiny.bin', size: 900)],
      ),
      {},
    ),
    const PairingOutgoingItem(
      PairingItem(
        kind: PairingItemKind.dictionary,
        key: 'es',
        files: [PairingFile(name: 'es.mzd', size: 900)],
      ),
      {},
      language: 'es',
    ),
  ];

  setUp(() {
    cubit = _MockSendCubit();
    when(() => cubit.connect()).thenAnswer((_) async {});
    when(() => cubit.confirm(match: any(named: 'match')))
        .thenAnswer((_) async {});
    when(() => cubit.send()).thenAnswer((_) async {});
  });

  Future<void> pump(WidgetTester tester, PairingSendState state) async {
    tester.view
      ..physicalSize = const Size(800, 1800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    when(() => cubit.state).thenReturn(state);
    await tester.pumpApp(
      Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => BlocProvider<PairingSendCubit>.value(
            value: cubit,
            child: const PairingSendView(),
          ),
        ),
      ),
    );
  }

  group('PairingSendView', () {
    testWidgets('takes the code typed or pasted', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              return {'text': ' mozhi://pair?code=ABC '};
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await pump(tester, const PairingSendState(input: 'AB'));
      expect(find.text('Send to another phone'), findsOneWidget);
      expect(find.text('AB'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('pairing_code_field')), 'XY');
      verify(() => cubit.setInput('XY')).called(1);
      await tester.tap(find.byTooltip('Paste code'));
      await tester.pump();
      verify(() => cubit.setInput('mozhi://pair?code=ABC')).called(1);
      expect(find.text('mozhi://pair?code=ABC'), findsOneWidget);
      await tester.tap(find.byKey(const Key('pairing_connect')));
      verify(() => cubit.connect()).called(1);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      verify(() => cubit.connect()).called(1);
    });

    testWidgets('pastes nothing from an empty clipboard', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              throw PlatformException(code: 'x');
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await pump(tester, const PairingSendState());
      await tester.tap(find.byTooltip('Paste code'));
      await tester.pump();
      verifyNever(() => cubit.setInput(any()));
    });

    testWidgets('says when the code is not one', (tester) async {
      await pump(
        tester,
        const PairingSendState(input: 'nope', invalidCode: true),
      );
      expect(
        find.text("That's not a pairing code. Check it for typos."),
        findsOneWidget,
      );
    });

    testWidgets('connects', (tester) async {
      await pump(
        tester,
        const PairingSendState(step: PairingSendStep.connecting),
      );
      expect(find.text('Connecting…'), findsOneWidget);
    });

    testWidgets('asks to compare the numbers', (tester) async {
      await pump(
        tester,
        const PairingSendState(step: PairingSendStep.confirm, sas: '000123'),
      );
      expect(find.text('000 123'), findsOneWidget);
      expect(
        find.text('Does the other phone show the same number?'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('pairing_mismatch')));
      verify(() => cubit.confirm(match: false)).called(1);
      await tester.tap(find.byKey(const Key('pairing_match')));
      verify(() => cubit.confirm(match: true)).called(1);
    });

    testWidgets('lists what can be sent while loading', (tester) async {
      await pump(
        tester,
        const PairingSendState(step: PairingSendStep.choose, loading: true),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('lets the user choose what to send', (tester) async {
      await pump(
        tester,
        PairingSendState(
          step: PairingSendStep.choose,
          packs: packs,
          sections: const ['history', 'settings'],
          chosenSections: const {'history'},
          selected: const {PairingBackupItem.id, 'translation:de'},
          includeSecrets: true,
        ),
      );
      expect(find.text('Choose what to send'), findsOneWidget);
      expect(find.text('History and favorites'), findsOneWidget);
      expect(
        find.text(
          'The other phone can then use your paid AI providers and sign in '
          'to your servers. Only send them to a phone of your own.',
        ),
        findsOneWidget,
      );
      expect(find.text('Translation: German'), findsOneWidget);
      expect(find.text('3.0 MB'), findsOneWidget);
      expect(find.text('Speech detector'), findsOneWidget);
      expect(find.text('Speech recognition: Whisper tiny'), findsOneWidget);
      expect(find.text('Dictionary: Spanish'), findsOneWidget);

      await tester.tap(find.text('Settings'));
      verify(() => cubit.toggleSection('settings')).called(1);
      await tester.tap(find.byKey(const Key('pairing_send_secrets')));
      verify(() => cubit.setIncludeSecrets(include: false)).called(1);
      await tester.tap(find.byKey(const Key('pairing_send_data')));
      verify(() => cubit.toggle(PairingBackupItem.id)).called(1);
      await tester.tap(
        find.byKey(const ValueKey('pairing_send_dictionary:es')),
      );
      verify(() => cubit.toggle('dictionary:es')).called(1);
      await tester.tap(find.byKey(const Key('pairing_send')));
      verify(() => cubit.send()).called(1);
    });

    testWidgets('cannot send nothing', (tester) async {
      await pump(tester, const PairingSendState(step: PairingSendStep.choose));
      expect(
        find.text('No offline languages or models on this phone yet.'),
        findsOneWidget,
      );
      expect(find.text('Your data'), findsNothing);
      final send = tester.widget<FilledButton>(
        find.byKey(const Key('pairing_send')),
      );
      expect(send.onPressed, isNull);
    });

    testWidgets('waits for the other phone', (tester) async {
      await pump(tester, const PairingSendState(step: PairingSendStep.waiting));
      expect(
        find.text('Waiting for the other phone to accept…'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pump();
    });

    testWidgets('shows the progress', (tester) async {
      await pump(
        tester,
        PairingSendState(
          step: PairingSendStep.transferring,
          packs: packs,
          progress: const PairingProgress(
            bytes: 0,
            totalBytes: 100,
            itemId: PairingBackupItem.id,
          ),
        ),
      );
      expect(find.text('Sending Your data…'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('lists the results and what was skipped', (tester) async {
      await pump(
        tester,
        PairingSendState(
          step: PairingSendStep.done,
          packs: packs,
          results: const [
            PairingItemResult('translation:de', PairingItemOutcome.installed),
          ],
          skipped: const ['dictionary:es'],
        ),
      );
      expect(find.text('Translation: German'), findsOneWidget);
      expect(
        find.text(
          "1 item was already on the other phone, or isn't usable there.",
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    });

    testWidgets('explains a failure and retries', (tester) async {
      await pump(
        tester,
        const PairingSendState(
          step: PairingSendStep.failed,
          failure: PairingFailure.unreachable,
        ),
      );
      expect(
        find.textContaining("Couldn't reach the other phone."),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('pairing_retry')));
      verify(() => cubit.retry()).called(1);
    });
  });

  group('PairingSendPage', () {
    testWidgets('fills in the code it was opened with', (tester) async {
      final environment = PairingEnvironment(
        library: PairingLibrary(),
        temporaryDirectory: () async => Directory.systemTemp,
      );
      await tester.pumpApp(
        PairingSendPage(
          initialCode: 'ABCD-EFGH',
          purpose: PairingSendPurpose.packs,
          environment: environment,
        ),
      );
      expect(find.text('ABCD-EFGH'), findsOneWidget);
    });

    testWidgets('is not available outside Android', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await tester.pumpApp(const PairingSendPage());
      expect(
        find.text('Phone to phone works in the Android app.'),
        findsOneWidget,
      );
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
