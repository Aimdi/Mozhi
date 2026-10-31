import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';

EgressEntry _entry({
  EgressOutcome outcome = EgressOutcome.succeeded,
  EgressPurpose purpose = EgressPurpose.translation,
}) => EgressEntry(
  id: 7,
  startedAt: DateTime(2026, 10, 22, 9, 41, 5),
  method: 'POST',
  scheme: 'https',
  destination: const EgressDestination(
    kind: EgressDestinationKind.cloudProvider,
    host: 'api.openai.com',
    port: 8443,
    name: 'OpenAI',
  ),
  purpose: purpose,
  viaProxy: true,
  bytesSent: 120,
  bytesReceived: 4096,
  statusCode: 200,
  outcome: outcome,
  failure: EgressFailure.timeout,
  duration: const Duration(milliseconds: 320),
  redirectedTo: 'eu.api.openai.com',
);

void main() {
  group('EgressPurpose', () {
    test('only translations, AI requests, speech and photos carry content', () {
      expect(
        [
          for (final purpose in EgressPurpose.values)
            if (purpose.carriesContent) purpose,
        ],
        [
          EgressPurpose.translation,
          EgressPurpose.aiModel,
          EgressPurpose.speech,
          EgressPurpose.image,
        ],
      );
    });
  });

  group('EgressDestinationKind', () {
    test('servers of the user are not third parties', () {
      expect(EgressDestinationKind.thisDevice.isThirdParty, isFalse);
      expect(EgressDestinationKind.localNetwork.isThirdParty, isFalse);
      expect(EgressDestinationKind.hiddenService.isThirdParty, isFalse);
      expect(EgressDestinationKind.cloudProvider.isThirdParty, isTrue);
      expect(EgressDestinationKind.publicServer.isThirdParty, isTrue);
      expect(EgressDestinationKind.modelHost.isThirdParty, isTrue);
      expect(EgressDestinationKind.website.isThirdParty, isTrue);
    });
  });

  group('EgressDestination', () {
    test('authority adds the port and brackets IPv6', () {
      const plain = EgressDestination(
        kind: EgressDestinationKind.publicServer,
        host: 'mozhi.example',
      );
      const port = EgressDestination(
        kind: EgressDestinationKind.localNetwork,
        host: '192.168.1.5',
        port: 3000,
      );
      const ipv6 = EgressDestination(
        kind: EgressDestinationKind.thisDevice,
        host: '::1',
        port: 11434,
      );
      expect(plain.authority, 'mozhi.example');
      expect(port.authority, '192.168.1.5:3000');
      expect(ipv6.authority, '[::1]:11434');
    });
  });

  group('EgressOutcome', () {
    test('only refused requests surely stayed on the device', () {
      for (final outcome in EgressOutcome.values) {
        expect(
          outcome.mayHaveLeftDevice,
          outcome != EgressOutcome.notSent,
          reason: outcome.name,
        );
      }
    });
  });

  group('EgressEntry', () {
    test('carriedContent needs a content purpose and a sent request', () {
      expect(_entry().carriedContent, isTrue);
      expect(_entry(purpose: EgressPurpose.catalog).carriedContent, isFalse);
      expect(_entry(outcome: EgressOutcome.notSent).carriedContent, isFalse);
      expect(_entry(outcome: EgressOutcome.pending).isPending, isTrue);
    });

    test('copyWith replaces the changing fields only', () {
      final entry = _entry(outcome: EgressOutcome.pending);
      final done = entry.copyWith(
        id: 9,
        bytesReceived: 1,
        statusCode: 404,
        outcome: EgressOutcome.httpError,
        failure: EgressFailure.connection,
        duration: const Duration(seconds: 1),
        redirectedTo: 'b.example',
      );
      expect(done.id, 9);
      expect(done.bytesReceived, 1);
      expect(done.statusCode, 404);
      expect(done.outcome, EgressOutcome.httpError);
      expect(done.failure, EgressFailure.connection);
      expect(done.duration, const Duration(seconds: 1));
      expect(done.redirectedTo, 'b.example');
      expect(done.destination, entry.destination);
      expect(done.startedAt, entry.startedAt);
      expect(entry.copyWith(), entry);
    });

    test('toMap holds plain values and fromMap restores them', () {
      final entry = _entry();
      final map = entry.toMap();
      expect(
        map.values.every(
          (v) => v == null || v is String || v is int || v is bool,
        ),
        isTrue,
      );
      expect(EgressEntry.fromMap(map), entry.copyWith(id: 0));
    });

    test('carries the engine through copyWith, toMap and fromMap', () {
      final entry = EgressEntry(
        id: 1,
        startedAt: DateTime(2026),
        method: 'POST',
        scheme: 'https',
        destination: const EgressDestination(
          kind: EgressDestinationKind.publicServer,
          host: 'mozhi.example',
        ),
        purpose: EgressPurpose.translation,
        engine: 'duckduckgo',
      );
      expect(
        entry.copyWith(outcome: EgressOutcome.succeeded).engine,
        'duckduckgo',
      );
      expect(EgressEntry.fromMap(entry.toMap())?.engine, 'duckduckgo');
      expect(
        EgressEntry.fromMap({...entry.toMap(), 'engine': 3})?.engine,
        isNull,
      );
      expect(entry, isNot(EgressEntry.fromMap({...entry.toMap(), 'id': 1})));
    });

    test('fromMap fills in optional values and rejects malformed maps', () {
      final minimal = {
        'startedAt': 0,
        'method': 'GET',
        'scheme': 'https',
        'kind': 'publicServer',
        'host': 'mozhi.example',
        'purpose': 'catalog',
        'outcome': 'pending',
      };
      final entry = EgressEntry.fromMap(minimal)!;
      expect(entry.bytesReceived, 0);
      expect(entry.bytesSent, isNull);
      expect(entry.viaProxy, isFalse);
      expect(entry.failure, isNull);
      expect(entry.destination.port, isNull);

      expect(EgressEntry.fromMap('nope'), isNull);
      expect(EgressEntry.fromMap({...minimal, 'kind': 'moon'}), isNull);
      expect(EgressEntry.fromMap({...minimal, 'purpose': null}), isNull);
      expect(EgressEntry.fromMap({...minimal, 'outcome': 1}), isNull);
      expect(EgressEntry.fromMap({...minimal, 'startedAt': '0'}), isNull);
      expect(EgressEntry.fromMap({...minimal, 'host': 3}), isNull);
    });
  });
}
