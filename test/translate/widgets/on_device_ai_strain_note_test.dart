import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const onDevice = TranslationEngine(
  id: 'ai:device-hy-mt2-1.8b-q4',
  kind: EngineKind.ai,
  name: 'Hy-MT2 1.8B (on this device)',
  providerId: 'device-hy-mt2-1.8b-q4',
  isLocal: true,
  onDevice: true,
);

class _FakeConditions extends Fake implements DeviceConditions {
  DeviceConditionsSnapshot snapshot = DeviceConditionsSnapshot.unknown;
  final controller = StreamController<DeviceConditionsSnapshot>.broadcast();
  int reads = 0;

  @override
  DeviceConditionsSnapshot get latest {
    reads++;
    return snapshot;
  }

  @override
  Stream<DeviceConditionsSnapshot> get changes => controller.stream;

  void change(DeviceConditionsSnapshot next) {
    snapshot = next;
    controller.add(next);
  }
}

const _hot = DeviceConditionsSnapshot(thermal: ThermalStatus.critical);
const _saver = DeviceConditionsSnapshot(powerSave: true);
const _heatText =
    'Your phone is hot, so on-device AI waits until you press Enter or '
    'Translate.';
const _saverText =
    'Battery saver is on, so on-device AI waits until you press Enter or '
    'Translate.';

void main() {
  setUpAll(registerTranslateFallbacks);

  late _FakeConditions conditions;

  setUp(() {
    conditions = _FakeConditions();
    addTearDown(conditions.controller.close);
  });

  TranslateState typed({TranslationEngine engine = onDevice}) =>
      readyState(engine: engine, input: 'Hallo');

  group('onDeviceAiWaitsForEnter', () {
    test('only for untranslated text typed for on-device AI', () {
      expect(onDeviceAiWaitsForEnter(typed(), instantAi: true), isTrue);
      expect(onDeviceAiWaitsForEnter(typed(), instantAi: false), isFalse);
      expect(
        onDeviceAiWaitsForEnter(typed(engine: claude), instantAi: true),
        isFalse,
      );
      expect(
        onDeviceAiWaitsForEnter(readyState(engine: onDevice), instantAi: true),
        isFalse,
      );
      expect(
        onDeviceAiWaitsForEnter(
          typed().copyWith(status: TranslateStatus.translating),
          instantAi: true,
        ),
        isFalse,
      );
      expect(
        onDeviceAiWaitsForEnter(
          typed().copyWith(status: TranslateStatus.failure),
          instantAi: true,
        ),
        isFalse,
      );
      expect(
        onDeviceAiWaitsForEnter(
          typed().copyWith(compareMode: true),
          instantAi: true,
        ),
        isFalse,
      );
      // A translation of the text: nothing waits.
      final done = typed().copyWith(
        result: () => helloResult,
        resultInput: () => 'Hallo',
      );
      expect(onDeviceAiWaitsForEnter(done, instantAi: true), isFalse);
      // One of earlier text: the new text waits.
      expect(
        onDeviceAiWaitsForEnter(
          done.copyWith(input: 'Hallo Welt'),
          instantAi: true,
        ),
        isTrue,
      );
    });
  });

  group(OnDeviceAiStrainNote, () {
    Future<void> pump(
      WidgetTester tester,
      TranslateState state, {
      AppSettings settings = const AppSettings(),
    }) => TranslateHarness(
      state: state,
      settings: settings,
    ).pump(tester, child: OnDeviceAiStrainNote(conditions: conditions));

    testWidgets('says the phone is hot', (tester) async {
      conditions.snapshot = _hot;
      await pump(tester, typed());
      expect(find.text(_heatText), findsOneWidget);
      expect(find.byIcon(Icons.thermostat_outlined), findsOneWidget);
    });

    testWidgets('says battery saver is on', (tester) async {
      conditions.snapshot = _saver;
      await pump(tester, typed());
      expect(find.text(_saverText), findsOneWidget);
      expect(find.byIcon(Icons.battery_saver_outlined), findsOneWidget);
    });

    testWidgets('follows the conditions', (tester) async {
      await pump(tester, typed());
      expect(
        find.byKey(const Key('translate_on_device_ai_strain')),
        findsNothing,
      );

      conditions.change(_hot);
      await tester.pump();
      expect(find.text(_heatText), findsOneWidget);

      conditions.change(DeviceConditionsSnapshot.unknown);
      await tester.pump();
      expect(find.text(_heatText), findsNothing);
    });

    testWidgets('never asks for other engines or without typing', (
      tester,
    ) async {
      conditions.snapshot = _hot;
      await pump(tester, typed(engine: claude));
      await pump(
        tester,
        typed(),
        settings: const AppSettings(instantTranslateAi: false),
      );
      expect(find.text(_heatText), findsNothing);
      expect(conditions.reads, 0);
    });

    testWidgets('uses the app-wide conditions by default', (tester) async {
      await TranslateHarness(state: typed())
          .pump(tester, child: const OnDeviceAiStrainNote());
      // No strain off Android.
      expect(
        find.byKey(const Key('translate_on_device_ai_strain')),
        findsNothing,
      );
    });
  });
}
