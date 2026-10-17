import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/network/network.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/instances_page.dart';
import 'package:mozhi/settings/view/widgets/add_instance_dialog.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi_api/mozhi_api.dart' show MozhiPublicInstance;
import 'package:translation_repository/translation_repository.dart';

import 'helpers.dart';

const _fast = MozhiInstance(url: 'https://fast.example.com', label: 'Fast');
const _slow = MozhiInstance(url: 'https://slow.example.com');
const _down = MozhiInstance(url: 'https://down.example.com');

InstanceOnline _online(int ms, {int engines = 2}) => InstanceOnline(
  latency: Duration(milliseconds: ms),
  engines: {for (var i = 0; i < engines; i++) 'engine$i': 'Engine $i'},
);

/// A checker whose answers the test decides.
class _FakeChecker implements MozhiInstanceChecker {
  @override
  final Map<String, InstanceHealth> results = {};

  /// What [check] answers per URL (offline when missing).
  final Map<String, FutureOr<InstanceHealth>> answers = {};
  final List<String> checked = [];

  /// What [test] does.
  FutureOr<InstanceTestResult> Function(String url) onTest = (_) =>
      throw StateError('not stubbed');
  final List<String> tested = [];

  final _changes = StreamController<void>.broadcast();

  void put(String url, InstanceHealth health) {
    results[url] = health;
    _changes.add(null);
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  InstanceHealth? resultFor(String url) => results[url];

  @override
  Future<InstanceHealth> check(String url) async {
    checked.add(url);
    put(url, const InstanceChecking());
    final health = await (answers[url] ?? const InstanceOffline('down'));
    put(url, health);
    return health;
  }

  @override
  Future<void> checkAll(Iterable<String> urls) async {
    await Future.wait(urls.map(check));
  }

  @override
  Future<InstanceTestResult> test(String url) async {
    tested.add(url);
    return await onTest(url);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(registerFallbacks);

  group('InstancesPage', () {
    late MockSettingsCubit settings;
    late _FakeChecker checker;

    setUp(() {
      settings = createSettingsCubit(
        const AppSettings(instances: [_fast, _slow, _down]),
      );
      checker = _FakeChecker()
        ..answers.addAll({
          _fast.url: _online(120),
          _slow.url: _online(900),
          _down.url: const InstanceOffline(MozhiApiException('timeout')),
        });
    });

    Future<void> pump(
      WidgetTester tester, {
      Size size = const Size(800, 1600),
      double textScale = 1,
      List<MozhiPublicInstance> catalog = const [],
      bool proxyActive = false,
    }) async {
      tester.setScreenSize(size);
      await tester.pumpView(
        InstancesPage(
          checker: checker,
          catalog: catalog,
          proxyActive: proxyActive,
        ),
        settings: settings,
        textScale: textScale,
      );
      await tester.pumpAndSettle();
    }

    Future<void> openMenu(WidgetTester tester, int index) async {
      await tester.tap(find.byTooltip('More options').at(index));
      await tester.pumpAndSettle();
    }

    StatusBadge badge(WidgetTester tester, String label) =>
        tester.widget<StatusBadge>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(StatusBadge),
          ),
        );

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
      expect(
        find.textContaining('only contacted when you check or test'),
        findsOneWidget,
      );
    });

    testWidgets('contacts no instance when it opens', (tester) async {
      await pump(tester);

      expect(checker.checked, isEmpty);
      expect(find.text('Checking…'), findsNothing);
      expect(find.text('Offline'), findsNothing);
      expect(find.byType(LatencyBadge), findsNothing);
    });

    testWidgets('shows the results of earlier checks this session', (
      tester,
    ) async {
      checker.results[_fast.url] = _online(120);
      await pump(tester);

      expect(find.text('120 ms'), findsOneWidget);
      expect(checker.checked, isEmpty);
    });

