import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/http_proxy_dialog.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

void main() {
  group('isValidHttpProxy', () {
    test('accepts host:port', () {
      for (final value in [
        '127.0.0.1:8118',
        'localhost:3128',
        ' proxy.example.org:8080 ',
        'my-proxy.lan:1',
        '[::1]:8118',
        '[2001:db8::1]:65535',
      ]) {
        expect(isValidHttpProxy(value), isTrue, reason: value);
      }
    });

    test('rejects anything else', () {
      for (final value in [
        '',
        '127.0.0.1',
        ':8118',
        'host:',
        'host:0',
        'host:65536',
        'host:123456',
        'http://host:8118',
        'user@host:8118',
        'host:8118/path',
        'a..b:8118',
        '-host:8118',
        'host-:8118',
        '[::1:8118',
        '[zz::1]:8118',
        '[1:2:3]:8118',
        'ho st:8118',
        '${'a' * 64}.example:8118',
        '${List.filled(60, 'abcd').join('.')}:8118',
      ]) {
        expect(isValidHttpProxy(value), isFalse, reason: value);
      }
    });
  });

  group(HttpProxyDialog, () {
    late bool closed;
    HttpProxyChoice? result;

    setUp(() {
      closed = false;
      result = null;
    });

    Future<void> open(
      WidgetTester tester, {
      String? initialValue,
      AppSettings settings = const AppSettings(),
    }) async {
      final cubit = _MockSettingsCubit();
      whenListen(
        cubit,
        const Stream<AppSettings>.empty(),
        initialState: settings,
      );
      await tester.pumpWidget(
        BlocProvider<SettingsCubit>.value(
          value: cubit,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<HttpProxyChoice>(
                    context: context,
                    builder: (_) => HttpProxyDialog(initialValue: initialValue),
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

    Finder field() => find.byKey(const Key('settings_http_proxy_field'));

    testWidgets('validates the address', (tester) async {
      await open(tester);

      await tester.enterText(field(), 'nonsense');
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(
        find.text('Enter a host and port, like 127.0.0.1:8118'),
        findsOneWidget,
      );
      expect(closed, isFalse);

      await tester.enterText(field(), '127.0.0.1:8118');
      await tester.pump();
      expect(
        find.text('Enter a host and port, like 127.0.0.1:8118'),
        findsNothing,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      expect(result?.proxy, '127.0.0.1:8118');
    });

    testWidgets('does not take spaces', (tester) async {
      await open(tester);
      await tester.enterText(field(), ' 1.2.3.4 :80');
      expect(tester.widget<TextField>(field()).controller!.text, '1.2.3.4:80');
    });

    testWidgets('an empty field removes the proxy', (tester) async {
      await open(tester, initialValue: '10.0.0.2:3128');
      expect(find.text('10.0.0.2:3128'), findsOneWidget);
      await tester.enterText(field(), '');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      expect(result, same(HttpProxyChoice.remove));
      expect(result?.proxy, isNull);
    });

    testWidgets('Remove only shows with a proxy set', (tester) async {
      await open(tester);
      expect(find.text('Remove'), findsNothing);
    });

    testWidgets('Remove pops the removal', (tester) async {
      await open(tester, initialValue: '10.0.0.2:3128');
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(result, same(HttpProxyChoice.remove));
    });

    testWidgets('cancels', (tester) async {
      await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      expect(result, isNull);
    });

    testWidgets('keeps keyboards from learning while incognito', (
      tester,
    ) async {
      await open(tester, settings: const AppSettings(incognito: true));
      final textField = tester.widget<TextField>(field());
      expect(textField.enableIMEPersonalizedLearning, isFalse);
      expect(textField.autocorrect, isFalse);
      expect(textField.enableSuggestions, isFalse);
    });
  });
}
