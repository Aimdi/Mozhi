import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/settings_save_failure_listener.dart';

import '../helpers.dart';

const _settingsText =
    "Couldn't save your settings. Changes stay until you close Mozhi.";
const _secretText =
    "Couldn't store your API key or password securely. It works until you "
    'close Mozhi and is never saved unprotected.';

void main() {
  group('SettingsSaveFailureListener', () {
    late StreamController<SettingsSaveFailure> failures;
    late MockSettingsCubit cubit;

    setUp(() {
      failures = StreamController<SettingsSaveFailure>.broadcast();
      cubit = createSettingsCubit();
      when(() => cubit.saveFailures).thenAnswer((_) => failures.stream);
    });

    tearDown(() => failures.close());

    Future<void> pump(
      WidgetTester tester, {
      GlobalKey<ScaffoldMessengerState>? messengerKey,
      SettingsCubit? settings,
    }) => tester.pumpWidget(
      BlocProvider<SettingsCubit>.value(
        value: settings ?? cubit,
        child: MaterialApp(
          scaffoldMessengerKey: messengerKey,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => SettingsSaveFailureListener(
            messengerKey: messengerKey,
            burstGap: const Duration(seconds: 10),
            child: child!,
          ),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );

    Future<void> fail(WidgetTester tester, SettingsSaveFailure failure) async {
      failures.add(failure);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('says the settings could not be saved', (tester) async {
      await pump(tester);
      await fail(tester, SettingsSaveFailure.settings);
      expect(find.text(_settingsText), findsOneWidget);
      // Non-blocking, and it can be closed.
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('says when an API key could not be stored securely', (
      tester,
    ) async {
      await pump(tester);
      await fail(tester, SettingsSaveFailure.secret);
      expect(find.text(_secretText), findsOneWidget);
    });

    testWidgets('tells a burst of failures once', (tester) async {
      await pump(tester);
      await fail(tester, SettingsSaveFailure.settings);
      expect(find.text(_settingsText), findsOneWidget);
      // Dismissed, then more failures follow within the burst.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 5));
        await fail(tester, SettingsSaveFailure.settings);
        expect(find.text(_settingsText), findsNothing);
      }
      // After a quiet gap, a new failure is a new burst.
      await tester.pump(const Duration(seconds: 11));
      await fail(tester, SettingsSaveFailure.settings);
      expect(find.text(_settingsText), findsOneWidget);
    });

    testWidgets('still tells a secret failure during a burst, once', (
      tester,
    ) async {
      await pump(tester);
      await fail(tester, SettingsSaveFailure.settings);
      await fail(tester, SettingsSaveFailure.secret);
      await tester.pumpAndSettle();
      expect(find.text(_secretText), findsOneWidget);
      expect(find.text(_settingsText), findsNothing);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      await fail(tester, SettingsSaveFailure.secret);
      await fail(tester, SettingsSaveFailure.settings);
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(seconds: 11));
    });

    testWidgets('uses the given messenger', (tester) async {
      final key = GlobalKey<ScaffoldMessengerState>();
      await pump(tester, messengerKey: key);
      await fail(tester, SettingsSaveFailure.settings);
      expect(find.text(_settingsText), findsOneWidget);
    });

    testWidgets('stops listening when removed', (tester) async {
      await pump(tester);
      expect(failures.hasListener, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(failures.hasListener, isFalse);
    });
  });
}
