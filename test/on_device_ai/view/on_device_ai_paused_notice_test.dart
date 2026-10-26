import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/on_device_ai/view/on_device_ai_paused_notice.dart';
import 'package:mozhi/platform/device_conditions.dart';

import '../../helpers/helpers.dart';
import '../../translate/helpers/fake_on_device_ai.dart';

const _heat = 'Paused while the phone cools down';
const _saver = 'Paused while battery saver is on';

void main() {
  late FakeOnDeviceAi ai;

  setUp(() {
    ai = FakeOnDeviceAi(FakeOnDeviceModels(testCatalog));
    addTearDown(ai.close);
  });

  testWidgets('says why a long job waits, and lets it go on', (tester) async {
    var cancelled = 0;
    await tester.pumpApp(
      Scaffold(
        body: OnDeviceAiPausedNotice(ai: ai, onCancel: () => cancelled++),
      ),
    );
    expect(find.text(_heat), findsNothing);

    ai.report(const OnDeviceAiPaused('hy', DeviceStrain.heat));
    await tester.pump();
    expect(find.text(_heat), findsOneWidget);
    expect(
      find.text('The rest is translated part by part once it is ready.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.thermostat_outlined), findsOneWidget);
    final semantics = tester.getSemantics(find.text(_heat));
    expect(semantics.flagsCollection.isLiveRegion, isTrue);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));

    await tester.tap(find.text('Continue anyway'));
    expect(ai.continued, 1);
    await tester.tap(find.text('Cancel'));
    expect(cancelled, 1);

    ai.report(const OnDeviceAiPaused('hy', DeviceStrain.batterySaver));
    await tester.pump();
    expect(find.text(_saver), findsOneWidget);
    expect(find.byIcon(Icons.battery_saver_outlined), findsOneWidget);

    ai.report(const OnDeviceAiGenerating('hy'));
    await tester.pump();
    expect(find.text(_saver), findsNothing);
  });

  testWidgets("reads the app's on-device AI, without Cancel", (tester) async {
    ai.currentStatus = const OnDeviceAiPaused('hy', DeviceStrain.heat);
    await tester.pumpApp(
      RepositoryProvider<OnDeviceAi>.value(
        value: ai,
        child: const Scaffold(body: OnDeviceAiPausedNotice()),
      ),
    );
    expect(find.text(_heat), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('shows nothing without on-device AI', (tester) async {
    await tester.pumpApp(const Scaffold(body: OnDeviceAiPausedNotice()));
    expect(find.byKey(const Key('on_device_ai_paused')), findsNothing);
  });
}
