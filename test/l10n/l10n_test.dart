import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/bundled_localizations_io.dart';
import 'package:mozhi/l10n/gen/app_localizations_de.dart';
import 'package:mozhi/l10n/gen/app_localizations_en.dart';
import 'package:mozhi/l10n/gen/app_localizations_ja.dart';
import 'package:mozhi/l10n/l10n.dart';

LocalizationsDelegate<AppLocalizations> get _delegate =>
    appLocalizationsDelegates.first as LocalizationsDelegate<AppLocalizations>;

Widget _app(Locale locale) => MaterialApp(
  locale: locale,
  localizationsDelegates: appLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(builder: (context) => Text(context.l10n.commonCancel)),
);

void main() {
  group('on native platforms', () {
    test('every supported language is bundled', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final localizations = bundledAppLocalizations(locale.languageCode);
        expect(
          localizations?.localeName,
          locale.languageCode,
          reason: '$locale',
        );
      }
      expect(bundledAppLocalizations('xx'), isNull);
    });

    test('lookupAppLocalizations answers for every language', () {
      for (final locale in AppLocalizations.supportedLocales) {
        expect(lookupAppLocalizations(locale).localeName, locale.languageCode);
      }
      expect(lookupAppLocalizations(const Locale('pt', 'BR')).localeName, 'pt');
    });

    test('the delegate loads synchronously', () {
      final loaded = _delegate.load(const Locale('ja'));

      expect(loaded, isA<SynchronousFuture<AppLocalizations>>());
      expect(_delegate.isSupported(const Locale('ja')), isTrue);
      expect(_delegate.isSupported(const Locale('xx')), isFalse);
      expect(_delegate.shouldReload(_delegate), isFalse);
      expect(_delegate.type, AppLocalizations);
    });

    testWidgets('the first frame is in the app language', (tester) async {
      await tester.pumpWidget(_app(const Locale('de')));

      expect(find.text(AppLocalizationsDe().commonCancel), findsOneWidget);
    });
  });

  group('like the web build', () {
    setUp(() {
      bundledLocalizations = (_) => null;
      resetLoadedAppLocalizations();
    });
    tearDown(() {
      bundledLocalizations = bundledAppLocalizations;
      resetLoadedAppLocalizations();
    });

    test('English is always at hand', () {
      expect(
        lookupAppLocalizations(const Locale('en')),
        isA<AppLocalizationsEn>(),
      );
      expect(
        _delegate.load(const Locale('en', 'GB')),
        isA<SynchronousFuture<AppLocalizations>>(),
      );
    });

    test('other languages need a preload', () async {
      expect(
        () => lookupAppLocalizations(const Locale('de')),
        throwsA(
          isA<FlutterError>().having(
            (e) => e.message,
            'message',
            contains('preloadAppLocalizations'),
          ),
        ),
      );

      await preloadAppLocalizations(const [
        Locale('de'),
        Locale('en'),
        Locale('xx'),
      ]);

      expect(
        lookupAppLocalizations(const Locale('de')),
        isA<AppLocalizationsDe>(),
      );
      expect(
        _delegate.load(const Locale('de')),
        isA<SynchronousFuture<AppLocalizations>>(),
      );
      expect(
        () => lookupAppLocalizations(const Locale('ja')),
        throwsFlutterError,
      );
    });

    test('a preload of a loaded language does nothing', () async {
      await preloadAppLocalizations(const [Locale('ja')]);
      final first = lookupAppLocalizations(const Locale('ja'));

      await preloadAppLocalizations(const [Locale('ja')]);

      expect(lookupAppLocalizations(const Locale('ja')), same(first));
    });

    test('the delegate loads a language that was not preloaded', () async {
      final loading = _delegate.load(const Locale('ja'));

      expect(loading, isNot(isA<SynchronousFuture<AppLocalizations>>()));
      expect(await loading, isA<AppLocalizationsJa>());
      expect(
        lookupAppLocalizations(const Locale('ja')),
        isA<AppLocalizationsJa>(),
      );
    });

    test('the delegate falls back to English when loading fails', () async {
      expect(
        await _delegate.load(const Locale('xx')),
        isA<AppLocalizationsEn>(),
      );
      await preloadAppLocalizations(const [Locale('xx')]);
    });

    testWidgets('a preloaded language is there on the first frame', (
      tester,
    ) async {
      await tester.runAsync(
        () => preloadAppLocalizations(const [Locale('de')]),
      );

      await tester.pumpWidget(_app(const Locale('de')));

      expect(find.text(AppLocalizationsDe().commonCancel), findsOneWidget);
    });

    testWidgets('any other language shows once it is loaded', (tester) async {
      await tester.pumpWidget(_app(const Locale('de')));
      expect(find.text(AppLocalizationsDe().commonCancel), findsNothing);

      await tester.pumpAndSettle();

      expect(find.text(AppLocalizationsDe().commonCancel), findsOneWidget);
    });
  });
}
