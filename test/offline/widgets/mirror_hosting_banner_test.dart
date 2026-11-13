import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/model_source_dialog.dart';

import '../../helpers/helpers.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

const _thisServer = ModelSource(kind: ModelSourceKind.thisServer);

/// A browser probe whose server hosts the folders in [hosted].
MirrorHostingProbe _probe(
  List<Uri> requests, {
  Set<String> hosted = const {},
}) => MirrorHostingProbe(
  client: MockClient((request) async {
    requests.add(request.url);
    final folder = request.url.pathSegments.reversed.elementAt(1);
    return hosted.contains(folder)
        ? http.Response('{"items": ["x"]}', 200)
        : http.Response('', 404);
  }),
  isWeb: true,
  appBase: () => Uri.parse('https://example.org/'),
);

void main() {
  late ModelSource current;

  setUp(() => current = ModelSource.current);
  tearDown(() => ModelSource.current = current);

  group(MirrorHostingBuilder, () {
    Widget builder(MirrorHostingProbe probe, MirrorDataKind kind) =>
        MirrorHostingBuilder(
          kind: kind,
          probe: probe,
          builder: (context, {required blocked}) =>
              Text(blocked ? 'blocked' : 'open'),
        );

    testWidgets('builds with what the probe says, without settings', (
      tester,
    ) async {
      ModelSource.current = _thisServer;
      final requests = <Uri>[];
      final probe = _probe(requests, hosted: {'phrasebooks'});
      await tester.pumpApp(builder(probe, MirrorDataKind.dictionary));
      expect(find.text('open'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('blocked'), findsOneWidget);
      await tester.pumpApp(builder(probe, MirrorDataKind.phrasebook));
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('asks again when the model source changes', (tester) async {
      final settings = _MockSettingsCubit();
      final changes = StreamController<AppSettings>();
      addTearDown(changes.close);
      const initial = AppSettings(modelSource: _thisServer);
      whenListen(settings, changes.stream, initialState: initial);
      final requests = <Uri>[];
      await tester.pumpApp(
        BlocProvider<SettingsCubit>.value(
          value: settings,
          child: builder(_probe(requests), MirrorDataKind.translation),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('blocked'), findsOneWidget);
      expect(requests, hasLength(1));

      changes.add(
        initial.copyWith(
          modelSource: const ModelSource(
            kind: ModelSourceKind.custom,
            customUrl: 'https://mirror.example.org/',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(requests, hasLength(1));

      // The original publishers refuse a web page: blocked without asking.
      changes.add(initial.copyWith(modelSource: ModelSource.defaultHosts));
      await tester.pumpAndSettle();
      expect(find.text('blocked'), findsOneWidget);
      expect(requests, hasLength(1));
    });

    testWidgets('tells the banner below why', (tester) async {
      ModelSource.current = ModelSource.defaultHosts;
      await tester.pumpApp(
        Scaffold(
          body: MirrorHostingBuilder(
            kind: MirrorDataKind.dictionary,
            probe: _probe([]),
            builder: (context, {required blocked}) => Column(
              children: [
                Text('${MirrorHostingBuilder.blockOf(context)}'),
                if (blocked) const MirrorNotHostedBanner(),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('${DownloadBlock.browserRefused}'), findsOneWidget);
      expect(
        find.text(
          'Your browser can’t download these from the original publishers',
        ),
        findsOneWidget,
      );
      expect(
        find.text("This web server doesn't host the downloads"),
        findsNothing,
      );
    });

    testWidgets('uses the shared probe by default', (tester) async {
      final shared = MirrorHostingProbe.instance;
      addTearDown(() => MirrorHostingProbe.instance = shared);
      final requests = <Uri>[];
      MirrorHostingProbe.instance = _probe(requests);
      ModelSource.current = _thisServer;
      await tester.pumpApp(
        MirrorHostingBuilder(
          kind: MirrorDataKind.textRecognition,
          builder: (context, {required blocked}) =>
              Text(blocked ? 'blocked' : 'open'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('blocked'), findsOneWidget);
      expect(requests.single.path, '/models/tesseract/index.json');
    });
  });

  group(MirrorNotHostedBanner, () {
    testWidgets('offers the import and the help page', (tester) async {
      final opened = <Uri>[];
      final launcher = LinkLauncher.launcher;
      LinkLauncher.launcher = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => LinkLauncher.launcher = launcher);
      var imports = 0;
      await tester.pumpApp(
        Scaffold(body: MirrorNotHostedBanner(onImport: () => imports++)),
      );
      expect(
        find.text("This web server doesn't host the downloads"),
        findsOneWidget,
      );
      expect(find.textContaining("ask the server's owner"), findsOneWidget);
      await tester.tap(find.text('Import from files'));
      expect(imports, 1);
      await tester.tap(find.text('How to host them'));
      await tester.pump();
      expect(opened, [mirrorHostingHelpUrl]);
      expect(mirrorHostingHelpUrl.fragment, 'mirror-the-on-device-models');
    });

    testWidgets('without an import, only the help page', (tester) async {
      await tester.pumpApp(const Scaffold(body: MirrorNotHostedBanner()));
      expect(find.byKey(const Key('mirror_not_hosted_import')), findsNothing);
      expect(find.byKey(const Key('mirror_not_hosted_help')), findsOneWidget);
    });

    testWidgets('original publishers: offers to change the model source', (
      tester,
    ) async {
      final settings = _MockSettingsCubit();
      when(() => settings.state).thenReturn(const AppSettings());
      await tester.pumpApp(
        BlocProvider<SettingsCubit>.value(
          value: settings,
          child: const Scaffold(
            body: MirrorNotHostedBanner(block: DownloadBlock.browserRefused),
          ),
        ),
      );
      expect(
        find.textContaining('don’t let web pages download these files'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('mirror_not_hosted_source')));
      await tester.pumpAndSettle();
      expect(find.byType(ModelSourceDialog), findsOneWidget);
    });

    testWidgets('original publishers without settings: no source button', (
      tester,
    ) async {
      await tester.pumpApp(
        const Scaffold(
          body: MirrorNotHostedBanner(block: DownloadBlock.browserRefused),
        ),
      );
      expect(find.byKey(const Key('mirror_not_hosted_source')), findsNothing);
      expect(find.byKey(const Key('mirror_not_hosted_help')), findsOneWidget);
    });

    testWidgets('a running import disables the button', (tester) async {
      await tester.pumpApp(
        Scaffold(body: MirrorNotHostedBanner(onImport: () {}, importing: true)),
      );
      final button = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('mirror_not_hosted_import')),
      );
      expect(button.onPressed, isNull);
    });
  });
}
