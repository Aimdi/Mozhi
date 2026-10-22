import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi/l10n/gen/app_localizations_en.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/network_activity_page.dart';

const _openAi = EgressDestination(
  kind: EgressDestinationKind.cloudProvider,
  host: 'api.openai.com',
  name: 'OpenAI',
);
const _models = EgressDestination(
  kind: EgressDestinationKind.modelHost,
  host: 'huggingface.co',
  name: 'Hugging Face',
);
const _lan = EgressDestination(
  kind: EgressDestinationKind.localNetwork,
  host: '192.168.1.5',
  port: 3000,
);
const _ollama = EgressDestination(
  kind: EgressDestinationKind.thisDevice,
  host: 'localhost',
  port: 11434,
);

void main() {
  final l10n = AppLocalizationsEn();
  final start = DateTime.now();
  late EgressLedger ledger;
  late List<String> copied;

  setUp(() {
    ledger = EgressLedger(clock: () => start);
    copied = [];
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });

  tearDown(
    () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  EgressEntry record(
    EgressDestination destination, {
    EgressPurpose purpose = EgressPurpose.aiModel,
    String scheme = 'https',
    bool viaProxy = false,
    int? sent = 1200,
    int received = 3400,
    int status = 200,
    EgressOutcome outcome = EgressOutcome.succeeded,
    EgressFailure? failure,
    String? redirectedTo,
  }) {
    final entry = ledger.begin(
      method: 'POST',
      scheme: scheme,
      destination: destination,
      purpose: purpose,
      viaProxy: viaProxy,
      bytesSent: sent,
    );
    if (outcome == EgressOutcome.pending) return entry;
    final done = entry.copyWith(
      bytesReceived: received,
      statusCode: status,
      outcome: outcome,
      failure: failure,
      duration: const Duration(milliseconds: 320),
      redirectedTo: redirectedTo,
    );
    ledger.update(done);
    return done;
  }

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(400, 900),
    ThemeMode mode = ThemeMode.light,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final themes = AppThemes.fromSettings(const AppSettings());
    await tester.pumpWidget(
      MaterialApp(
        theme: themes.light,
        darkTheme: themes.dark,
        themeMode: mode,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NetworkActivityPage(ledger: ledger),
      ),
    );
    await tester.pump();
  }

  group('NetworkActivityPage', () {
    testWidgets('says when nothing has left the device', (tester) async {
      await pump(tester);

      expect(find.text(l10n.settingsNetworkNothingTitle), findsOneWidget);
      expect(find.text(l10n.settingsNetworkDestinations), findsNothing);
      expect(find.text(l10n.settingsNetworkLog), findsNothing);
      expect(find.text(l10n.settingsNetworkAboutSession), findsOneWidget);
      expect(find.text(l10n.settingsNetworkAboutNotRecorded), findsOneWidget);
      final clear = tester.widget<IconButton>(
        find.byKey(const Key('network_activity_clear')),
      );
      expect(clear.onPressed, isNull);
      expect(
        tester.getSemantics(find.text(l10n.settingsNetworkNothingTitle)),
        matchesSemantics(
          isHeader: true,
          label: l10n.settingsNetworkNothingTitle,
        ),
      );
    });

    testWidgets('a server on this device keeps it on the device', (
      tester,
    ) async {
      record(_ollama);
      await pump(tester);

      expect(find.text(l10n.settingsNetworkNothingTitle), findsOneWidget);
      expect(find.text(l10n.settingsNetworkStayedOnDevice(1)), findsOneWidget);
      expect(find.text('localhost:11434'), findsWidgets);
    });

    testWidgets('summarises the destinations and lists the requests', (
      tester,
    ) async {
      record(_openAi, viaProxy: true);
      record(
        _openAi,
        purpose: EgressPurpose.catalog,
        sent: null,
        status: 401,
        outcome: EgressOutcome.httpError,
      );
      record(
        _models,
        purpose: EgressPurpose.modelDownload,
        sent: 0,
        received: 5 * 1024 * 1024,
        redirectedTo: 'cdn-lfs.huggingface.co',
      );
      record(
        _lan,
        scheme: 'http',
        purpose: EgressPurpose.translation,
        outcome: EgressOutcome.failed,
        failure: EgressFailure.timeout,
      );
      record(_lan, outcome: EgressOutcome.pending);
      await pump(tester);

      final headline = tester.widget<Text>(
        find.byKey(const Key('network_activity_headline')),
      );
      expect(headline.data, startsWith('5 requests since'));
      expect(find.text(l10n.settingsNetworkContentSummary(2)), findsOneWidget);
      expect(find.text(l10n.settingsNetworkDestinations), findsOneWidget);
      expect(find.text('OpenAI'), findsWidgets);
      expect(find.text('Cloud provider · api.openai.com'), findsOneWidget);
      expect(
        find.text(l10n.settingsNetworkKindCloudProviderBody),
        findsOneWidget,
      );
      expect(find.text(l10n.settingsNetworkContentSent), findsNWidgets(2));
      expect(find.text(l10n.settingsNetworkNoContent), findsOneWidget);
      expect(find.text(l10n.settingsNetworkViaProxy), findsWidgets);
      expect(find.text(l10n.settingsNetworkUnencrypted), findsWidgets);

      await tester.scrollUntilVisible(
        find.text(l10n.settingsNetworkLog),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(l10n.settingsNetworkStatusPending), findsOneWidget);
      expect(find.text(l10n.settingsNetworkStatusTimeout), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text(l10n.settingsNetworkStatusHttpError(401)),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text(l10n.settingsNetworkRedirected('cdn-lfs.huggingface.co')),
        findsOneWidget,
      );
      expect(find.text(l10n.settingsNetworkStatusOk(200)), findsWidgets);
    });

    testWidgets('a request reads as one sentence', (tester) async {
      final handle = tester.ensureSemantics();
      final entry = record(_openAi);
      await pump(tester, size: const Size(400, 2000));

      final node = tester.getSemantics(
        find.byKey(Key('network_entry_${entry.id}')),
      );
      expect(node.label, contains('OpenAI'));
      expect(node.label, contains(l10n.settingsNetworkPurposeAi));
      expect(node.label, contains(l10n.settingsNetworkStatusOk(200)));
      handle.dispose();
    });

    testWidgets('mentions requests that are no longer listed', (tester) async {
      ledger = EgressLedger(capacity: 1, clock: () => start);
      record(_openAi);
      record(_openAi);
      await pump(tester, size: const Size(400, 2000));

      expect(find.text(l10n.settingsNetworkDropped(1)), findsOneWidget);
    });

    testWidgets('Clear empties the log', (tester) async {
      record(_openAi);
      await pump(tester);

      await tester.tap(find.byKey(const Key('network_activity_clear')));
      await tester.pump();

      expect(ledger.entries, isEmpty);
      expect(find.text(l10n.settingsNetworkCleared), findsOneWidget);
      expect(find.text(l10n.settingsNetworkNothingTitle), findsOneWidget);
    });

    testWidgets('Copy summary copies a text-free summary', (tester) async {
      record(_openAi);
      record(_models, purpose: EgressPurpose.modelDownload, sent: 0);
      await pump(tester);

      await tester.tap(find.byKey(const Key('network_activity_copy')));
      await tester.pump();

      final text = copied.single;
      expect(text, startsWith('Mozhi network activity since'));
      expect(text, contains('OpenAI (Cloud provider): 1 request'));
      expect(text, contains(l10n.settingsNetworkContentSent));
      expect(text, contains('Hugging Face (Model download)'));
      expect(text, endsWith(l10n.settingsNetworkCopyFooter));
      expect(find.text(l10n.commonCopied), findsOneWidget);
    });

    testWidgets('shows summary and requests side by side when wide', (
      tester,
    ) async {
      record(_openAi);
      await pump(tester, size: const Size(1280, 900));

      expect(
        find.byKey(const Key('network_activity_summary_pane')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('network_activity_log_pane')),
        findsOneWidget,
      );
      expect(find.text(l10n.settingsNetworkLog), findsOneWidget);
    });

    testWidgets('works in the dark theme', (tester) async {
      record(_openAi);
      record(_lan, scheme: 'http');
      await pump(tester, mode: ThemeMode.dark);

      expect(tester.takeException(), isNull);
      expect(find.text('OpenAI'), findsWidgets);
    });

    testWidgets('follows the current session by default', (tester) async {
      final previous = NetworkSession.current;
      addTearDown(() => NetworkSession.current = previous);
      final session = NetworkSession(ledger: ledger);
      NetworkSession.current = session;
      record(_openAi);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const NetworkActivityPage(),
        ),
      );
      await tester.pump();

      expect(find.text('OpenAI'), findsWidgets);
      record(_models, purpose: EgressPurpose.modelDownload);
      await tester.pump();
      expect(find.text('Hugging Face'), findsWidgets);
    });
  });

  group('labels', () {
    test('every kind and purpose has a label, text and icon', () {
      for (final kind in EgressDestinationKind.values) {
        expect(egressKindLabel(l10n, kind), isNotEmpty);
        expect(egressKindDescription(l10n, kind), isNotEmpty);
        expect(egressKindIcon(kind), isNotNull);
      }
      expect({
        for (final kind in EgressDestinationKind.values)
          egressKindLabel(l10n, kind),
      }, hasLength(EgressDestinationKind.values.length));
      for (final purpose in EgressPurpose.values) {
        expect(egressPurposeLabel(l10n, purpose), isNotEmpty);
        expect(egressPurposeIcon(purpose), isNotNull);
      }
    });

    test('statuses', () {
      EgressEntry entry(
        EgressOutcome outcome, {
        int? status,
        EgressFailure? failure,
      }) => EgressEntry(
        id: 1,
        startedAt: start,
        method: 'GET',
        scheme: 'https',
        destination: _openAi,
        purpose: EgressPurpose.catalog,
        statusCode: status,
        outcome: outcome,
        failure: failure,
      );
      expect(
        egressStatusLabel(l10n, entry(EgressOutcome.pending)),
        l10n.settingsNetworkStatusPending,
      );
      expect(
        egressStatusLabel(l10n, entry(EgressOutcome.succeeded)),
        'Answered (200)',
      );
      expect(
        egressStatusLabel(l10n, entry(EgressOutcome.httpError, status: 503)),
        'Error 503',
      );
      expect(
        egressStatusLabel(l10n, entry(EgressOutcome.httpError)),
        'Error 0',
      );
      expect(
        egressStatusLabel(
          l10n,
          entry(EgressOutcome.failed, failure: EgressFailure.connection),
        ),
        l10n.settingsNetworkStatusConnection,
      );
      expect(
        egressStatusLabel(
          l10n,
          entry(EgressOutcome.failed, failure: EgressFailure.secureConnection),
        ),
        l10n.settingsNetworkStatusSecureConnection,
      );
      expect(
        egressStatusLabel(l10n, entry(EgressOutcome.failed)),
        l10n.settingsNetworkStatusFailed,
      );
      expect(
        egressStatusLabel(l10n, entry(EgressOutcome.cancelled)),
        l10n.settingsNetworkStatusCancelled,
      );
      expect(
        egressStatusLabel(l10n, entry(EgressOutcome.notSent)),
        l10n.settingsNetworkStatusNotSent,
      );
    });

    test('durations', () {
      expect(
        egressDurationLabel(l10n, const Duration(milliseconds: 320)),
        '320 ms',
      );
      expect(
        egressDurationLabel(l10n, const Duration(milliseconds: 4200)),
        '4.2 s',
      );
    });

    test('destination titles fall back to the host and port', () {
      expect(egressDestinationTitle(_openAi), 'OpenAI');
      expect(egressDestinationTitle(_lan), '192.168.1.5:3000');
    });

    test('the summary of an empty log says so', () {
      final text = networkActivitySummaryText(
        l10n,
        NetworkActivityState.of(ledger),
        formatTime: (_) => '9:00 AM',
      );
      expect(text.split('\n'), [
        'Mozhi network activity since 9:00 AM',
        l10n.settingsNetworkNothingTitle,
        l10n.settingsNetworkCopyFooter,
      ]);
    });

    test('the summary mentions dropped requests', () {
      ledger = EgressLedger(capacity: 1, clock: () => start);
      record(_openAi);
      record(_openAi);
      final text = networkActivitySummaryText(
        l10n,
        NetworkActivityState.of(ledger),
        formatTime: (_) => '9:00 AM',
      );
      expect(text, contains(l10n.settingsNetworkDropped(1)));
    });
  });

  testWidgets('formatActivityTime adds the date on other days', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    final now = DateTime(2026, 10, 22, 12);
    expect(
      formatActivityTime(context, DateTime(2026, 10, 22, 9, 41), now: now),
      '9:41 AM',
    );
    expect(
      formatActivityTime(context, DateTime(2026, 10, 21, 23, 5), now: now),
      'Oct 21, 11:05 PM',
    );
  });
}
