import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/instances_page.dart';
import 'package:mozhi/settings/view/widgets/region_names.dart';
import 'package:mozhi_api/mozhi_api.dart' show MozhiPublicInstance;

void main() {
  group('regionName', () {
    test('names every region of the snapshot in every UI language', () {
      final codes = {
        for (final instance in MozhiPublicInstance.all) ...instance.regions,
      };
      expect(codes, isNotEmpty);
      for (final locale in AppLocalizations.supportedLocales) {
        for (final code in codes) {
          expect(
            regionName(code, locale.toString()),
            isNotNull,
            reason: '$code in $locale',
          );
        }
      }
    });

    test('in the UI language, else English', () {
      expect(regionName('DE', 'de'), 'Deutschland');
      expect(regionName('de', 'pt_BR'), 'Alemanha');
      expect(regionName('IN', 'ja'), 'インド');
      expect(regionName('RU', 'xx'), 'Russia');
      expect(regionName('NZ', 'de'), isNull);
    });
  });

  group('catalogRegionNames', () {
    test('joins the names, else falls back to the upstream text', () {
      const both = MozhiPublicInstance(
        url: 'https://a.example',
        country: 'Germany, India',
        regions: ['DE', 'IN'],
      );
      expect(catalogRegionNames(both, 'fr'), 'Allemagne, Inde');
      const unknown = MozhiPublicInstance(
        url: 'https://a.example',
        country: 'Germany, Atlantis',
        regions: ['DE', 'AQ'],
      );
      expect(catalogRegionNames(unknown, 'fr'), 'Germany, Atlantis');
      const none = MozhiPublicInstance(url: 'https://a.example');
      expect(catalogRegionNames(none, 'fr'), isNull);
    });
  });
}
