import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/offline.dart';

void main() {
  const german = OfflineLanguage(
    code: 'de',
    name: 'German',
    nativeName: 'Deutsch',
  );
  const french = OfflineLanguage(
    code: 'fr',
    name: 'French',
    nativeName: 'Français',
  );
  const unknown = OfflineLanguage(code: 'xx', name: 'xx');

  group('OfflineLanguage', () {
    test('matches name, native name and exact code', () {
      expect(german.matches(''), isTrue);
      expect(german.matches('germ'), isTrue);
      expect(german.matches('deutsch'), isTrue);
      expect(german.matches('de'), isTrue);
      expect(german.matches('fr'), isFalse);
      expect(unknown.matches('deu'), isFalse);
      expect(unknown.matches('xx'), isTrue);
    });

    test('supports value equality', () {
      expect(
        german,
        const OfflineLanguage(
          code: 'de',
          name: 'German',
          nativeName: 'Deutsch',
        ),
      );
      expect(german, isNot(french));
    });
  });

  group('OfflineModelOutcome', () {
    test('asks for consent only after a metered network', () {
      const metered = OfflineModelOutcome(
        language: german,
        operation: OfflineModelOperation.download,
        succeeded: false,
        error: OfflineModelError(OfflineModelErrorKind.metered),
      );
      expect(metered.needsMeteredConsent, isTrue);
      expect(
        const OfflineModelOutcome(
          language: german,
          operation: OfflineModelOperation.download,
          succeeded: false,
          error: OfflineModelError(OfflineModelErrorKind.network),
        ).needsMeteredConsent,
        isFalse,
      );
      expect(
        const OfflineModelOutcome(
          language: german,
          operation: OfflineModelOperation.download,
          succeeded: true,
        ).needsMeteredConsent,
        isFalse,
      );
    });
  });

  group('OfflineModelsState', () {
    const state = OfflineModelsState(
      status: OfflineModelsStatus.ready,
      languages: [french, german, unknown],
      downloaded: {'de'},
    );

    test('has sensible defaults', () {
      const initial = OfflineModelsState();
      expect(initial.status, OfflineModelsStatus.initial);
      expect(initial.isAvailable, isTrue);
      expect(initial.wifiOnly, isTrue);
      expect(initial.downloadedCount, 0);
      expect(initial.outcome, isNull);
    });

    test('splits visible languages into downloaded and available', () {
      expect(state.downloadedCount, 1);
      expect(state.isDownloaded('de'), isTrue);
      expect(state.isDownloaded('fr'), isFalse);
      expect(state.visible, [french, german, unknown]);
      expect(state.visibleDownloaded, [german]);
      expect(state.visibleAvailable, [french, unknown]);
    });

    test('filters by query', () {
      final filtered = state.copyWith(query: '  FRAN ');
      expect(filtered.visible, [french]);
      expect(filtered.visibleDownloaded, isEmpty);
      expect(filtered.visibleAvailable, [french]);
    });

    test('knows nothing about sizes without details', () {
      expect(state.hasDetails, isFalse);
      expect(state.isBuiltIn('de'), isFalse);
      expect(state.downloadSizeOf('de'), isNull);
      expect(state.installedSizeOf('de'), isNull);
      expect(state.isOutdated('de'), isFalse);
    });

    test('reports sizes, built-in languages and updates with details', () {
      final detailed = state.copyWith(
        languages: [french, german, unknown],
        downloaded: {'de', 'en'},
        downloadSizes: {'de': 50, 'fr': 40, 'en': 0},
        storage: () => const OfflineStorage(
          installedBytes: {'de': 70},
          totalBytes: 70,
          outdated: {'de', 'fr'},
        ),
        progress: {'fr': 0.5},
      );
      expect(detailed.hasDetails, isTrue);
      expect(detailed.isBuiltIn('en'), isTrue);
      expect(detailed.isBuiltIn('de'), isFalse);
      // English needs no download, so it is not counted.
      expect(detailed.downloadedCount, 1);
      expect(detailed.downloadSizeOf('fr'), 40);
      expect(detailed.installedSizeOf('de'), 70);
      expect(detailed.installedSizeOf('fr'), isNull);
      expect(detailed.isOutdated('de'), isTrue);
      // Only downloaded languages can be outdated.
      expect(detailed.isOutdated('fr'), isFalse);
      expect(detailed.progress, {'fr': 0.5});
      expect(detailed.copyWith(storage: () => null).storage, isNull);
      expect(detailed.copyWith(), detailed);
    });

    test('copyWith keeps or replaces values', () {
      const outcome = OfflineModelOutcome(
        language: german,
        operation: OfflineModelOperation.download,
        succeeded: true,
      );
      final copy = state.copyWith(
        isAvailable: false,
        pending: {'fr': OfflineModelOperation.download},
        wifiOnly: false,
        outcome: () => outcome,
      );
      expect(copy.isAvailable, isFalse);
      expect(copy.pending, {'fr': OfflineModelOperation.download});
      expect(copy.wifiOnly, isFalse);
      expect(copy.outcome, outcome);
      expect(copy.languages, state.languages);
      expect(copy.copyWith(), copy);
      expect(copy.copyWith(outcome: () => null).outcome, isNull);
      expect(copy, isNot(state));
    });
  });
}
