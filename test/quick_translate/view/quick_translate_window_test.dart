import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/quick_translate/quick_translate.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

class _MockGoRouter extends Mock implements GoRouter;

void main() {
  setUpAll(registerQuickTranslateFallbacks);

  const channel = MethodChannel(QuickTranslateHost.channelName);
  late MockTranslationRepository repository;
  late MockSettingsCubit settings;
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    repository = MockTranslationRepository();
    settings = mockSettings(const AppSettings(target: french));
    when(() => repository.getEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async => const [google]);
    when(() => repository.getTargetLanguages(any()))
        .thenAnswer((_) async => mozhiTargets);
    when(() => repository.translate(any(), any()))
        .thenAnswer((_) => Stream.value(result('Bonjour')));
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  Future<void> open(
    WidgetTester tester,
    QuickTranslateHost window, {
    GoRouter? router,
  }) async {
    Widget child = Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () =>
              showQuickTranslate(context, text: 'Hello', host: window),
          child: const Text('open'),
        ),
      ),
    );
    if (router != null) {
      child = InheritedGoRouter(goRouter: router, child: child);
    }
    await tester.pumpQuick(
      RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: BlocProvider<SettingsCubit>.value(value: settings, child: child),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('closing the sheet closes the quick translate window', (
    tester,
  ) async {
    final window = QuickTranslateHost(
      initialRoute: () => QuickTranslateHost.location,
    );
    await open(tester, window);
    expect(find.byType(QuickTranslateSheet), findsOneWidget);
    expect(calls, isEmpty);

    await tester.tap(find.byKey(const Key('quick_translate_close')));
    await tester.pumpAndSettle();

    expect(calls.single.method, 'close');
  });

  testWidgets('the offline languages open in the main window', (tester) async {
    final router = _MockGoRouter();
    final window = QuickTranslateHost(
      initialRoute: () => QuickTranslateHost.location,
    );
    await open(tester, window, router: router);

    tester
        .widget<QuickTranslateSheet>(find.byType(QuickTranslateSheet))
        .onOpenOfflineModels!();
    await tester.pump();

    expect(calls.single.method, 'openInApp');
    expect(calls.single.arguments, {'location': AppRoutes.offline});
    verifyNever(() => router.push<void>(any()));
  });

  testWidgets('the main window keeps its sheet and its router', (tester) async {
    final router = _MockGoRouter();
    when(() => router.push<void>(any())).thenAnswer((_) async {});
    final window = QuickTranslateHost(initialRoute: () => '/');
    await open(tester, window, router: router);

    tester
        .widget<QuickTranslateSheet>(find.byType(QuickTranslateSheet))
        .onOpenOfflineModels!();
    await tester.tap(find.byKey(const Key('quick_translate_close')));
    await tester.pumpAndSettle();

    verify(() => router.push<void>(AppRoutes.offline)).called(1);
    expect(calls, isEmpty);
  });
}
