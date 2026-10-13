import 'package:flutter_test/flutter_test.dart';
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
