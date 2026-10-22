import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/model_source_dialog.dart';

import '../../../helpers/helpers.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

const _mirror = ModelSource(
  kind: ModelSourceKind.custom,
  customUrl: 'https://mirror.example/models/',
);

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    registerFallbackValue(ModelSource.defaultHosts);
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group(modelSourceSummary, () {
    test('names the source and the fallback', () {
      expect(
        modelSourceSummary(l10n, ModelSource.defaultHosts),
        'Original publishers',
      );
      expect(
        modelSourceSummary(
          l10n,
          const ModelSource(kind: ModelSourceKind.thisServer),
        ),
        'This web server',
      );
      expect(modelSourceSummary(l10n, _mirror), 'Mirror: mirror.example');
      expect(
        modelSourceSummary(l10n, _mirror.copyWith(fallbackToDefault: true)),
        'Mirror: mirror.example, then the original publishers',
      );
    });

    test('shows the port of a mirror', () {
      expect(
        modelSourceHost(
          const ModelSource(
            kind: ModelSourceKind.custom,
            customUrl: 'http://192.168.1.10:8080/',
          ),
        ),
        '192.168.1.10:8080',
      );
      expect(modelSourceHost(ModelSource.defaultHosts), isNull);
    });
  });

  group(ModelSourceTile, () {
    late SettingsCubit cubit;

    setUp(() {
      cubit = _MockSettingsCubit();
      when(() => cubit.state)
          .thenReturn(const AppSettings(modelSource: _mirror));
    });

    Future<void> pump(WidgetTester tester) => tester.pumpApp(
      Scaffold(
        body: BlocProvider<SettingsCubit>.value(
          value: cubit,
          child: const ModelSourceTile(),
        ),
      ),
    );

    testWidgets('shows the source in use', (tester) async {
      await pump(tester);
      expect(find.text('Model source'), findsOneWidget);
      expect(find.text('Mirror: mirror.example'), findsOneWidget);
    });

    testWidgets('shows nothing without settings', (tester) async {
      await tester.pumpApp(const Scaffold(body: ModelSourceTile()));
      expect(find.byKey(ModelSourceTile.tileKey), findsNothing);
    });

    testWidgets('saves the source picked in the dialog', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ModelSourceTile.tileKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Original publishers'));
      await tester.pump();
      await tester.tap(find.byKey(ModelSourceDialog.saveKey));
      await tester.pumpAndSettle();
      verify(
        () => cubit.setModelSource(
          const ModelSource(customUrl: 'https://mirror.example/models/'),
        ),
      ).called(1);
    });

    testWidgets('changes nothing when cancelled or unchanged', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ModelSourceTile.tileKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ModelSourceTile.tileKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ModelSourceDialog.saveKey));
      await tester.pumpAndSettle();
      verifyNever(() => cubit.setModelSource(any()));
    });
  });

  group(ModelSourceDialog, () {
    ModelSource? result;
    late bool closed;

    setUp(() {
      result = null;
      closed = false;
    });

    Future<void> open(
      WidgetTester tester, {
      ModelSource initial = ModelSource.defaultHosts,
      bool offerThisServer = false,
      bool proxyActive = false,
    }) async {
      await tester.pumpApp(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showDialog<ModelSource>(
                    context: context,
                    builder: (_) => ModelSourceDialog(
                      initial: initial,
                      offerThisServer: offerThisServer,
                      appBase: Uri.parse('https://mozhi.example/app/'),
                      proxyActive: proxyActive,
                    ),
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.byKey(ModelSourceDialog.saveKey));
      await tester.pumpAndSettle();
    }

    Future<void> chooseMirror(WidgetTester tester, String url) async {
      await tester.tap(find.text('Custom mirror…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(ModelSourceDialog.urlFieldKey), url);
      await tester.pump();
    }

    testWidgets('offers the original publishers and a custom mirror', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Original publishers'), findsOneWidget);
      expect(find.text('This web server'), findsNothing);
      expect(find.text('Custom mirror…'), findsOneWidget);
      // No mirror, no fallback.
      expect(find.byKey(ModelSourceDialog.fallbackKey), findsNothing);
      expect(find.byKey(ModelSourceDialog.urlFieldKey), findsNothing);
      await save(tester);
      expect(result, ModelSource.defaultHosts);
    });

    testWidgets('saves a normalised mirror with the fallback', (tester) async {
      await open(tester);
      await chooseMirror(tester, 'mirror.example/models');
      await tester.ensureVisible(find.byKey(ModelSourceDialog.fallbackKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ModelSourceDialog.fallbackKey));
      await tester.pump();
      await save(tester);
      expect(
        result,
        const ModelSource(
          kind: ModelSourceKind.custom,
          customUrl: 'https://mirror.example/models/',
          fallbackToDefault: true,
        ),
      );
    });

    testWidgets('saves from the keyboard', (tester) async {
      await open(tester);
      await chooseMirror(tester, 'http://192.168.1.10:8080/models/');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(result?.customUrl, 'http://192.168.1.10:8080/models/');
    });

    final refused = {
      '':
          'Enter the mirror’s address, for example '
          'https://example.org/models/',
      'https://me:pw@mirror.example/':
          'Remove the user name and password '
          'from the address. Model mirrors are public; their files are '
          'checked by Mozhi.',
      'https://mirror.example/?k=1':
          'Remove the part after “?” or “#” '
          'from the address.',
      'http://mirror.example/': 'Use https:// for public servers.',
    };
    for (final MapEntry(key: url, value: message) in refused.entries) {
      testWidgets('refuses "$url"', (tester) async {
        await open(tester);
        await chooseMirror(tester, url);
        await save(tester);
        expect(closed, isFalse);
        expect(find.text(message), findsOneWidget);
        // Typing again clears the error.
        await tester.enterText(find.byKey(ModelSourceDialog.urlFieldKey), 'x');
        await tester.pump();
        expect(find.text(message), findsNothing);
      });
    }

    testWidgets('warns about plain http to a public server', (tester) async {
      await open(tester);
      await chooseMirror(tester, 'http://mirror.example/');
      expect(
        find.byKey(const Key('model_source_insecure_warning')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(ModelSourceDialog.urlFieldKey),
        'http://nas.local/',
      );
      await tester.pump();
      expect(
        find.byKey(const Key('model_source_insecure_warning')),
        findsNothing,
      );
    });

    testWidgets('notes that .onion needs a proxy', (tester) async {
      await open(tester);
      await chooseMirror(tester, 'http://abcdef.onion/');
      expect(find.byKey(const Key('model_source_needs_proxy')), findsOneWidget);
    });

    testWidgets('no proxy note with a proxy', (tester) async {
      await open(tester, proxyActive: true);
      await chooseMirror(tester, 'http://abcdef.onion/');
      expect(find.byKey(const Key('model_source_needs_proxy')), findsNothing);
    });

    testWidgets('offers this web server in a browser', (tester) async {
      await open(tester, offerThisServer: true);
      expect(
        find.textContaining('https://mozhi.example/app/models/'),
        findsOneWidget,
      );
      await tester.tap(find.text('This web server'));
      await tester.pump();
      expect(find.byKey(ModelSourceDialog.fallbackKey), findsOneWidget);
      await save(tester);
      expect(result, const ModelSource(kind: ModelSourceKind.thisServer));
    });

    testWidgets('keeps a stored custom URL when another kind is saved', (
      tester,
    ) async {
      await open(tester, initial: _mirror);
      expect(find.text('https://mirror.example/models/'), findsOneWidget);
      await tester.tap(find.text('Original publishers'));
      await tester.pump();
      await save(tester);
      expect(
        result,
        const ModelSource(customUrl: 'https://mirror.example/models/'),
      );
    });

    testWidgets('cancel pops nothing', (tester) async {
      await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result, isNull);
    });
  });
}
