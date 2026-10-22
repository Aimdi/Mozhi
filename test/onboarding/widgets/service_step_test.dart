import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/onboarding/onboarding.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/insecure_http_warning.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

void main() {
  setUpAll(registerOnboardingFallbacks);

  Future<MockOnboardingCubit> pump(
    WidgetTester tester, [
    OnboardingState state = const OnboardingState(),
    AppSettings settings = testSettings,
  ]) async {
    tester.setScreenSize(const Size(500, 2000));
    final cubit = createOnboardingCubit(state);
    await tester.pumpOnboarding(
      const ServiceStep(),
      onboarding: cubit,
      settings: createSettings(settings),
    );
    return cubit;
  }

  /// Opens the list of instances behind "Change".
  Future<void> openList(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('onboarding_server_change')));
    await tester.pump();
  }

  group('ServiceStep', () {
    testWidgets('shows the server in use, the list behind "Change"', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);

      expect(find.text('Online translation'), findsOneWidget);
      expect(find.text('Optional'), findsOneWidget);
      expect(find.textContaining('Cloudflare'), findsNothing);
      expect(
        find.textContaining('For languages that aren’t on this device'),
        findsOneWidget,
      );
      expect(find.text('Using Alpha'), findsOneWidget);
      expect(find.text('a.example'), findsOneWidget);
      expect(find.byType(RadioListTile<String>), findsNothing);
      expect(find.text('Change'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const Key('onboarding_server_change'))),
        isSemantics(isButton: true, hasExpandedState: true, isExpanded: false),
      );

      await openList(tester);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('b.example'), findsOneWidget);
      expect(find.text('Charlie'), findsOneWidget);
      final radios = tester
          .widgetList<RadioListTile<String>>(find.byType(RadioListTile<String>))
          .map((tile) => tile.value);
      expect(radios, [instanceA.url, instanceB.url, instanceC.url]);

      await tester.tap(find.text('Done'));
      await tester.pump();
      expect(find.byType(RadioListTile<String>), findsNothing);
      semantics.dispose();
    });

    testWidgets('never measures the servers by itself', (tester) async {
      final cubit = await pump(tester);
      await tester.pumpAndSettle();
      verifyNever(cubit.findFastestInstance);
    });

    testWidgets('without an on-device engine', (tester) async {
      final cubit = await pump(tester, const OnboardingState(onDevice: false));

      // Not optional there: it is how Mozhi translates.
      expect(find.text('Optional'), findsNothing);
      expect(
        find.textContaining('Mozhi translates with a Mozhi server'),
        findsOneWidget,
      );
      final ask = find.byKey(const Key('onboarding_ask_before_sending'));
      expect(ask, findsOneWidget);
      expect(find.text('Ask before sending text'), findsOneWidget);
      // Offline first (the default) asks.
      expect(tester.widget<SwitchListTile>(ask).value, isTrue);
      await tester.tap(ask);
      verify(() => cubit.setAskBeforeSending(ask: false)).called(1);
    });

    testWidgets('the switch is off in Online mode', (tester) async {
      await pump(
        tester,
        const OnboardingState(onDevice: false),
        const AppSettings(
          instances: testInstances,
          privacyMode: PrivacyMode.online,
        ),
      );

      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('onboarding_ask_before_sending')),
            )
            .value,
        isFalse,
      );
    });

    testWidgets('keeps the privacy switch to devices without an engine', (
      tester,
    ) async {
      await pump(tester);
      expect(
        find.byKey(const Key('onboarding_ask_before_sending')),
        findsNothing,
      );
    });

    testWidgets('says that Offline only never contacts the servers', (
      tester,
    ) async {
      await pump(tester);
      const note = Key('onboarding_service_offline_only');
      expect(find.byKey(note), findsNothing);

      await pump(
        tester,
        const OnboardingState(),
        const AppSettings(
          instances: testInstances,
          privacyMode: PrivacyMode.offlineOnly,
        ),
      );
      expect(find.byKey(note), findsOneWidget);
    });

    testWidgets('points to the AI provider settings', (tester) async {
      await pump(tester);
      expect(find.textContaining('AI translators are optional'), findsOne);
      // Without a callback there is no link.
      expect(find.text('Open AI provider settings'), findsNothing);

      var opened = 0;
      tester.setScreenSize(const Size(500, 2000));
      await tester.pumpOnboarding(
        ServiceStep(onOpenAiSettings: () => opened++),
        onboarding: createOnboardingCubit(),
        settings: createSettings(),
      );
      final link = find.text('Open AI provider settings');
      await tester.ensureVisible(link);
      await tester.tap(link);
      expect(opened, 1);
      expect(
        tester.getSize(find.byKey(const Key('onboarding_open_ai_settings'))),
        isA<Size>().having((s) => s.height, 'height', greaterThanOrEqualTo(48)),
      );
    });

    testWidgets('find fastest starts pinging, saying it contacts them', (
      tester,
    ) async {
      final cubit = await pump(tester);
      expect(
        find.text(
          'Contacts every listed server once to measure its speed, then '
          'tries the fastest first.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Find the fastest server'));
      verify(cubit.findFastestInstance).called(1);
    });

    testWidgets('shows live progress while pinging', (tester) async {
      await pump(
        tester,
        OnboardingState(
          serviceStatus: ServiceStatus.pinging,
          pings: {
            instanceA.url: const InstancePing.pending(),
            instanceB.url: const InstancePing.success(
              Duration(milliseconds: 120),
            ),
            instanceC.url: const InstancePing.pending(),
          },
        ),
      );

      expect(find.text('Testing instances…'), findsOneWidget);
      final tile = tester.widget<ListTile>(
        find.byKey(const Key('onboarding_find_fastest')),
      );
      expect(tile.onTap, isNull);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(progress.value, closeTo(1 / 3, 0.001));
      // The server in use is still pending.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await openList(tester);
      expect(find.byType(CircularProgressIndicator), findsNWidgets(3));
      expect(find.text('120 ms'), findsOneWidget);
      expect(find.text('Fastest'), findsNothing);
    });

    testWidgets('shows results with the fastest instance', (tester) async {
      await pump(
        tester,
        OnboardingState(
          serviceStatus: ServiceStatus.done,
          pings: {
            instanceA.url: const InstancePing.success(
              Duration(milliseconds: 90),
            ),
            instanceB.url: const InstancePing.failure('boom'),
            instanceC.url: const InstancePing.timedOut(),
          },
        ),
      );

      expect(find.text('Test again'), findsOneWidget);
      // On the row of the server in use.
      expect(find.text('90 ms'), findsOneWidget);
      expect(find.text('Fastest'), findsOneWidget);
      await openList(tester);
      expect(find.text('90 ms'), findsNWidgets(2));
      expect(find.text('Unreachable'), findsOneWidget);
      expect(find.text('Timed out'), findsOneWidget);
      expect(find.byTooltip('boom'), findsOneWidget);
    });

    testWidgets('colours latencies by speed', (tester) async {
      await pump(
        tester,
        OnboardingState(
          serviceStatus: ServiceStatus.done,
          pings: {
            instanceA.url: const InstancePing.success(
              Duration(milliseconds: 100),
            ),
            instanceB.url: const InstancePing.success(Duration(seconds: 1)),
            instanceC.url: const InstancePing.success(Duration(seconds: 3)),
          },
        ),
      );
      await openList(tester);
      Color colorOf(String text) =>
          tester.widget<Text>(find.text(text).last).style!.color!;
      final colors = {
        colorOf('100 ms'),
        colorOf('1000 ms'),
        colorOf('3000 ms'),
      };
      expect(colors, hasLength(3));
    });

    testWidgets('puts badges below the title on narrow screens', (
      tester,
    ) async {
      final cubit = createOnboardingCubit(
        OnboardingState(
          serviceStatus: ServiceStatus.pinging,
          pings: {
            instanceA.url: const InstancePing.pending(),
            instanceB.url: const InstancePing.success(
              Duration(milliseconds: 40),
            ),
          },
        ),
      );
      tester.setScreenSize(const Size(360, 2000));
      await tester.pumpOnboarding(
        const ServiceStep(),
        onboarding: cubit,
        settings: createSettings(),
      );
      await openList(tester);

      final tiles = tester.widgetList<RadioListTile<String>>(
        find.byType(RadioListTile<String>),
      );
      expect(tiles.every((tile) => tile.secondary == null), isTrue);
      final title = tester.getRect(find.text('b.example'));
      final badge = tester.getRect(find.text('40 ms'));
      expect(badge.top, greaterThan(title.bottom));
      // Alpha's pending ping, on its row and in the list.
      expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
    });

    testWidgets('warns when no instance answered', (tester) async {
      await pump(
        tester,
        OnboardingState(
          serviceStatus: ServiceStatus.done,
          pings: {instanceA.url: const InstancePing.failure('x')},
        ),
      );
      expect(find.textContaining('No instance answered'), findsOneWidget);
    });

    testWidgets('explains an empty instance list', (tester) async {
      await pump(
        tester,
        const OnboardingState(),
        const AppSettings(instances: []),
      );
      expect(find.textContaining('No instances configured'), findsOneWidget);
      expect(find.byType(RadioListTile<String>), findsNothing);
    });

    testWidgets('tapping an instance prefers it', (tester) async {
      final cubit = await pump(tester);
      await openList(tester);
      await tester.tap(find.text('Charlie'));
      verify(() => cubit.selectInstance(instanceC.url)).called(1);
    });

    group('own instance', () {
      testWidgets('tests and adds the entered url', (tester) async {
        final cubit = await pump(tester);
        await tester.enterText(find.byType(TextField), 'mozhi.example.com');
        verify(cubit.ownInstanceChanged).called(1);

        await tester.tap(find.text('Test & add'));
        verify(() => cubit.addOwnInstance('mozhi.example.com')).called(1);

        await tester.showKeyboard(find.byType(TextField));
        await tester.testTextInput.receiveAction(TextInputAction.go);
        verify(() => cubit.addOwnInstance('mozhi.example.com')).called(1);
      });

      group('plain http to a remote host', () {
        const warning = Key('onboarding_insecure_warning');
        const url = 'http://mozhi.example.com';

        testWidgets('shows the warning banner live', (tester) async {
          await pump(tester);
          expect(find.byKey(warning), findsNothing);
          await tester.enterText(find.byType(TextField), url);
          await tester.pump();
          expect(find.byKey(warning), findsOneWidget);
          expect(find.text('Connection not encrypted'), findsOneWidget);
          expect(
            tester.widget(find.byKey(warning)),
            isA<InsecureHttpWarning>(),
          );

          await tester.enterText(
            find.byType(TextField),
            'http://localhost:3000',
          );
          await tester.pump();
          expect(find.byKey(warning), findsNothing);
          await tester.enterText(find.byType(TextField), 'https://x.example');
          await tester.pump();
          expect(find.byKey(warning), findsNothing);
        });

        testWidgets('public plain http is refused: https is required', (
          tester,
        ) async {
          final cubit = await pump(
            tester,
            const OnboardingState(
              ownInstanceStatus: OwnInstanceStatus.failure,
              ownInstanceError: OwnInstanceError.insecure,
            ),
          );
          await tester.enterText(find.byType(TextField), url);
          await tester.pump();
          expect(find.text('Use https:// for public servers.'), findsWidgets);
          await tester.tap(find.text('Test & add'));
          await tester.pumpAndSettle();
          // No confirmation: the cubit refuses it.
          expect(find.text('Add without encryption?'), findsNothing);
          verify(() => cubit.addOwnInstance(url)).called(1);
        });

        testWidgets('local addresses are added without asking', (tester) async {
          final cubit = await pump(tester);
          await tester.enterText(find.byType(TextField), 'http://192.168.1.2');
          await tester.tap(find.text('Test & add'));
          await tester.pumpAndSettle();
          expect(find.text('Add without encryption?'), findsNothing);
          verify(() => cubit.addOwnInstance('http://192.168.1.2')).called(1);
        });
      });

      testWidgets('disables the button while testing', (tester) async {
        await pump(
          tester,
          const OnboardingState(ownInstanceStatus: OwnInstanceStatus.testing),
        );
        final button = tester.widget<ButtonStyleButton>(
          find.ancestor(
            of: find.text('Test & add'),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
        );
        expect(button.onPressed, isNull);
      });

      testWidgets('shows success', (tester) async {
        await pump(
          tester,
          const OnboardingState(
            ownInstanceStatus: OwnInstanceStatus.success,
            ownInstanceLatency: Duration(milliseconds: 77),
          ),
        );
        expect(find.text('Added and selected (77 ms).'), findsOneWidget);
      });

      for (final (error, text) in [
        (OwnInstanceError.empty, 'Enter the address of your instance.'),
        (
          OwnInstanceError.invalidUrl,
          'This does not look like a valid http(s) address.',
        ),
        (OwnInstanceError.unreachable, 'Could not reach this instance: nope'),
        (
          OwnInstanceError.timedOut,
          'Could not reach this instance: it took too long to answer.',
        ),
        (OwnInstanceError.insecure, 'Use https:// for public servers.'),
      ]) {
        testWidgets('shows ${error.name} errors', (tester) async {
          await pump(
            tester,
            OnboardingState(
              ownInstanceStatus: OwnInstanceStatus.failure,
              ownInstanceError: error,
              ownInstanceMessage: 'nope',
            ),
          );
          expect(find.text(text), findsOneWidget);
        });
      }
    });
  });
}
