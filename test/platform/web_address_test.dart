import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/platform/web_address.dart';
import 'package:mozhi/platform/web_storage_changes.dart';

void main() {
  group('addressWithoutQuery', () {
    test('drops the query, keeping the path and the route', () {
      expect(
        addressWithoutQuery(
          Uri.parse('https://host.test/Mozhi/app/?text=hola&to=en#/translate'),
        ),
        '/Mozhi/app/#/translate',
      );
      expect(
        addressWithoutQuery(Uri.parse('https://host.test/?text=a%20b')),
        '/',
      );
      expect(
        addressWithoutQuery(Uri.parse('https://host.test?text=x#/a%20b?c=1')),
        '/#/a%20b?c=1',
      );
    });

    test('is null without a query', () {
      expect(addressWithoutQuery(Uri.parse('https://host.test/#/x')), isNull);
      expect(
        addressWithoutQuery(Uri.parse('https://host.test/#/translate?text=x')),
        isNull,
      );
    });
  });

  group('clearWebAddressQuery', () {
    test('replaces an address with a query', () {
      final replaced = <String>[];
      clearWebAddressQuery(
        address: Uri.parse('https://host.test/app/?text=hola#/translate'),
        replace: replaced.add,
      );
      expect(replaced, ['/app/#/translate']);
    });

    test('leaves an address without a query', () {
      final replaced = <String>[];
      clearWebAddressQuery(
        address: Uri.parse('https://host.test/app/#/translate'),
        replace: replaced.add,
      );
      expect(replaced, isEmpty);
    });

    test('does nothing outside a browser', () {
      clearWebAddressQuery(address: Uri.parse('https://host.test/?text=x'));
    });
  });

  group('addressWithoutRouteQuery', () {
    test('drops the query of the route, keeping the rest', () {
      expect(
        addressWithoutRouteQuery(
          Uri.parse('https://host.test/app/#/proofread?text=Hallo%20Welt'),
        ),
        '/app/#/proofread',
      );
      expect(
        addressWithoutRouteQuery(Uri.parse('https://host.test?a=1#/p?text=x')),
        '/?a=1#/p',
      );
    });

    test('is null without a query in the route', () {
      expect(addressWithoutRouteQuery(Uri.parse('https://host.test/')), isNull);
      expect(
        addressWithoutRouteQuery(Uri.parse('https://host.test/?text=x#/p')),
        isNull,
      );
    });
  });

  group('clearWebRouteQuery', () {
    test('replaces an address whose route has a query', () {
      final replaced = <String>[];
      clearWebRouteQuery(
        address: Uri.parse('https://host.test/#/proofread?text=x'),
        replace: replaced.add,
      );
      clearWebRouteQuery(
        address: Uri.parse('https://host.test/#/proofread'),
        replace: replaced.add,
      );
      expect(replaced, ['/#/proofread']);
    });

    test('does nothing outside a browser', () {
      clearWebRouteQuery(address: Uri.parse('https://host.test/#/p?text=x'));
    });
  });

  test('no other tab changes the storage outside a browser', () async {
    expect(await webStorageChanges().isEmpty, isTrue);
  });
}
