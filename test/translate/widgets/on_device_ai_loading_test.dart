import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_on_device_ai.dart';
import '../helpers/helpers.dart';

const hyMt = TranslationEngine(
  id: 'ai:device-hy-mt2-1.8b-q4',
  kind: EngineKind.ai,
  name: 'Hy-MT2 1.8B (on this device)',
  providerId: 'device-hy-mt2-1.8b-q4',
  isLocal: true,
  onDevice: true,
  promptProfile: PromptProfile.hunyuanMt,
);

const _loadingText = 'Loading the on-device model…';

void main() {
  setUpAll(registerTranslateFallbacks);

  late FakeOnDeviceAi ai;

  setUp(() {
    ai = FakeOnDeviceAi(FakeOnDeviceModels(testCatalog));
    addTearDown(ai.close);
  });

  TranslateState pending({TranslationEngine engine = hyMt}) => readyState(
    engine: engine,
    input: 'Hallo',
    source: german,
  ).copyWith(status: TranslateStatus.translating);

  Future<TranslateHarness> pump(
    WidgetTester tester, {
    TranslateState? state,
    Widget child = const OutputCard(),
    bool disableAnimations = false,
    bool provided = true,
  }) async {
    final harness = TranslateHarness(state: state ?? pending());
    when(harness.translate.stopTranslation).thenReturn(null);
    await harness.pump(
      tester,
      child: provided
          ? RepositoryProvider<OnDeviceAi>.value(value: ai, child: child)
          : child,
      disableAnimations: disableAnimations,
    );
    return harness;
  }

  testWidgets('says the model is loading, with Cancel', (tester) async {
    ai.currentStatus = const OnDeviceAiLoading('hy-mt2-1.8b-q4');
    final harness = await pump(tester);
    expect(find.text(_loadingText), findsOneWidget);
    expect(
      find.text('The first translation after a pause takes a few seconds.'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // The placeholder lines stay below it.
    expect(find.byKey(const Key('translate_output_skeleton')), findsOne);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));

    await tester.tap(find.text('Cancel'));
    verify(harness.translate.stopTranslation).called(1);
  });

  testWidgets('follows the status: then the text streams as usual', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text(_loadingText), findsNothing);

    ai.report(const OnDeviceAiLoading('hy-mt2-1.8b-q4'));
    await tester.pump();
    expect(find.text(_loadingText), findsOneWidget);

    ai.report(const OnDeviceAiGenerating('hy-mt2-1.8b-q4'));
    await tester.pump();
    expect(find.text(_loadingText), findsNothing);
    expect(find.byKey(const Key('translate_output_skeleton')), findsOne);
  });

  testWidgets('keeps still with reduced motion', (tester) async {
    ai.currentStatus = const OnDeviceAiLoading('hy-mt2-1.8b-q4');
    await pump(tester, disableAnimations: true);
    expect(find.text(_loadingText), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.memory), findsOneWidget);
  });

  testWidgets('is a polite live region', (tester) async {
    ai.currentStatus = const OnDeviceAiLoading('hy-mt2-1.8b-q4');
    await pump(tester, child: OnDeviceAiLoadingNotice(ai: ai), provided: false);
    final semantics = tester.getSemantics(find.text(_loadingText));
    expect(semantics.flagsCollection.isLiveRegion, isTrue);
  });

  testWidgets('is only shown for on-device AI', (tester) async {
    ai.currentStatus = const OnDeviceAiLoading('qwen3-1.7b-q4');
    await pump(tester, state: pending(engine: claude));
    expect(find.text(_loadingText), findsNothing);
  });

  testWidgets('shows nothing without on-device AI', (tester) async {
    await pump(tester, provided: false);
    expect(find.text(_loadingText), findsNothing);
    expect(find.byKey(const Key('translate_output_skeleton')), findsOne);
  });

  group('for the AI extras', () {
    const extraHint = 'The first request after a pause takes a few seconds.';

    testWidgets('shows above an extra that waits for the model', (
      tester,
    ) async {
      ai.currentStatus = const OnDeviceAiLoading('qwen3-1.7b-q4');
      await pump(
        tester,
        child: const OnDeviceAiExtraLoading(
          engine: hyMt,
          child: LinearProgressIndicator(key: Key('extra_progress')),
        ),
      );
      expect(find.text(_loadingText), findsOneWidget);
      expect(find.text(extraHint), findsOneWidget);
      expect(find.byKey(const Key('extra_progress')), findsOneWidget);
      // No Cancel without one.
      expect(find.text('Cancel'), findsNothing);
      final semantics = tester.getSemantics(find.text(_loadingText));
      expect(semantics.flagsCollection.isLiveRegion, isTrue);

      ai.report(const OnDeviceAiGenerating('qwen3-1.7b-q4'));
      await tester.pump();
      expect(find.text(_loadingText), findsNothing);
      expect(find.byKey(const Key('extra_progress')), findsOneWidget);
    });

    testWidgets('only for an extra on on-device AI', (tester) async {
      ai.currentStatus = const OnDeviceAiLoading('qwen3-1.7b-q4');
      await pump(
        tester,
        child: const Column(
          children: [
            OnDeviceAiExtraLoading(engine: claude, child: Text('cloud')),
            OnDeviceAiExtraLoading(engine: null, child: Text('none')),
          ],
        ),
      );
      expect(find.text(_loadingText), findsNothing);
      expect(find.text('cloud'), findsOneWidget);
      expect(find.text('none'), findsOneWidget);
    });

    testWidgets('can cancel and say something else', (tester) async {
      ai.currentStatus = const OnDeviceAiLoading('qwen3-1.7b-q4');
      var cancelled = 0;
      await pump(
        tester,
        child: OnDeviceAiLoadingNotice.extra(
          ai: ai,
          hint: 'Wait a moment.',
          onCancel: () => cancelled++,
        ),
        provided: false,
      );
      expect(find.text('Wait a moment.'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('on_device_ai_extra_loading_cancel')),
      );
      expect(cancelled, 1);
    });

    testWidgets('a refinement of the shown translation says so', (
      tester,
    ) async {
      ai.currentStatus = const OnDeviceAiLoading('hy-mt2-1.8b-q4');
      final shown = readyState(
        engine: hyMt,
        input: 'Hallo',
        source: german,
        result: const TranslationResult(
          engineId: 'ai:device-hy-mt2-1.8b-q4',
          engineName: 'Hy-MT2',
          text: 'Hello',
        ),
      );
      await pump(
        tester,
        state: shown.copyWith(status: TranslateStatus.translating),
      );
      expect(find.text(_loadingText), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
    });
  });

  testWidgets('a long text waiting between its parts says so', (
    tester,
  ) async {
    ai.currentStatus = const OnDeviceAiPaused(
      'hy-mt2-1.8b-q4',
      DeviceStrain.heat,
    );
    final streaming = readyState(
      engine: hyMt,
      input: 'Hallo',
      source: german,
      result: const TranslationResult(
        engineId: 'ai:device-hy-mt2-1.8b-q4',
        engineName: 'Hy-MT2',
        text: 'Hello',
        isComplete: false,
      ),
    ).copyWith(status: TranslateStatus.translating);
    final harness = await pump(tester, state: streaming);
    expect(find.text('Paused while the phone cools down'), findsOneWidget);
    await tester.tap(find.text('Continue anyway'));
    expect(ai.continued, 1);
    await tester.tap(find.byKey(const Key('on_device_ai_paused_cancel')));
    verify(harness.translate.stopTranslation).called(1);
  });
}
