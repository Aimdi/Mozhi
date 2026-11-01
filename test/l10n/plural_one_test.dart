import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/l10n/gen/app_localizations_pl.dart';
import 'package:mozhi/l10n/gen/app_localizations_ru.dart';
import 'package:mozhi/l10n/gen/app_localizations_uk.dart';
import 'package:mozhi/l10n/l10n.dart';

/// gen-l10n puts `=1` and `one` into the same argument (the later wins), so
/// these messages once read "none of the 1 servers" for exactly one.
void main() {
  final locales = <String, AppLocalizations>{
    'pl': AppLocalizationsPl(),
    'ru': AppLocalizationsRu(),
    'uk': AppLocalizationsUk(),
  };

  group('exactly one volunteer server', () {
    const one = {
      'pl':
          'Serwer wolontariuszy nie mógł teraz przetłumaczyć tekstu za '
          'pomocą Google.',
      'ru':
          'Волонтёрскому серверу сейчас не удалось перевести текст с '
          'помощью Google.',
      'uk':
          'Волонтерському серверу зараз не вдалося перекласти текст за '
          'допомогою Google.',
    };

    for (final MapEntry(key: code, value: l10n) in locales.entries) {
      test('$code: translateErrorAllServersFailed is singular for 1', () {
        final message = l10n.translateErrorAllServersFailed(1, 'Google');
        expect(message, startsWith(one[code]!));
        expect(message, isNot(contains(' 1 ')));
        // More servers still name the number.
        expect(l10n.translateErrorAllServersFailed(3, 'Google'), contains('3'));
        expect(l10n.translateErrorAllServersFailed(5, 'Google'), contains('5'));
      });

      test('$code: commonConsentMozhiListNote names the other server', () {
        expect(l10n.commonConsentMozhiListNote(1), isNot(contains('1')));
        expect(l10n.commonConsentMozhiListNote(3), contains('3'));
      });
    }
  });

  test('one online voice is "it", not "they"', () {
    expect(
      locales['ru']!.speechOnlineVoicesSubtitle(1),
      startsWith('1 онлайн-голос может читать вслух. Он отправляет'),
    );
    expect(
      locales['uk']!.speechOnlineVoicesSubtitle(1),
      startsWith('1 онлайн-голос може читати вголос. Він надсилає'),
    );
    expect(
      locales['ru']!.speechOnlineVoicesSubtitle(3),
      contains('Они отправляют'),
    );
  });

  test('counts read the same as before for one', () {
    // `=1` was overridden by `one` and is gone: nothing changes.
    expect(locales['pl']!.historyFilterPairCount(1), '1 tłumaczenie');
    expect(locales['ru']!.historyFilterPairCount(1), '1 перевод');
    expect(locales['uk']!.historyFilterPairCount(21), '21 переклад');
  });
}
