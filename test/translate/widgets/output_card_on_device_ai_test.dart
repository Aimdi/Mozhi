import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

/// Qwen3 on this device, writing the extras.
const qwen = TranslationEngine(
  id: 'ai:device-qwen3-1.7b-q4',
  kind: EngineKind.ai,
  name: 'Qwen3 1.7B (on this device)',
  providerId: 'device-qwen3-1.7b-q4',
  isLocal: true,
  onDevice: true,
  promptProfile: PromptProfile.general,
);

class _FakeConditions extends Fake implements DeviceConditions {
  new(this.snapshot);

  final DeviceConditionsSnapshot snapshot;

  @override
  DeviceConditionsSnapshot get latest => snapshot;
}

void main() {
  setUpAll(registerTranslateFallbacks);

  /// Insights on, then an instant translation of new text arrives.
  Future<TranslateHarness> typeOn(
    WidgetTester tester,
    DeviceConditionsSnapshot conditions,
  ) async {
    final previous = DeviceConditions.instance;
    DeviceConditions.instance = _FakeConditions(conditions);
    addTearDown(() => DeviceConditions.instance = previous);
    final controller = StreamController<TranslateState>.broadcast();
    addTearDown(controller.close);
    final harness = TranslateHarness(
      state: translatedState(assistEngine: qwen)
          .copyWith(insightsStatus: ExtraStatus.ready),
    );
    when(() => harness.translate.stream).thenAnswer((_) => controller.stream);
    await harness.pump(tester, child: const OutputCard(), more: true);
    await tester.tap(find.byKey(const Key('translate_insights_button')));
    await tester.pump();
    controller.add(
      translatedState(
        assistEngine: qwen,
        input: 'Hello there',
      ).copyWith(instantResult: true),
    );
    await tester.pump();
    return harness;
  }

  group('extras of an on-device assistant after typing', () {
    testWidgets('reload while the phone is fine', (tester) async {
      final harness = await typeOn(tester, DeviceConditionsSnapshot.unknown);
      verify(harness.translate.loadInsights).called(1);
    });

    for (final (name, conditions) in [
      ('hot', const DeviceConditionsSnapshot(thermal: ThermalStatus.severe)),
      ('saving battery', const DeviceConditionsSnapshot(powerSave: true)),
    ]) {
      testWidgets('turn off while the phone is $name', (tester) async {
        final harness = await typeOn(tester, conditions);
        verifyNever(harness.translate.loadInsights);
      });
    }
  });
}
