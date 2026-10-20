import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_languages.dart';

void main() {
  group(AppLanguages, () {
    test('offers every language of lib/l10n/arb', () {
      final arbLocales =
          Directory('lib/l10n/arb')
              .listSync()
              .map((file) => file.uri.pathSegments.last)
              .where((name) => name.startsWith('app_') && name.endsWith('.arb'))
              .map((name) => name.substring(4, name.length - 4))
              .toList()
            ..sort();

      expect(
        AppLanguages.supported.map((locale) => locale.toLanguageTag()).toList()
          ..sort(),
        arbLocales,
      );
      expect(AppLanguages.supported, AppLocalizations.supportedLocales);
    });

    group('resolve', () {
      test('is null for the system default and unknown languages', () {
        expect(AppLanguages.resolve(null), isNull);
        expect(AppLanguages.resolve(''), isNull);
        expect(AppLanguages.resolve('  '), isNull);
        expect(AppLanguages.resolve('sv'), isNull);
      });

      test('finds a supported language', () {
        expect(AppLanguages.resolve('de'), const Locale('de'));
        expect(AppLanguages.resolve(' JA '), const Locale('ja'));
      });

      test('falls back to the language of a regional tag', () {
        expect(AppLanguages.resolve('pt-BR'), const Locale('pt'));
        expect(AppLanguages.resolve('zh_CN'), const Locale('zh'));
      });
    });

    group('nativeName', () {
      test('names each language in itself', () {
        expect(AppLanguages.nativeName(const Locale('de')), 'Deutsch');
        expect(AppLanguages.nativeName(const Locale('ja')), '日本語');
        expect(AppLanguages.nativeName(const Locale('en')), 'English');
        expect(AppLanguages.nativeName(const Locale('ar')), 'العربية');
      });

      test('knows every supported language', () {
        for (final locale in AppLanguages.supported) {
          expect(
            AppLanguages.nativeName(locale),
            isNot(locale.toLanguageTag()),
            reason: '$locale',
          );
        }
      });

      test('falls back to the language tag', () {
        expect(AppLanguages.nativeName(const Locale('xx')), 'xx');
      });
    });

    test('byName sorts by native name, Latin script first', () {
      final names = AppLanguages.byName.map(AppLanguages.nativeName).toList();

      expect(names, hasLength(AppLanguages.supported.length));
      expect(names.first, 'Bahasa Indonesia');
      expect(names.indexOf('Deutsch'), lessThan(names.indexOf('English')));
      expect(names.indexOf('Türkçe'), lessThan(names.indexOf('Русский')));
      expect(names.indexOf('English'), lessThan(names.indexOf('日本語')));
    });

    group('resolveDeviceLocales', () {
      const supported = AppLocalizations.supportedLocales;

      test('matches a supported device language', () {
        expect(
          AppLanguages.resolveDeviceLocales(const [
            Locale('sv', 'SE'),
            Locale('de', 'AT'),
          ], supported),
          const Locale('de'),
        );
        expect(
          AppLanguages.resolveDeviceLocales(const [
            Locale('fr', 'CA'),
          ], supported),
          const Locale('fr'),
        );
      });

      test('falls back to English, not the first supported language', () {
        expect(supported.first, isNot(const Locale('en')));
        expect(
          AppLanguages.resolveDeviceLocales(const [
            Locale('sv', 'SE'),
          ], supported),
          AppLanguages.fallback,
        );
        expect(
          AppLanguages.resolveDeviceLocales(null, supported),
          AppLanguages.fallback,
        );
        expect(
          AppLanguages.resolveDeviceLocales(const [], supported),
          AppLanguages.fallback,
        );
      });

      test('uses the first supported language without English', () {
        expect(
          AppLanguages.resolveDeviceLocales(
            const [Locale('sv')],
            const [Locale('de'), Locale('fr')],
          ),
          const Locale('de'),
        );
      });
    });
  });
}
