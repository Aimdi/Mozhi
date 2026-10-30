import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app_lock/app_lock.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_app_lock_platform.dart';

class _MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class _MockHistoryCubit extends MockCubit<HistoryState> implements HistoryCubit;

class _MockTranslationRepository extends Mock implements TranslationRepository;

/// A screen with a draft in a text field.
class _Draft extends StatefulWidget {
  const new();

  @override
  State<_Draft> createState() => _DraftState();
}

class _DraftState extends State<_Draft> {
  final _controller = TextEditingController(text: 'Secret draft');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const Text('Secret output'),
        TextField(key: const Key('draft'), controller: _controller),
      ],
    ),
  );
}

/// Every label and value in the semantics tree.
List<String> _semanticsTexts(WidgetTester tester) {
  final texts = <String>[];
  void visit(SemanticsNode node) {
    texts
      ..add(node.label)
      ..add(node.value);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  final owner = tester.renderObject(find.byType(MaterialApp)).owner!;
  final root = owner.semanticsOwner?.rootSemanticsNode;
  if (root != null) visit(root);
  return texts.where((text) => text.isNotEmpty).toList();
}

void main() {
  late FakeAppLockPlatform platform;
  late _MockTranslateCubit translate;
  late _MockHistoryCubit history;
  late _MockTranslationRepository repository;
  var listenerLocks = 0;
  var listenerUnlocks = 0;

  setUp(() {
    platform = FakeAppLockPlatform(unlocked: true);
    translate = _MockTranslateCubit();
    history = _MockHistoryCubit();
    repository = _MockTranslationRepository();
    when(() => history.forgetForLock()).thenAnswer((_) async {});
    when(() => history.reloadAfterLock()).thenAnswer((_) async {});
    listenerLocks = 0;
    listenerUnlocks = 0;
  });

  AppLockController create({
    AppLockTimeout timeout = AppLockTimeout.immediately,
  }) => AppLockController(platform: platform, timeout: timeout);

  Future<void> pumpGate(
    WidgetTester tester,
    AppLockController lock, {
    bool providers = true,
    Widget child = const _Draft(),
  }) async {
    addTearDown(lock.dispose);
    Widget app = MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppLockGate(
        lock: lock,
        child: AppLockListener(
          onLock: (_) => listenerLocks++,
          onUnlock: (_) => listenerUnlocks++,
          child: child,
        ),
      ),
    );
    if (providers) {
      app = RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TranslateCubit>.value(value: translate),
            BlocProvider<HistoryCubit>.value(value: history),
          ],
          child: app,
        ),
      );
    }
    await tester.pumpWidget(app);
    await tester.pump();
  }

  Future<void> goTo(WidgetTester tester, List<AppLifecycleState> states) async {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
  }

  Future<void> leave(WidgetTester tester) async {
    platform.leave(Duration.zero);
    await goTo(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
    await tester.pump(Duration.zero);
  }

  /// Comes back; the prompt unlocks unless [platform] says otherwise.
  Future<void> comeBack(WidgetTester tester) async {
    platform.comeBack();
    await goTo(tester, const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await tester.pump();
    await tester.pump();
  }

  group('locking with the screens built', () {
    testWidgets('drops the history and the cache, keeps the translation '
        'hidden, and reads the history again after the unlock', (tester) async {
      await pumpGate(tester, create());
      expect(find.text('Secret output'), findsOneWidget);
      verifyNever(() => history.forgetForLock());

      await leave(tester);

      verify(() => history.forgetForLock()).called(1);
      verify(() => repository.clearCache()).called(1);
      verifyNever(() => history.reloadAfterLock());
      expect(listenerLocks, 1);
      expect(listenerUnlocks, 0);

      await comeBack(tester);

      expect(find.text('Secret output'), findsOneWidget);
      verify(() => history.reloadAfterLock()).called(1);
      verifyNoMoreInteractions(repository);
      expect(listenerLocks, 1);
      expect(listenerUnlocks, 1);
    });

    testWidgets('drops nothing at the first unlock after a start', (
      tester,
    ) async {
      platform.unlocked = false;
      await pumpGate(tester, create());
      await tester.pump();

      expect(find.text('Secret output'), findsOneWidget);
      verifyNever(() => history.forgetForLock());
      verifyNever(() => history.reloadAfterLock());
      expect(listenerLocks, 0);
      expect(listenerUnlocks, 0);
    });

    testWidgets('drops nothing for a return that stays unlocked', (
      tester,
    ) async {
      await pumpGate(tester, create(timeout: AppLockTimeout.after5Minutes));
      platform.leave(const Duration(seconds: 10));
      await goTo(tester, const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
      ]);
      await comeBack(tester);

      expect(find.text('Secret output'), findsOneWidget);
      verifyNever(() => history.forgetForLock());
      expect(listenerLocks, 0);
      expect(listenerUnlocks, 0);
    });

    testWidgets('locks again after a cancelled unlock without dropping '
        'twice', (tester) async {
      await pumpGate(tester, create());
      platform.promptResult = AppLockPromptResult.cancelled;
      await leave(tester);
      await comeBack(tester);
      expect(find.byType(AppLockScreen), findsOneWidget);
      await leave(tester);

      verify(() => history.forgetForLock()).called(1);
      expect(listenerLocks, 1);

      platform.promptResult = AppLockPromptResult.success;
      await comeBack(tester);

      verify(() => history.reloadAfterLock()).called(1);
      expect(listenerUnlocks, 1);
    });

    testWidgets('works without the app-wide state above it', (tester) async {
      await pumpGate(tester, create(), providers: false);
      await leave(tester);
      await comeBack(tester);

      expect(find.text('Secret output'), findsOneWidget);
      expect(listenerLocks, 1);
      expect(listenerUnlocks, 1);
    });
  });

  group('a draft kept while locked', () {
    testWidgets('is neither shown nor in the semantics tree', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpGate(tester, create());
      expect(_semanticsTexts(tester), contains('Secret draft'));
      expect(find.text('Secret draft'), findsOneWidget);

      await leave(tester);
      // Back on the screen (frames again), before the prompt opens.
      await goTo(tester, const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
      ]);

      expect(find.byType(AppLockScreen), findsOneWidget);
      // Kept (the user would lose it), but hidden.
      expect(find.text('Secret draft', skipOffstage: false), findsOneWidget);
      expect(find.text('Secret draft'), findsNothing);
      expect(find.text('Secret output'), findsNothing);
      final texts = _semanticsTexts(tester);
      expect(texts, isNot(contains('Secret draft')));
      expect(texts.any((text) => text.contains('Secret')), isFalse);

      await comeBack(tester);

      expect(find.text('Secret draft'), findsOneWidget);
      expect(_semanticsTexts(tester), contains('Secret draft'));
      semantics.dispose();
    });
  });

  group(AppLockListener, () {
    testWidgets('does nothing without a lock gate', (tester) async {
      await tester.pumpWidget(
        AppLockListener(
          onLock: (_) => listenerLocks++,
          child: const SizedBox(),
        ),
      );

      expect(find.byType(SizedBox), findsOneWidget);
      expect(listenerLocks, 0);
    });

    testWidgets('runs with its own context', (tester) async {
      BuildContext? seen;
      final lock = create();
      await pumpGate(
        tester,
        lock,
        providers: false,
        child: AppLockListener(
          onLock: (context) => seen = context,
          child: const SizedBox(key: Key('inner')),
        ),
      );
      await leave(tester);

      expect(seen, isNotNull);
      expect(seen!.findAncestorWidgetOfExactType<AppLockGate>(), isNotNull);
    });
  });
}
