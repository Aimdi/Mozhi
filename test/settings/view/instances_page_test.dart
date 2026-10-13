import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/instances_page.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

import 'helpers.dart';

const _fast = MozhiInstance(url: 'https://fast.example.com', label: 'Fast');
const _slow = MozhiInstance(url: 'https://slow.example.com');
const _down = MozhiInstance(url: 'https://down.example.com');

void main() {
  setUpAll(registerFallbacks);

  group('InstancesPage', () {
    late MockSettingsCubit settings;
    late MockTranslationRepository repository;

    setUp(() {
      settings = createSettingsCubit(
        const AppSettings(instances: [_fast, _slow, _down]),
      );
      repository = MockTranslationRepository();
      when(() => repository.pingInstance(_fast))
          .thenAnswer((_) async => const Duration(milliseconds: 120));
      when(() => repository.pingInstance(_slow))
          .thenAnswer((_) async => const Duration(milliseconds: 900));
      when(() => repository.pingInstance(_down))
          .thenThrow(const MozhiApiException('timeout'));
    });

    Future<void> pump(
      WidgetTester tester, {
      Size size = const Size(800, 1600),
      double textScale = 1,
    }) async {
      tester.setScreenSize(size);
      await tester.pumpView(
        const InstancesPage(),
        settings: settings,
        repository: repository,
        textScale: textScale,
      );
      await tester.pumpAndSettle();
    }

    Future<void> openMenu(WidgetTester tester, int index) async {
      await tester.tap(find.byTooltip('More options').at(index));
      await tester.pumpAndSettle();
    }

    testWidgets('renders instances with the preferred one first', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Mozhi instances'), findsOneWidget);
      expect(find.text('Fast'), findsOneWidget);
      expect(find.text('fast.example.com'), findsOneWidget);
      expect(find.text('slow.example.com'), findsOneWidget);
      expect(find.text('Preferred'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Preferred')).dy,
        lessThan(tester.getTopLeft(find.text('slow.example.com')).dy),
      );
      expect(find.text('What is Mozhi?'), findsOneWidget);
      expect(find.textContaining('Self-hosting'), findsOneWidget);
    });

    testWidgets('pings every instance and shows latency badges', (
      tester,
    ) async {
      await pump(tester);
      verify(() => repository.pingInstance(_fast)).called(1);
      verify(() => repository.pingInstance(_slow)).called(1);
      verify(() => repository.pingInstance(_down)).called(1);

      final colors = Theme.of(tester.element(find.text('Fast'))).colorScheme;
      StatusBadge badge(String label) => tester.widget<StatusBadge>(
        find.ancestor(of: find.text(label), matching: find.byType(StatusBadge)),
      );
      expect(badge('120 ms').color, colors.success);
      expect(badge('900 ms').color, colors.warning);
      expect(badge('Offline').color, colors.error);
    });

    testWidgets('marks very slow instances red', (tester) async {
      when(() => repository.pingInstance(_slow))
          .thenAnswer((_) async => const Duration(milliseconds: 2400));
      await pump(tester);
      final colors = Theme.of(tester.element(find.text('Fast'))).colorScheme;
      final badge = tester.widget<StatusBadge>(
        find.ancestor(
          of: find.text('2400 ms'),
          matching: find.byType(StatusBadge),
        ),
      );
      expect(badge.color, colors.error);
    });

    testWidgets('shows checking while a ping is in flight', (tester) async {
      final completer = Completer<Duration>();
      when(() => repository.pingInstance(_fast))
          .thenAnswer((_) => completer.future);
      tester.setScreenSize(const Size(800, 1600));
      await tester.pumpView(
        const InstancesPage(),
        settings: settings,
        repository: repository,
      );
      await tester.pump();
      expect(find.text('Checking…'), findsOneWidget);
      completer.complete(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.text('50 ms'), findsOneWidget);
    });

    testWidgets('pull to refresh pings again', (tester) async {
      await pump(tester);
      await tester.fling(
        find.text('What is Mozhi?'),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      verify(() => repository.pingInstance(_fast)).called(2);
    });

    testWidgets('refresh button pings again without a drag', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Check latency again'));
      await tester.pump();
      expect(find.text('Checking…'), findsNWidgets(3));
      await tester.pumpAndSettle();
      verify(() => repository.pingInstance(_fast)).called(2);
      verify(() => repository.pingInstance(_down)).called(2);
      expect(find.text('120 ms'), findsOneWidget);
    });

    testWidgets('refresh button is disabled without instances', (tester) async {
      when(() => settings.state).thenReturn(const AppSettings(instances: []));
      await pump(tester);
      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.refresh),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('announces how many instances are reachable once', (
      tester,
    ) async {
      await pump(tester);
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('2 of 3 instances reachable'),
      ]);
      await tester.tap(find.byTooltip('Check latency again'));
      await tester.pumpAndSettle();
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('2 of 3 instances reachable'),
      ]);
    });

    testWidgets('latency levels differ by icon and spoken word', (
      tester,
    ) async {
      when(() => repository.pingInstance(_down))
          .thenAnswer((_) async => const Duration(milliseconds: 2400));
      final handle = tester.ensureSemantics();
      await pump(tester);
      Finder icon(String label, IconData icon) => find.descendant(
        of: find.ancestor(
          of: find.text(label),
          matching: find.byType(StatusBadge),
        ),
        matching: find.byIcon(icon),
      );
      expect(icon('120 ms', Icons.speed), findsOneWidget);
      expect(icon('900 ms', Icons.timelapse), findsOneWidget);
      expect(icon('2400 ms', Icons.hourglass_bottom), findsOneWidget);
      expect(find.semantics.byLabel(RegExp('120 ms, fast')), findsOne);
      expect(find.semantics.byLabel(RegExp('900 ms, moderate')), findsOne);
      expect(find.semantics.byLabel(RegExp('2400 ms, slow')), findsOne);
      handle.dispose();
    });

    testWidgets('outlines the preferred instance instead of tinting it', (
      tester,
    ) async {
      await pump(tester);
      final colors = Theme.of(tester.element(find.text('Fast'))).colorScheme;
      Card card(String text) => tester.widget<Card>(
        find.ancestor(of: find.text(text), matching: find.byType(Card)).first,
      );
      final preferred = card('Fast');
      final other = card('slow.example.com');
      expect(preferred.color, colors.surfaceContainerLow);
      expect(other.color, colors.surfaceContainerLow);
      final side = (preferred.shape! as RoundedRectangleBorder).side;
      expect(side.color, colors.primary);
      expect(side.width, 2);
      expect((other.shape! as RoundedRectangleBorder).side, BorderSide.none);
    });

    testWidgets('pings instances added later', (tester) async {
      const added = MozhiInstance(url: 'https://new.example.com');
      when(() => repository.pingInstance(added))
          .thenAnswer((_) async => const Duration(milliseconds: 10));
      whenListen(
        settings,
        Stream.value(
          const AppSettings(instances: [_fast, _slow, _down, added]),
        ),
        initialState: const AppSettings(instances: [_fast, _slow, _down]),
      );
      await pump(tester);
      verify(() => repository.pingInstance(added)).called(1);
    });

    testWidgets('opens the Mozhi project page', (tester) async {
      final opened = <Uri>[];
      final original = LinkLauncher.launcher;
      LinkLauncher.launcher = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => LinkLauncher.launcher = original);
      await pump(tester);
      await tester.tap(find.text('Mozhi on Codeberg'));
      await tester.pump();
      expect(opened, [Uri.parse('https://codeberg.org/aryak/mozhi')]);
    });

    testWidgets('reports links that cannot be opened', (tester) async {
      final original = LinkLauncher.launcher;
      LinkLauncher.launcher = (uri) async => false;
      addTearDown(() => LinkLauncher.launcher = original);
      await pump(tester);
      await tester.tap(find.text('Mozhi on Codeberg'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't open the link"), findsOneWidget);
    });

    group('menu', () {
      testWidgets('makes an instance preferred', (tester) async {
        await pump(tester);
        await openMenu(tester, 1);
        await tester.tap(find.text('Make preferred'));
        await tester.pumpAndSettle();
        verify(() => settings.preferInstance(_slow.url)).called(1);
      });

      testWidgets('moves an instance down', (tester) async {
        await pump(tester);
        await openMenu(tester, 0);
        await tester.tap(find.text('Move down'));
        await tester.pumpAndSettle();
        // onReorder semantics: insertion index before removal.
        verify(() => settings.moveInstance(0, 2)).called(1);
      });

      testWidgets('moves an instance up', (tester) async {
        await pump(tester);
        await openMenu(tester, 2);
        await tester.tap(find.text('Move up'));
        await tester.pumpAndSettle();
        verify(() => settings.moveInstance(2, 1)).called(1);
      });

      testWidgets('removes an instance with undo', (tester) async {
        await pump(tester);
        await openMenu(tester, 1);
        await tester.tap(find.text('Remove'));
        await tester.pumpAndSettle();
        verify(() => settings.removeInstance(_slow.url)).called(1);
        expect(find.text('Instance removed'), findsOneWidget);
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        verify(() => settings.addInstance(_slow)).called(1);
        verify(() => settings.moveInstance(2, 1)).called(1);
      });
    });

    testWidgets('reorders by dragging the handle', (tester) async {
      await pump(tester);
      final handle = find.byIcon(Icons.drag_indicator).first;
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 100));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      final captured = verify(() => settings.moveInstance(0, captureAny()))
          .captured;
      expect(captured.single as int, greaterThanOrEqualTo(2));
    });

    group('reset', () {
      testWidgets('restores the public list after confirmation', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(find.byTooltip('Reset to public list'));
        await tester.pumpAndSettle();
        expect(find.text('Reset instances?'), findsOneWidget);
        await tester.tap(find.text('Reset'));
        await tester.pumpAndSettle();
        verify(settings.resetInstances).called(1);
      });

      testWidgets('cancel keeps the list', (tester) async {
        await pump(tester);
        await tester.tap(find.byTooltip('Reset to public list'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verifyNever(settings.resetInstances);
      });

      testWidgets('empty list offers a reset', (tester) async {
        when(() => settings.state).thenReturn(const AppSettings(instances: []));
        await pump(tester);
        expect(find.text('No instances yet'), findsOneWidget);
        await tester.tap(
          find.widgetWithText(FilledButton, 'Reset to public list'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Reset'));
        await tester.pumpAndSettle();
        verify(settings.resetInstances).called(1);
      });
    });

    group('add instance', () {
      Future<void> openDialog(WidgetTester tester) async {
        await pump(tester);
        await tester.tap(find.text('Add instance'));
        await tester.pumpAndSettle();
      }

      Finder field(String label) => find.widgetWithText(TextFormField, label);

      testWidgets('validates the URL', (tester) async {
        await openDialog(tester);
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(
          find.text('Enter a valid URL, such as https://mozhi.example.com'),
          findsOneWidget,
        );

        await tester.enterText(field('Instance URL'), 'ftp://example.com');
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(
          find.text('Enter a valid URL, such as https://mozhi.example.com'),
          findsOneWidget,
        );
        verifyNever(() => settings.addInstance(any()));
      });

      testWidgets('rejects credentials in the URL and refocuses it', (
        tester,
      ) async {
        await openDialog(tester);
        await tester.enterText(
          field('Instance URL'),
          'https://me:secret@mozhi.example.com',
        );
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Remove the user name and password'),
          findsOneWidget,
        );
        final editable = tester.widget<EditableText>(
          find.descendant(
            of: field('Instance URL'),
            matching: find.byType(EditableText),
          ),
        );
        expect(editable.focusNode.hasFocus, isTrue);

        // Also without a scheme.
        await tester.enterText(field('Instance URL'), 'me@mozhi.example.com');
        await tester.tap(find.text('Test'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Remove the user name and password'),
          findsOneWidget,
        );
        verifyNever(() => settings.addInstance(any()));
        // Only the three initial pings; the test button sent nothing.
        verify(() => repository.pingInstance(any())).called(3);
      });

      testWidgets('rejects query strings in the URL', (tester) async {
        await openDialog(tester);
        await tester.enterText(
          field('Instance URL'),
          'https://mozhi.example.com/?token=abc',
        );
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Remove the part after “?”'), findsOne);
        verifyNever(() => settings.addInstance(any()));
      });

      testWidgets('rejects duplicates', (tester) async {
        await openDialog(tester);
        await tester.enterText(field('Instance URL'), 'fast.example.com/');
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(
          find.text('This instance is already in your list'),
          findsOneWidget,
        );
      });

      testWidgets('adds a normalised instance with a label', (tester) async {
        await openDialog(tester);
        await tester.enterText(field('Instance URL'), ' mozhi.home.net/api ');
        await tester.enterText(field('Label (optional)'), 'Home');
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        final added =
            verify(() => settings.addInstance(captureAny())).captured.single
                as MozhiInstance;
        expect(added.url, 'https://mozhi.home.net');
        expect(added.label, 'Home');
        expect(added.isCustom, isTrue);
        expect(find.text('Instance added'), findsOneWidget);
      });

      testWidgets('tests reachability before saving', (tester) async {
        when(
          () => repository.pingInstance(
            const MozhiInstance(url: 'https://ok.example.com'),
          ),
        ).thenAnswer((_) async => const Duration(milliseconds: 42));
        await openDialog(tester);
        await tester.enterText(field('Instance URL'), 'ok.example.com');
        final handle = tester.ensureSemantics();
        await tester.tap(find.text('Test'));
        await tester.pump();
        expect(find.semantics.byLabel(RegExp('Testing instance…')), findsOne);
        await tester.pumpAndSettle();
        expect(find.text('Reachable in 42 ms'), findsOneWidget);
        expect(
          tester.getSemantics(find.text('Reachable in 42 ms')),
          isSemantics(label: 'Reachable in 42 ms', isLiveRegion: true),
        );
        // Only the icon is green; the text keeps full contrast on the
        // dialog surface.
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text('Reachable in 42 ms'),
        );
        final colors = Theme.of(tester.element(find.text('Reachable in 42 ms')))
            .colorScheme;
        expect(
          contrastRatio(
            paragraph.text.style!.color!,
            colors.surfaceContainerHigh,
          ),
          greaterThanOrEqualTo(7),
        );
        verifyNever(() => settings.addInstance(any()));
        handle.dispose();
      });

      testWidgets('shows test failures', (tester) async {
        when(
          () => repository.pingInstance(
            const MozhiInstance(url: 'https://bad.example.com'),
          ),
        ).thenThrow(const MozhiApiException('Connection refused'));
        await openDialog(tester);
        await tester.enterText(field('Instance URL'), 'bad.example.com');
        await tester.tap(find.text('Test'));
        await tester.pumpAndSettle();
        expect(
          find.text("Couldn't reach this instance: Connection refused"),
          findsOneWidget,
        );
      });

      testWidgets('cancel adds nothing', (tester) async {
        await openDialog(tester);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verifyNever(() => settings.addInstance(any()));
      });
    });

    testWidgets('fits 320dp with large text', (tester) async {
      await pump(tester, size: const Size(320, 900), textScale: 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('centers content on wide screens', (tester) async {
      await pump(tester, size: const Size(1400, 1000));
      expect(
        tester.getTopLeft(find.text('What is Mozhi?')).dx,
        greaterThan(300),
      );
    });
  });
}
