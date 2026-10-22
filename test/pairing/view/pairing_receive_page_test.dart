import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/core/qr/qr_code_view.dart';
import 'package:mozhi/pairing/cubit/pairing_receive_cubit.dart';
import 'package:mozhi/pairing/data/pairing_environment.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/models/pairing_failure.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/pairing/protocol/pairing_code.dart';
import 'package:mozhi/pairing/view/pairing_receive_page.dart';

import '../../helpers/helpers.dart';

class _MockReceiveCubit extends MockCubit<PairingReceiveState>
    implements PairingReceiveCubit;

void main() {
  late _MockReceiveCubit cubit;
  final code = PairingCode(
    address: const [192, 168, 1, 20],
    port: 41234,
    secret: List.filled(8, 7),
  );

  const de = PairingItem(
    kind: PairingItemKind.translation,
    key: 'de',
    files: [PairingFile(name: 'de-en/model.bin', size: 2 << 20)],
  );
  const fr = PairingItem(
    kind: PairingItemKind.translation,
    key: 'fr',
    files: [PairingFile(name: 'fr-en/model.bin', size: 10)],
  );
  const ocr = PairingItem(
    kind: PairingItemKind.ocr,
    key: 'xyz',
    files: [PairingFile(name: 'xyz.traineddata', size: 10)],
  );
  const data = PairingItem(
    kind: PairingItemKind.data,
    key: PairingBackupItem.key,
    files: [PairingFile(name: 'backup.json', size: 500)],
    sections: ['history', 'settings'],
    secrets: true,
  );
  final offered = [
    const PairingOfferedItem(
      data,
      PairingPlan.available([PairingFile(name: 'backup.json', size: 500)]),
    ),
    const PairingOfferedItem(
      de,
      PairingPlan.available([
        PairingFile(name: 'de-en/model.bin', size: 2 << 20),
      ], language: 'de'),
    ),
    const PairingOfferedItem(fr, PairingPlan.installed(language: 'fr')),
    const PairingOfferedItem(ocr, PairingPlan.incompatible()),
  ];

  setUp(() {
    cubit = _MockReceiveCubit();
    when(() => cubit.start(address: any(named: 'address')))
        .thenAnswer((_) async {});
    when(() => cubit.useAddress(any())).thenAnswer((_) async {});
    when(() => cubit.accept()).thenAnswer((_) async {});
    when(() => cubit.decline()).thenAnswer((_) async {});
  });

  Future<void> pump(WidgetTester tester, PairingReceiveState state) async {
    tester.view
      ..physicalSize = const Size(800, 1800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    when(() => cubit.state).thenReturn(state);
    await tester.pumpApp(
      Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => BlocProvider<PairingReceiveCubit>.value(
            value: cubit,
            child: const PairingReceiveView(),
          ),
        ),
      ),
    );
  }

  group('PairingReceiveView', () {
    testWidgets('starts with a spinner', (tester) async {
      await pump(tester, const PairingReceiveState());
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Receive on this phone'), findsOneWidget);
    });

    testWidgets('asks for a network', (tester) async {
      await pump(
        tester,
        const PairingReceiveState(step: PairingReceiveStep.noNetwork),
      );
      expect(
        find.text('Connect to Wi-Fi or turn on a hotspot'),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry'));
      verify(() => cubit.start()).called(1);
    });

    testWidgets('shows the code, its text and when it expires', (tester) async {
      final copied = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') copied.add(call.arguments);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await pump(
        tester,
        PairingReceiveState(
          step: PairingReceiveStep.waiting,
          addresses: const ['192.168.1.20'],
          address: '192.168.1.20',
          code: code,
          expiresAt: DateTime.now().add(
            const Duration(minutes: 4, seconds: 30),
          ),
        ),
      );
      final qr = tester.widget<QrCodeView>(find.byType(QrCodeView));
      expect(qr.data, code.link);
      expect(qr.semanticLabel, 'Pairing code for the other phone');
      expect(find.text(code.text), findsOneWidget);
      expect(find.textContaining('Expires in 4:'), findsOneWidget);
      expect(find.text('On 192.168.1.20'), findsOneWidget);

      await tester.tap(find.byTooltip('Copy code'));
      await tester.pump();
      expect(copied, hasLength(1));
      expect(find.text('Copied to clipboard'), findsOneWidget);

      await tester.tap(find.byKey(const Key('pairing_new_code')));
      verify(() => cubit.start(address: '192.168.1.20')).called(1);

      // The countdown ticks.
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Expires in'), findsOneWidget);
    });

    testWidgets('lets the user pick another network', (tester) async {
      await pump(
        tester,
        PairingReceiveState(
          step: PairingReceiveStep.waiting,
          addresses: const ['192.168.1.20', '10.0.0.4'],
          address: '192.168.1.20',
          code: code,
          expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
        ),
      );
      expect(find.text('Expires in 0:00'), findsOneWidget);
      final menu = tester.widget<DropdownMenu<String>>(
        find.byKey(const Key('pairing_network')),
      );
      expect(menu.initialSelection, '192.168.1.20');
      menu.onSelected!('192.168.1.20');
      menu.onSelected!(null);
      verifyNever(() => cubit.useAddress(any()));
      menu.onSelected!('10.0.0.4');
      verify(() => cubit.useAddress('10.0.0.4')).called(1);
    });

    testWidgets('offers a new code once it expired', (tester) async {
      await pump(
        tester,
        const PairingReceiveState(step: PairingReceiveStep.expired),
      );
      expect(find.text('The code has expired'), findsOneWidget);
      await tester.tap(find.byKey(const Key('pairing_new_code')));
      verify(() => cubit.start()).called(1);
    });

    testWidgets('shows the number while the other phone chooses', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(
        tester,
        const PairingReceiveState(
          step: PairingReceiveStep.connected,
          sas: '042917',
        ),
      );
      expect(find.text('042 917'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Number to compare: 0 4 2 9 1 7')),
        findsOneWidget,
      );
      semantics.dispose();
      expect(
        find.text('Waiting for the other phone to choose what to send…'),
        findsOneWidget,
      );
    });

    testWidgets('shows the offer and takes the answer', (tester) async {
      await pump(
        tester,
        PairingReceiveState(
          step: PairingReceiveStep.offer,
          sas: '123456',
          offered: offered,
          selected: const {PairingBackupItem.id, 'translation:de'},
        ),
      );
      expect(find.text('123 456'), findsOneWidget);
      expect(find.text('Your data'), findsOneWidget);
      expect(find.text('History and favorites, Settings'), findsOneWidget);
      expect(find.text('Includes API keys and passwords'), findsOneWidget);
      expect(find.text('Translation: German'), findsOneWidget);
      expect(find.text('2.0 MB'), findsOneWidget);
      expect(find.text('Already on this phone'), findsOneWidget);
      expect(
        find.text("Not usable with this phone's version of Mozhi"),
        findsOneWidget,
      );
      expect(find.text('Text recognition: xyz'), findsOneWidget);
      final installed = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('pairing_item_translation:fr')),
      );
      expect(installed.onChanged, isNull);
      expect(installed.value, isFalse);

      await tester.tap(
        find.byKey(const ValueKey('pairing_item_translation:de')),
      );
      verify(() => cubit.toggle('translation:de')).called(1);

      await tester.scrollUntilVisible(find.text('Replace my data'), 100);
      await tester.tap(find.text('Replace my data'));
      verify(() => cubit.setMode(BackupRestoreMode.replace)).called(1);

      await tester.scrollUntilVisible(
        find.byKey(const Key('pairing_accept')),
        100,
      );
      await tester.tap(find.byKey(const Key('pairing_accept')));
      verify(() => cubit.accept()).called(1);
      await tester.tap(find.byKey(const Key('pairing_decline')));
      verify(() => cubit.decline()).called(1);
    });

    testWidgets('hides the restore modes without data', (tester) async {
      await pump(
        tester,
        PairingReceiveState(
          step: PairingReceiveStep.offer,
          sas: '123456',
          offered: offered,
          selected: const {'translation:de'},
        ),
      );
      expect(find.text('Replace my data'), findsNothing);
    });

    testWidgets('shows the progress and cancels by leaving', (tester) async {
      await pump(
        tester,
        PairingReceiveState(
          step: PairingReceiveStep.transferring,
          offered: offered,
          progress: const PairingProgress(
            bytes: 1 << 20,
            totalBytes: 2 << 20,
            itemId: 'translation:de',
          ),
        ),
      );
      expect(find.text('Receiving Translation: German…'), findsOneWidget);
      expect(find.text('1.0 MB of 2.0 MB'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.5);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('says when the other phone installs', (tester) async {
      await pump(
        tester,
        PairingReceiveState(
          step: PairingReceiveStep.transferring,
          offered: offered,
          progress: const PairingProgress(
            bytes: 10,
            totalBytes: 10,
            itemId: 'translation:de',
            installing: true,
          ),
        ),
      );
      expect(
        find.text('Installing Translation: German on the receiving phone…'),
        findsOneWidget,
      );
    });

    testWidgets('lists the results', (tester) async {
      await pump(
        tester,
        PairingReceiveState(
          step: PairingReceiveStep.done,
          offered: offered,
          results: const [
            PairingItemResult(
              PairingBackupItem.id,
              PairingItemOutcome.installed,
            ),
            PairingItemResult('translation:de', PairingItemOutcome.installed),
            PairingItemResult('translation:fr', PairingItemOutcome.damaged),
            PairingItemResult('ocr:xyz', PairingItemOutcome.noSpace),
            PairingItemResult('dictionary:es', PairingItemOutcome.failed),
            PairingItemResult('speech:tiny', PairingItemOutcome.incompatible),
          ],
        ),
      );
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Restored'), findsOneWidget);
      expect(find.text('Installed'), findsOneWidget);
      expect(
        find.text("A file didn't check out, so nothing of it was installed"),
        findsOneWidget,
      );
      expect(find.text('Not enough storage space'), findsOneWidget);
      expect(find.text("Couldn't install"), findsOneWidget);
      expect(find.text('dictionary:es'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    });

    testWidgets('says when the user declined', (tester) async {
      await pump(
        tester,
        const PairingReceiveState(step: PairingReceiveStep.declined),
      );
      expect(find.text('Nothing was received'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    });

    testWidgets('explains failures and offers a new code', (tester) async {
      for (final failure in PairingFailure.values) {
        await pump(
          tester,
          PairingReceiveState(
            step: PairingReceiveStep.failed,
            failure: failure,
          ),
        );
        expect(find.text('Stopped'), findsOneWidget, reason: '$failure');
      }
      await tester.tap(find.byKey(const Key('pairing_new_code')));
      verify(() => cubit.start()).called(1);
    });
  });

  group('PairingReceivePage', () {
    testWidgets('starts listening with its environment', (tester) async {
      final environment = PairingEnvironment(
        library: PairingLibrary(),
        temporaryDirectory: () async => Directory.systemTemp,
        addresses: () async => const [],
      );
      await tester.pumpApp(PairingReceivePage(environment: environment));
      await tester.pump();
      expect(
        find.text('Connect to Wi-Fi or turn on a hotspot'),
        findsOneWidget,
      );
    });

    testWidgets('is not available outside Android', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await tester.pumpApp(const PairingReceivePage());
      expect(
        find.text('Phone to phone works in the Android app.'),
        findsOneWidget,
      );
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
