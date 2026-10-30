import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  const publicInstances = MozhiInstance.publicInstances;
  final newOrder = [for (final instance in publicInstances) instance.url];

  /// The first default list as stored by earlier versions.
  final oldDefaults = [
    for (final url in MozhiInstance.previousDefaultOrders.first)
      MozhiInstance(url: url, label: 'old $url', isCustom: false),
  ];

  List<String> urls(List<MozhiInstance> instances) => [
    for (final instance in instances) instance.url,
  ];

  const own = MozhiInstance(url: 'https://mozhi.example.org', label: 'Mine');
  const other = MozhiInstance(url: 'http://192.168.1.10:3000');

  group('publicInstances', () {
    test('are built in, unique and https', () {
      expect(publicInstances.every((i) => !i.isCustom), isTrue);
      expect(newOrder.toSet(), hasLength(newOrder.length));
      for (final url in newOrder) {
        expect(Uri.parse(url).isScheme('https'), isTrue, reason: url);
      }
    });

    test('start with the servers that translate with Google', () {
      expect(newOrder, [
        'https://mozhi.adminforge.de',
        'https://mozhi.ducks.party',
        'https://mozhi.catsarch.com',
        'https://mzh.dc09.xyz',
        'https://mozhi.aryak.me',
        'https://translate.projectsegfau.lt',
        'https://mozhi.pussthecat.org',
      ]);
    });

    test('list no retired server', () {
      for (final url in newOrder) {
        expect(MozhiInstance.retiredUrls, isNot(contains(url)));
      }
    });

    test('are the previous defaults without the retired servers', () {
      for (final order in MozhiInstance.previousDefaultOrders) {
        expect(order.toSet(), hasLength(order.length));
        expect({
          ...order.where((u) => !MozhiInstance.retiredUrls.contains(u)),
        }, newOrder.toSet());
      }
      expect(
        MozhiInstance.previousDefaultOrders.first.toSet(),
        containsAll(MozhiInstance.retiredUrls),
      );
    });
  });

  group('migrateDefaults', () {
    test('replaces the old default order with the new one', () {
      final migrated = MozhiInstance.migrateDefaults(oldDefaults);
      expect(urls(migrated), newOrder);
      // The current entries, with their labels.
      expect(
        [for (final i in migrated) i.label],
        [for (final i in publicInstances) i.label],
      );
      expect(migrated.every((i) => !i.isCustom), isTrue);
    });

    test('also when the user already removed a retired server', () {
      final stored = oldDefaults
          .where((i) => i.url != 'https://mozhi.canine.tools')
          .toList();
      expect(urls(MozhiInstance.migrateDefaults(stored)), newOrder);
    });

    test('keeps custom instances before and after the defaults', () {
      final migrated = MozhiInstance.migrateDefaults([
        own,
        ...oldDefaults,
        other,
      ]);
      expect(urls(migrated), [own.url, ...newOrder, other.url]);
      expect(migrated.first.label, 'Mine');
      expect(migrated.first.isCustom, isTrue);
    });

    test('keeps a list the user reordered (without retired servers)', () {
      final reordered = [oldDefaults[5], ...oldDefaults]
        ..removeAt(6); // adminforge.de moved to the top.
      final migrated = MozhiInstance.migrateDefaults(reordered);
      expect(urls(migrated), [
        'https://mozhi.adminforge.de',
        'https://mozhi.aryak.me',
        'https://translate.projectsegfau.lt',
        'https://mozhi.ducks.party',
        'https://mozhi.pussthecat.org',
        'https://mzh.dc09.xyz',
        'https://mozhi.catsarch.com',
      ]);
      // The stored entries, labels included.
      expect(migrated.first.label, 'old https://mozhi.adminforge.de');
    });

    test('keeps a list from which the user removed a server', () {
      final stored = oldDefaults
          .where((i) => i.url != 'https://mozhi.aryak.me')
          .toList();
      expect(urls(MozhiInstance.migrateDefaults(stored)), [
        'https://translate.projectsegfau.lt',
        'https://mozhi.ducks.party',
        'https://mozhi.pussthecat.org',
        'https://mozhi.adminforge.de',
        'https://mzh.dc09.xyz',
        'https://mozhi.catsarch.com',
      ]);
    });

    test('keeps custom instances between the defaults where they are', () {
      final stored = [...oldDefaults]..insert(2, own);
      final migrated = MozhiInstance.migrateDefaults(stored);
      expect(urls(migrated), [
        'https://mozhi.aryak.me',
        'https://translate.projectsegfau.lt',
        own.url,
        'https://mozhi.ducks.party',
        'https://mozhi.pussthecat.org',
        'https://mozhi.adminforge.de',
        'https://mzh.dc09.xyz',
        'https://mozhi.catsarch.com',
      ]);
    });

    test('drops retired built-in servers but keeps custom ones', () {
      const customRetired = MozhiInstance(url: 'https://mozhi.bloat.cat');
      final migrated = MozhiInstance.migrateDefaults([
        const MozhiInstance(url: 'https://mozhi.canine.tools', isCustom: false),
        customRetired,
        own,
        const MozhiInstance(
          url: 'https://translate.nerdvpn.de',
          isCustom: false,
        ),
      ]);
      expect(urls(migrated), [customRetired.url, own.url]);
    });

    test('leaves an empty list empty', () {
      expect(MozhiInstance.migrateDefaults(const []), isEmpty);
    });

    test('a list of retired servers only gets the current defaults', () {
      expect(
        MozhiInstance.migrateDefaults([
          for (final url in MozhiInstance.retiredUrls)
            MozhiInstance(url: url, isCustom: false),
        ]),
        MozhiInstance.publicInstances,
      );
    });

    test('keeps a list of custom instances only', () {
      expect(urls(MozhiInstance.migrateDefaults([own, other])), [
        own.url,
        other.url,
      ]);
    });

    test('is idempotent and keeps the current defaults', () {
      expect(urls(MozhiInstance.migrateDefaults(publicInstances)), newOrder);
      final once = MozhiInstance.migrateDefaults([own, ...oldDefaults]);
      expect(MozhiInstance.migrateDefaults(once), once);
    });

    test('returns an unmodifiable list', () {
      expect(
        () => MozhiInstance.migrateDefaults(oldDefaults).add(own),
        throwsUnsupportedError,
      );
      expect(
        () => MozhiInstance.migrateDefaults([own]).add(own),
        throwsUnsupportedError,
      );
    });
  });
}
