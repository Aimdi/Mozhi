import 'dart:io';

import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';

/// The offline dictionaries ([DictionaryPacks]) as pairing items: one per
/// installed pack, keyed by its id, its file `<id>.mzd`.
///
/// A phone takes a pack its own catalogue lists with the same size and
/// SHA-256 and installs it with [DictionaryPacks.installFrom], which
/// checks it again.
class DictionaryPairingPacks implements PairingPacks {
  new(this.packs);

  final DictionaryPacks packs;

  @override
  PairingItemKind get kind => PairingItemKind.dictionary;

  @override
  Future<List<PairingOutgoingItem>> outgoing() async => [
    for (final pack in await packs.installed())
      PairingOutgoingItem(
        PairingItem(
          kind: kind,
          key: pack.id,
          files: [
            PairingFile(
              name: '${pack.id}.mzd',
              size: pack.size,
              sha256: pack.sha256,
            ),
          ],
        ),
        {'${pack.id}.mzd': () => packs.read(pack.id)},
        language: pack.language,
      ),
  ];

  @override
  Future<PairingPlan> plan(PairingItem item) async {
    final pack = packs.catalog.byId(item.key);
    if (!packs.isSupported || pack == null) {
      return const PairingPlan.incompatible();
    }
    if ((await packs.installedPack(pack.id))?.sha256 == pack.sha256) {
      return PairingPlan.installed(language: pack.language);
    }
    final expected = PairingFile(
      name: pack.fileName,
      size: pack.size,
      sha256: pack.sha256,
    );
    return matchesOffer(item, expected)
        ? PairingPlan.available([expected], language: pack.language)
        : const PairingPlan.incompatible();
  }

  @override
  Future<PairingItemOutcome> install(PairingItem item, List<File> files) async {
    final pack = packs.catalog.byId(item.key);
    if (pack == null || files.length != 1) {
      return PairingItemOutcome.incompatible;
    }
    try {
      await packs.installFrom(pack, files.single.openRead());
      return PairingItemOutcome.installed;
    } on DictionaryPackChecksumException {
      return PairingItemOutcome.damaged;
    } on DictionaryPackUnsupportedException {
      return PairingItemOutcome.incompatible;
    }
  }
}
