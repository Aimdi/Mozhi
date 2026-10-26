import 'dart:ui';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/shared_text_handler.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

import 'helpers.dart';

class _MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class _MockSharedTextService extends Mock implements SharedTextService;

class _MockQuickTranslateHost extends Mock implements QuickTranslateHost;

// The screen-translate window is a second copy of the app, like the quick
// translate window: it hands its network activity to the main window and
// never takes the main window's place as the receiver.
void main() {
  late _MockSharedTextService service;
  late _MockQuickTranslateHost quick;
  late MockScreenTranslateHost screen;
  late EgressLedger ledger;

  setUp(() {
    service = _MockSharedTextService();
    quick = _MockQuickTranslateHost();
    screen = mockScreenTranslateHost();
    ledger = EgressLedger();
    when(() => service.texts).thenAnswer((_) => const Stream.empty());
    when(service.initialText).thenAnswer((_) async => null);
    when(() => quick.isActive).thenReturn(false);
    when(() => screen.isActive).thenReturn(true);
  });

  tearDown(() => IsolateNameServer.removePortNameMapping(EgressRelay.portName));

  SharedTextHandler create() => SharedTextHandler(
    service: service,
    translateCubit: _MockTranslateCubit(),
    onShowTranslate: () {},
    quickHost: quick,
    screenHost: screen,
    ledger: ledger,
  );

  test('the window forwards its activity to the main window', () async {
    final main = EgressLedger();
    final stop = EgressRelay.receive(main);
    addTearDown(stop);
    final mainPort = IsolateNameServer.lookupPortByName(EgressRelay.portName);
    final handler = create();
    await handler.start();

    // Still the main window's port.
    expect(IsolateNameServer.lookupPortByName(EgressRelay.portName), mainPort);
    final entry = ledger.begin(
      method: 'POST',
      scheme: 'https',
      destination: const EgressDestination(
        kind: EgressDestinationKind.publicServer,
        host: 'mozhi.example',
      ),
      purpose: EgressPurpose.translation,
    );
    ledger.update(entry.copyWith(outcome: EgressOutcome.succeeded));
    await pumpEventQueue();
    expect(main.entries.single.destination.host, 'mozhi.example');

    await handler.dispose();
    // The window does not close itself without shared text: its page
    // waits for the screenshot.
    verifyNever(quick.close);
    verifyNever(screen.close);
  });

  test('without a main window it registers nothing', () async {
    final handler = create();
    await handler.start();
    expect(IsolateNameServer.lookupPortByName(EgressRelay.portName), isNull);
    await handler.dispose();
  });
}
