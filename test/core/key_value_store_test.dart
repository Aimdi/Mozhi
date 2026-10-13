import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockSharedPreferencesAsync extends Mock
    implements SharedPreferencesAsync {}

class _MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  group(MemoryStore, () {
    test('starts with a copy of the initial values', () async {
      final initial = {'a': '1'};
      final store = MemoryStore(initial);
      initial['b'] = '2';

      expect(await store.read('a'), '1');
      expect(await store.read('b'), isNull);
    });

    test('writes, reads and deletes values', () async {
      final store = MemoryStore();

      await store.write('key', 'value');
      expect(await store.read('key'), 'value');
      expect(store.values, {'key': 'value'});

      await store.delete('key');
      expect(await store.read('key'), isNull);
    });
  });

  group(PreferencesStore, () {
    late SharedPreferencesAsync prefs;
    late PreferencesStore store;

    setUp(() {
      prefs = _MockSharedPreferencesAsync();
      store = PreferencesStore(prefs);
    });

    test('read delegates to getString', () async {
      when(() => prefs.getString('key')).thenAnswer((_) async => 'value');

      expect(await store.read('key'), 'value');
    });

    test('write delegates to setString', () async {
      when(() => prefs.setString('key', 'value')).thenAnswer((_) async {});

      await store.write('key', 'value');

      verify(() => prefs.setString('key', 'value')).called(1);
    });

    test('delete delegates to remove', () async {
      when(() => prefs.remove('key')).thenAnswer((_) async {});

      await store.delete('key');

      verify(() => prefs.remove('key')).called(1);
    });

    test('creates the platform preferences lazily', () {
      final store = PreferencesStore();

      // No platform implementation is registered in unit tests, so the
      // failure only surfaces once the store is used.
      expect(() => store.read('key'), throwsStateError);
    });
  });

  group(SecureStore, () {
    late FlutterSecureStorage storage;
    late SecureStore store;

    setUp(() {
      storage = _MockFlutterSecureStorage();
      store = SecureStore(storage);
    });

    test('can be created with the default storage', () {
      expect(SecureStore.new, returnsNormally);
    });

    test('read delegates to the secure storage', () async {
      when(() => storage.read(key: 'key')).thenAnswer((_) async => 'secret');

      expect(await store.read('key'), 'secret');
    });

    test('write delegates to the secure storage', () async {
      when(() => storage.write(key: 'key', value: 'secret'))
          .thenAnswer((_) async {});

      await store.write('key', 'secret');

      verify(() => storage.write(key: 'key', value: 'secret')).called(1);
    });

    test('delete delegates to the secure storage', () async {
      when(() => storage.delete(key: 'key')).thenAnswer((_) async {});

      await store.delete('key');

      verify(() => storage.delete(key: 'key')).called(1);
    });
  });
}