    testWidgets('checks every instance on request', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Check instances'));
      await tester.pumpAndSettle();

      expect(checker.checked, [_fast.url, _slow.url, _down.url]);
      final colors = Theme.of(tester.element(find.text('Fast'))).colorScheme;
      expect(badge(tester, '120 ms').color, colors.success);
      expect(badge(tester, '900 ms').color, colors.warning);
      expect(badge(tester, 'Offline').color, colors.error);
      expect(find.text('2 engines'), findsNWidgets(2));
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('2 of 3 instances reachable'),
      ]);
    });

    testWidgets('shows progress while checking', (tester) async {
      final answer = Completer<InstanceHealth>();
      checker.answers[_fast.url] = answer.future;
      await pump(tester);

      await tester.tap(find.byTooltip('Check instances'));
      await tester.pump();

      expect(find.text('Checking…'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.network_check),
      );
      expect(button.onPressed, isNull);

      answer.complete(_online(50));
      await tester.pumpAndSettle();
      expect(find.text('50 ms'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('pull to refresh checks too', (tester) async {
      await pump(tester);
      await tester.fling(
        find.text('What is Mozhi?'),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(checker.checked, hasLength(3));
    });

    testWidgets('a second request while checking does nothing', (tester) async {
      final answer = Completer<InstanceHealth>();
      checker.answers[_fast.url] = answer.future;
      await pump(tester);
      await tester.tap(find.byTooltip('Check instances'));
      await tester.pump();

      await tester.fling(
        find.text('What is Mozhi?'),
        const Offset(0, 400),
        1000,
      );
      await tester.pump(const Duration(seconds: 1));
      answer.complete(_online(1));
      await tester.pumpAndSettle();

      expect(checker.checked, hasLength(3));
    });

    testWidgets('the check button is disabled without instances', (
      tester,
    ) async {
      when(() => settings.state).thenReturn(const AppSettings(instances: []));
      await pump(tester);
      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.network_check),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('updates when a result changes elsewhere', (tester) async {
      await pump(tester);

      checker.put(_slow.url, _online(30, engines: 0));
      await tester.pumpAndSettle();

      expect(find.text('30 ms'), findsOneWidget);
      final colors = Theme.of(tester.element(find.text('Fast'))).colorScheme;
      expect(badge(tester, 'No engines').color, colors.error);
    });

    testWidgets('latency levels differ by icon and spoken word', (
      tester,
    ) async {
      checker.results.addAll({
        _fast.url: _online(120),
        _slow.url: _online(900),
        _down.url: _online(2400, engines: 1),
      });
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
      expect(find.text('1 engine'), findsOneWidget);
      expect(find.semantics.byLabel(RegExp('120 ms, fast')), findsOne);
      expect(find.semantics.byLabel(RegExp('900 ms, moderate')), findsOne);
      expect(find.semantics.byLabel(RegExp('2400 ms, slow')), findsOne);
      handle.dispose();
    });

    testWidgets('explains instances the network policy refused', (
      tester,
    ) async {
      checker.results.addAll({
        _fast.url: const InstanceOffline(
          MozhiApiException(ProxyRequiredException.defaultMessage),
        ),
        _slow.url: const InstanceOffline(
          MozhiApiException(CleartextRefusedException.defaultMessage),
        ),
      });
      await pump(tester);

      expect(find.text('Needs a proxy'), findsOneWidget);
      expect(find.text('Needs https'), findsOneWidget);
    });

    group('special addresses', () {
      const onion = MozhiInstance(url: 'http://abc.onion');
      const i2p = MozhiInstance(url: 'http://abc.b32.i2p');
      const plain = MozhiInstance(url: 'http://mozhi.example.com');

      setUp(() {
        when(() => settings.state)
            .thenReturn(const AppSettings(instances: [onion, i2p, plain]));
        checker.results[onion.url] = _online(10);
      });

      testWidgets('Tor and I2P need an active proxy', (tester) async {
        await pump(tester);

        expect(find.text('Tor'), findsOneWidget);
        expect(find.text('I2P'), findsOneWidget);
        expect(find.text('Needs a proxy'), findsNWidgets(2));
        // The check result does not hide that the proxy is missing.
        expect(find.text('10 ms'), findsNothing);
      });

      testWidgets('with a proxy they show their results', (tester) async {
        await pump(tester, proxyActive: true);

        expect(find.text('Needs a proxy'), findsNothing);
        expect(find.text('10 ms'), findsOneWidget);
      });

      testWidgets('plain http to a public host needs https', (tester) async {
        await pump(tester, proxyActive: true);

        expect(find.text('Needs https'), findsOneWidget);
      });
    });

    testWidgets('marks instances behind Cloudflare', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        catalog: [MozhiPublicInstance(url: _slow.url, cloudflare: true)],
      );

      expect(find.byType(CloudflareBadge), findsOneWidget);
      expect(
        find.semantics.byLabel(RegExp('Cloudflare, which can read')),
        findsOne,
      );
      handle.dispose();
    });

    testWidgets('NetworkBadge shows nothing for ordinary hosts', (
      tester,
    ) async {
      await tester.pumpView(const NetworkBadge(host: 'mozhi.example.com'));
      expect(find.byType(StatusBadge), findsNothing);
    });

    testWidgets('draws flat hairline cards and outlines the preferred one', (
      tester,
    ) async {
      await pump(tester);
      final colors = Theme.of(tester.element(find.text('Fast'))).colorScheme;
      Card card(String text) => tester.widget<Card>(
        find.ancestor(of: find.text(text), matching: find.byType(Card)).first,
      );
      final preferred = card('Fast');
      final other = card('slow.example.com');
      expect(preferred.color, colors.surface);
      expect(other.color, colors.surface);
      final side = (preferred.shape! as RoundedRectangleBorder).side;
      expect(side.color, colors.primary);
      expect(side.width, 2);
      expect(
        (other.shape! as RoundedRectangleBorder).side,
        BorderSide(
          color: AppPalette.of(tester.element(find.text('Fast'))).hairline,
        ),
      );
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

    testWidgets('uses the session checker by default', (tester) async {
      tester.setScreenSize(const Size(800, 1600));
      await tester.pumpView(const InstancesPage(), settings: settings);
      await tester.pumpAndSettle();

      final view = tester.widget<InstancesView>(find.byType(InstancesView));
      expect(view.checker, same(NetworkSession.current.instanceChecker));
      expect(view.catalog, MozhiPublicInstance.all);
      expect(view.proxyActive, NetworkSession.current.hasProxy);
    });

    testWidgets('follows a new checker and catalogue', (tester) async {
      await pump(tester);
      final other = _FakeChecker()..results[_fast.url] = _online(77);

      await tester.pumpView(
        InstancesPage(
          checker: other,
          catalog: const [MozhiPublicInstance(url: 'https://new.example')],
        ),
        settings: settings,
      );
      await tester.pumpAndSettle();

      expect(find.text('77 ms'), findsOneWidget);
      expect(find.text('new.example'), findsOneWidget);
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
        // Closable without a pointer and without undoing.
        expect(
          tester.widget<SnackBar>(find.byType(SnackBar)).showCloseIcon,
          isTrue,
        );
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        verify(() => settings.addInstance(_slow)).called(1);
        verify(() => settings.moveInstance(2, 1)).called(1);
      });

      group('test', () {
        Future<void> runTest(WidgetTester tester) async {
          await pump(tester);
          await openMenu(tester, 0);
          await tester.tap(find.text('Test'));
          await tester.pump();
        }

        testWidgets('translates hello and shows the latency', (tester) async {
          final answer = Completer<InstanceTestResult>();
          checker.onTest = (_) => answer.future;
          final handle = tester.ensureSemantics();
          await runTest(tester);

          expect(find.text('Test Fast'), findsOneWidget);
          expect(find.semantics.byLabel(RegExp('Testing instance…')), findsOne);
          answer.complete(
            const InstanceTestResult(
              engineId: 'google',
              engineName: 'Google',
              text: 'Hallo',
              latency: Duration(milliseconds: 420),
            ),
          );
          await tester.pumpAndSettle();

          const result = 'Google translated “hello” to “Hallo” in 420 ms.';
          expect(find.text(result), findsOneWidget);
          expect(
            tester.getSemantics(find.text(result)),
            isSemantics(label: result, isLiveRegion: true),
          );
          expect(checker.tested, [_fast.url]);
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();
          expect(find.text(result), findsNothing);
          handle.dispose();
        });

        testWidgets('shows a failure', (tester) async {
          checker.onTest = (_) =>
              throw const MozhiApiException('Connection refused');
          await runTest(tester);
          await tester.pumpAndSettle();

          expect(
            find.text("Couldn't reach this instance: Connection refused"),
            findsOneWidget,
          );
        });

        testWidgets('explains a refused request', (tester) async {
          checker.onTest = (_) => throw const MozhiApiException(
            ProxyRequiredException.defaultMessage,
          );
          await runTest(tester);
          await tester.pumpAndSettle();

          expect(
            find.textContaining('only work through a proxy'),
            findsOneWidget,
          );
        });

        testWidgets('says when no engine is enabled', (tester) async {
          checker.onTest = (_) => throw const InstanceHasNoEnginesException();
          await runTest(tester);
          await tester.pumpAndSettle();

          expect(
            find.text('This instance has no translation engine enabled.'),
            findsOneWidget,
          );
        });

        testWidgets('ignores a result after closing', (tester) async {
          final answer = Completer<InstanceTestResult>();
          checker.onTest = (_) => answer.future;
          await runTest(tester);
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();

          answer.completeError(const MozhiApiException('late'));
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
        });

        testWidgets('ignores a success after closing', (tester) async {
          final answer = Completer<InstanceTestResult>();
          checker.onTest = (_) => answer.future;
          await runTest(tester);
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();

          answer.complete(
            const InstanceTestResult(
              engineId: 'g',
              engineName: 'G',
              text: 't',
              latency: Duration.zero,
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
        });

        testWidgets('ignores missing engines after closing', (tester) async {
          final answer = Completer<InstanceTestResult>();
          checker.onTest = (_) => answer.future;
          await runTest(tester);
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();

          answer.completeError(const InstanceHasNoEnginesException());
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
        });
      });

      group('edit', () {
        Finder field(String label) => find.widgetWithText(TextFormField, label);

        Future<void> openEditor(WidgetTester tester, int index) async {
          await pump(tester);
          await openMenu(tester, index);
          await tester.tap(find.text('Edit'));
          await tester.pumpAndSettle();
        }

        testWidgets('prefills the instance', (tester) async {
          await openEditor(tester, 0);

          expect(find.text('Edit instance'), findsOneWidget);
          expect(find.text('https://fast.example.com'), findsOneWidget);
          expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
        });

        testWidgets('replaces the label in place', (tester) async {
          await openEditor(tester, 0);
          await tester.enterText(field('Label (optional)'), 'Quick');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();

          final saved =
              verify(() => settings.addInstance(captureAny())).captured.single
                  as MozhiInstance;
          expect(saved.url, _fast.url);
          expect(saved.label, 'Quick');
          verifyNever(() => settings.removeInstance(any()));
          expect(find.text('Instance updated'), findsOneWidget);
        });

        testWidgets('a new URL keeps the position', (tester) async {
          when(() => settings.removeInstance(any())).thenAnswer((invocation) {
            when(() => settings.state)
                .thenReturn(const AppSettings(instances: [_fast, _down]));
          });
          when(() => settings.addInstance(any())).thenAnswer((invocation) {
            when(() => settings.state).thenReturn(
              AppSettings(
                instances: [
                  _fast,
                  _down,
                  invocation.positionalArguments.single as MozhiInstance,
                ],
              ),
            );
          });
          await openEditor(tester, 1);
          await tester.enterText(field('Instance URL'), 'quick.example.com');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();

          verify(() => settings.removeInstance(_slow.url)).called(1);
          final saved =
              verify(() => settings.addInstance(captureAny())).captured.single
                  as MozhiInstance;
          expect(saved.url, 'https://quick.example.com');
          verify(() => settings.moveInstance(2, 1)).called(1);
        });

        testWidgets('a new URL at the end needs no move', (tester) async {
          when(() => settings.addInstance(any())).thenAnswer((invocation) {
            when(() => settings.state).thenReturn(
              AppSettings(
                instances: [
                  _fast,
                  _slow,
                  invocation.positionalArguments.single as MozhiInstance,
                ],
              ),
            );
          });
          await openEditor(tester, 2);
          await tester.enterText(field('Instance URL'), 'up.example.com');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();

          verifyNever(() => settings.moveInstance(any(), any()));
        });

        testWidgets('allows its own URL but not another one', (tester) async {
          await openEditor(tester, 0);
          await tester.enterText(field('Instance URL'), 'slow.example.com');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();

          expect(
            find.text('This instance is already in your list'),
            findsOneWidget,
          );
        });

        testWidgets('a public instance stays one with the same URL', (
          tester,
        ) async {
          const public = MozhiInstance(
            url: 'https://pub.example.com',
            label: 'pub',
            isCustom: false,
          );
          when(() => settings.state)
              .thenReturn(const AppSettings(instances: [public]));
          await openEditor(tester, 0);
          await tester.enterText(field('Label (optional)'), 'Mine');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();

          final saved =
              verify(() => settings.addInstance(captureAny())).captured.single
                  as MozhiInstance;
          expect(saved.isCustom, isFalse);
        });

        testWidgets('cancel changes nothing', (tester) async {
          await openEditor(tester, 0);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();

          verifyNever(() => settings.addInstance(any()));
        });
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

    group('public instances', () {
      const catalog = [
        MozhiPublicInstance(
          url: 'https://fast.example.com',
          country: 'Germany',
        ),
        MozhiPublicInstance(
          url: 'https://cf.example.com',
          country: 'USA',
          isp: 'Cloudflare Inc',
          cloudflare: true,
          onion: 'http://cfmirror.onion',
        ),
        MozhiPublicInstance(i2p: 'http://only.b32.i2p'),
      ];

      testWidgets('lists the ones not added yet', (tester) async {
        await pump(tester, catalog: catalog);

        expect(find.text('Public instances'), findsOneWidget);
        expect(
          find.textContaining('(${MozhiPublicInstance.snapshotDate})'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('catalog https://fast.example.com')),
          findsNothing,
        );
        expect(find.text('cf.example.com'), findsOneWidget);
        expect(find.text('USA · Cloudflare Inc'), findsOneWidget);
        expect(find.byType(CloudflareBadge), findsOneWidget);
      });

      testWidgets('hides Tor and I2P addresses without a proxy setting', (
        tester,
      ) async {
        await pump(tester, catalog: catalog);

        expect(find.text('cfmirror.onion'), findsNothing);
        expect(find.text('only.b32.i2p'), findsNothing);
        expect(
          find.textContaining('once a proxy is set in the privacy settings'),
          findsOneWidget,
        );
      });

      testWidgets('lists Tor and I2P addresses with a proxy setting', (
        tester,
      ) async {
        when(() => settings.state).thenReturn(
          const AppSettings(instances: [_fast], httpProxy: '127.0.0.1:8118'),
        );
        await pump(tester, catalog: catalog);

        expect(find.text('cfmirror.onion'), findsOneWidget);
        // The mirror names its clearnet operator.
        expect(find.text('cf.example.com · USA · Cloudflare Inc'), findsOne);
        expect(find.text('only.b32.i2p'), findsOneWidget);
        expect(find.text('Tor'), findsOneWidget);
        expect(find.text('I2P'), findsOneWidget);
        expect(find.textContaining('once a proxy is set'), findsNothing);
      });

      testWidgets('adds one with its country as the label', (tester) async {
        await pump(tester, catalog: catalog);

        await tester.tap(find.byTooltip('Add cf.example.com'));
        await tester.pumpAndSettle();

        final added =
            verify(() => settings.addInstance(captureAny())).captured.single
                as MozhiInstance;
        expect(added.url, 'https://cf.example.com');
        expect(added.label, 'cf.example.com (USA)');
        expect(added.isCustom, isFalse);
        expect(find.text('Instance added'), findsOneWidget);
      });

      testWidgets('adds a hidden service without a label', (tester) async {
        when(() => settings.state).thenReturn(
          const AppSettings(instances: [], httpProxy: '127.0.0.1:8118'),
        );
        await pump(tester, catalog: catalog);

        await tester.tap(find.byTooltip('Add only.b32.i2p'));
        await tester.pumpAndSettle();

        final added =
            verify(() => settings.addInstance(captureAny())).captured.single
                as MozhiInstance;
        expect(added.url, 'http://only.b32.i2p');
        expect(added.label, isNull);
      });

      testWidgets('says when every one is added', (tester) async {
        await pump(tester, catalog: [MozhiPublicInstance(url: _slow.url)]);

        expect(
          find.text('Every public instance is already in your list.'),
          findsOneWidget,
        );
      });
    });

    group('add instance', () {
      Future<void> openDialog(WidgetTester tester, {bool proxy = false}) async {
        await pump(tester, proxyActive: proxy);
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
        // The test button sent nothing.
        expect(checker.tested, isEmpty);
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

      testWidgets('submitting the label field adds the instance', (
        tester,
      ) async {
        await openDialog(tester);
        await tester.enterText(field('Instance URL'), 'mozhi.example.net');
        await tester.enterText(field('Label (optional)'), 'Mine');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        final added =
            verify(() => settings.addInstance(captureAny())).captured.single
                as MozhiInstance;
        expect(added.url, 'https://mozhi.example.net');
      });

      test('describeError', () {
        expect(describeError(const MozhiApiException('down')), 'down');
        expect(describeError(const LlmApiException('bad')), 'bad');
        expect(
          describeError(const LlmApiException('bad', statusCode: 500)),
          '500: bad',
        );
        expect(describeError(const FormatException('oops')), 'oops');
        expect(describeError(StateError('x')), 'Bad state: x');
      });

      test('describeErrorLocalized', () {
        final l10n = lookupAppLocalizations(const Locale('en'));
        expect(
          describeErrorLocalized(
            l10n,
            const MozhiApiException(CleartextRefusedException.defaultMessage),
          ),
          l10n.commonErrorCleartextRefused,
        );
        expect(
          describeErrorLocalized(l10n, const MozhiApiException('down')),
          'down',
        );
      });

      test('urlSecretProblem', () {
        expect(urlSecretProblem(''), isNull);
        expect(urlSecretProblem('https://mozhi.example.com/api'), isNull);
        expect(urlSecretProblem('mozhi.example.com:3000'), isNull);
        expect(
          urlSecretProblem('https://u:p@mozhi.example.com'),
          UrlSecretProblem.credentials,
        );
        expect(
          urlSecretProblem('token@mozhi.example.com'),
          UrlSecretProblem.credentials,
        );
        expect(
          urlSecretProblem('https://mozhi.example.com?key=1'),
          UrlSecretProblem.query,
        );
        expect(urlSecretProblem('http://[::1'), isNull);
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

      testWidgets('test translates hello before saving', (tester) async {
        final answer = Completer<InstanceTestResult>();
        checker.onTest = (_) => answer.future;
        await openDialog(tester);
        await tester.enterText(field('Instance URL'), 'ok.example.com');
        final handle = tester.ensureSemantics();
        await tester.tap(find.text('Test'));
        await tester.pump();
        expect(find.semantics.byLabel(RegExp('Testing instance…')), findsOne);
        answer.complete(
          const InstanceTestResult(
            engineId: 'google',
            engineName: 'Google',
            text: 'Hallo',
            latency: Duration(milliseconds: 42),
          ),
        );
        await tester.pumpAndSettle();
        const result = 'Google translated “hello” to “Hallo” in 42 ms.';
        expect(find.text(result), findsOneWidget);
        expect(checker.tested, ['https://ok.example.com']);
        expect(
          tester.getSemantics(find.text(result)),
          isSemantics(label: result, isLiveRegion: true),
        );
        // Only the icon is green; the text keeps full contrast on the
        // dialog surface.
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(result),
        );
        final colors = Theme.of(tester.element(find.text(result))).colorScheme;
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
        checker.onTest = (_) =>
            throw const MozhiApiException('Connection refused');
        await openDialog(tester);
        await tester.enterText(field('Instance URL'), 'bad.example.com');
        await tester.tap(find.text('Test'));
        await tester.pumpAndSettle();
        expect(
          find.text("Couldn't reach this instance: Connection refused"),
          findsOneWidget,
        );
      });

      testWidgets('says when the instance has no engines', (tester) async {
        checker.onTest = (_) => throw const InstanceHasNoEnginesException();
        await openDialog(tester);
        await tester.enterText(field('Instance URL'), 'empty.example.com');
        await tester.tap(find.text('Test'));
        await tester.pumpAndSettle();
        expect(
          find.text('This instance has no translation engine enabled.'),
          findsOneWidget,
        );
      });

      testWidgets('cancel adds nothing', (tester) async {
        await openDialog(tester);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verifyNever(() => settings.addInstance(any()));
      });

      group('plain http', () {
        const warning = Key('instance_insecure_warning');

        testWidgets('refuses a public http instance', (tester) async {
          await openDialog(tester);
          expect(find.byKey(warning), findsNothing);
          await tester.enterText(
            field('Instance URL'),
            'http://mozhi.example.com/api',
          );
          await tester.pump();
          expect(find.byKey(warning), findsOneWidget);
          expect(find.text('Connection not encrypted'), findsOneWidget);
          expect(
            find.textContaining('Use https for public servers'),
            findsOneWidget,
          );
          expect(
            tester.getSemantics(find.text('Connection not encrypted')),
            isSemantics(isLiveRegion: true),
          );

          await tester.tap(find.text('Add'));
          await tester.pumpAndSettle();
          expect(find.text('Use https:// for public servers.'), findsOne);
          verifyNever(() => settings.addInstance(any()));

          await tester.tap(find.text('Test'));
          await tester.pumpAndSettle();
          expect(checker.tested, isEmpty);

          await tester.enterText(
            field('Instance URL'),
            'https://mozhi.example.com',
          );
          await tester.pump();
          expect(find.byKey(warning), findsNothing);
        });

        for (final url in [
          'http://localhost:3000',
          'http://192.168.1.20:3000',
          'http://10.0.0.5',
          'http://mozhi.lan',
          'http://nas.local:3000',
          'http://[fd00::1]:3000',
          'http://mozhibox',
          '192.168.1.20:3000',
        ]) {
          testWidgets('adds local $url without a warning', (tester) async {
            await openDialog(tester);
            await tester.enterText(field('Instance URL'), url);
            await tester.pump();
            expect(find.byKey(warning), findsNothing);
            await tester.tap(find.text('Add'));
            await tester.pumpAndSettle();
            final added =
                verify(() => settings.addInstance(captureAny())).captured.single
                    as MozhiInstance;
            expect(added.url, startsWith('http://'));
          });
        }
      });

      group('Tor and I2P', () {
        const note = Key('instance_needs_proxy');

        testWidgets('note that they need a proxy', (tester) async {
          await openDialog(tester);
          await tester.enterText(field('Instance URL'), 'abc.onion');
          await tester.pump();

          expect(find.byKey(note), findsOneWidget);
          expect(
            find.byKey(const Key('instance_insecure_warning')),
            findsNothing,
          );
          await tester.tap(find.text('Add'));
          await tester.pumpAndSettle();
          final added =
              verify(() => settings.addInstance(captureAny())).captured.single
                  as MozhiInstance;
          expect(added.url, 'http://abc.onion');
        });

        testWidgets('need no note with an active proxy', (tester) async {
          await openDialog(tester, proxy: true);
          await tester.enterText(field('Instance URL'), 'abc.b32.i2p');
          await tester.pump();

          expect(find.byKey(note), findsNothing);
        });
      });
    });

    testWidgets('fits 320dp with large text', (tester) async {
      checker.results.addAll({_fast.url: _online(5), _slow.url: _online(5)});
      await pump(
        tester,
        size: const Size(320, 900),
        textScale: 2,
        catalog: MozhiPublicInstance.all,
      );
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

  testWidgets('the default dialog uses the session', (tester) async {
    await tester.pumpView(const AddInstanceDialog(existingUrls: []));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Instance URL'),
      'abc.onion',
    );
    await tester.pump();

    // No proxy in this session.
    expect(find.byKey(const Key('instance_needs_proxy')), findsOneWidget);
  });
}
