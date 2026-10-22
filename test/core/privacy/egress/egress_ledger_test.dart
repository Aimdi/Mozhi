import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';

const _openAi = EgressDestination(
  kind: EgressDestinationKind.cloudProvider,
  host: 'api.openai.com',
  name: 'OpenAI',
);
const _models = EgressDestination(
  kind: EgressDestinationKind.modelHost,
  host: 'huggingface.co',
  name: 'Hugging Face',
);
const _lan = EgressDestination(
  kind: EgressDestinationKind.localNetwork,
  host: '192.168.1.5',
  port: 3000,
);

void main() {
  late DateTime now;
  late EgressLedger ledger;

  setUp(() {
    now = DateTime(2026, 10, 22, 9);
    ledger = EgressLedger(clock: () => now);
  });

  EgressEntry begin(
    EgressDestination destination, {
    EgressPurpose purpose = EgressPurpose.translation,
    String scheme = 'https',
    bool viaProxy = false,
    int? bytesSent = 10,
  }) => ledger.begin(
    method: 'POST',
    scheme: scheme,
    destination: destination,
    purpose: purpose,
    viaProxy: viaProxy,
    bytesSent: bytesSent,
  );

  test('starts empty, now', () {
    expect(ledger.isEmpty, isTrue);
    expect(ledger.entries, isEmpty);
    expect(ledger.since, now);
    expect(ledger.now(), now);
    expect(ledger.capacity, EgressLedger.defaultCapacity);
  });

  test('records requests with increasing ids and notifies', () async {
    var changes = 0;
    final subscription = ledger.changes.listen((_) => changes++);
    addTearDown(subscription.cancel);

    final first = begin(_openAi);
    now = now.add(const Duration(seconds: 1));
    final second = begin(_models, purpose: EgressPurpose.modelDownload);

    expect(first.id, lessThan(second.id));
    expect(first.startedAt, DateTime(2026, 10, 22, 9));
    expect(first.outcome, EgressOutcome.pending);
    expect(ledger.entries, [first, second]);
    expect(ledger.isEmpty, isFalse);
    expect(changes, 2);

    ledger.update(first.copyWith(outcome: EgressOutcome.succeeded));
    expect(ledger.entries.first.outcome, EgressOutcome.succeeded);
    expect(changes, 3);
  });

  test('update ignores entries that are gone', () {
    final entry = begin(_openAi);
    ledger
      ..clear()
      ..update(entry.copyWith(outcome: EgressOutcome.succeeded));
    expect(ledger.entries, isEmpty);
  });

  test('entries cannot be changed from outside', () {
    begin(_openAi);
    expect(() => ledger.entries.clear(), throwsUnsupportedError);
  });

  test('keeps the newest entries and counts the dropped ones', () {
    ledger = EgressLedger(capacity: 2, clock: () => now);
    final a = begin(_openAi);
    final b = begin(_openAi);
    final c = begin(_openAi);

    expect(ledger.entries, [b, c]);
    expect(ledger.dropped, 1);
    expect(ledger.entries.contains(a), isFalse);
  });

  test('add numbers entries from elsewhere', () {
    final own = begin(_openAi);
    ledger.add(
      EgressEntry(
        id: 0,
        startedAt: now,
        method: 'GET',
        scheme: 'https',
        destination: _models,
        purpose: EgressPurpose.modelDownload,
      ),
    );
    expect(ledger.entries.last.id, own.id + 1);
  });

  test('clear forgets everything and starts a new log', () {
    ledger = EgressLedger(capacity: 1, clock: () => now);
    begin(_openAi);
    begin(_openAi);
    now = now.add(const Duration(minutes: 5));

    ledger.clear();

    expect(ledger.entries, isEmpty);
    expect(ledger.dropped, 0);
    expect(ledger.since, DateTime(2026, 10, 22, 9, 5));
    expect(ledger.isEmpty, isTrue);
  });

  test('summarize groups by destination, content first', () {
    final model = begin(
      _models,
      purpose: EgressPurpose.modelDownload,
      bytesSent: 0,
    );
    ledger.update(
      model.copyWith(bytesReceived: 5000, outcome: EgressOutcome.succeeded),
    );
    begin(_models, purpose: EgressPurpose.modelDownload, bytesSent: 0);
    begin(_models, purpose: EgressPurpose.modelDownload, bytesSent: 0);
    final ai = begin(_openAi, purpose: EgressPurpose.aiModel, viaProxy: true);
    ledger.update(
      ai.copyWith(bytesReceived: 300, outcome: EgressOutcome.succeeded),
    );
    now = now.add(const Duration(seconds: 3));
    begin(_openAi, purpose: EgressPurpose.catalog, bytesSent: null);
    begin(_lan, scheme: 'http');
    // Never sent: not a destination.
    final refused = begin(
      const EgressDestination(
        kind: EgressDestinationKind.publicServer,
        host: 'mozhi.example',
      ),
    );
    ledger.update(refused.copyWith(outcome: EgressOutcome.notSent));

    final summaries = ledger.summarize();

    expect(summaries.map((s) => s.destination), [_openAi, _lan, _models]);
    final openAi = summaries.first;
    expect(openAi.requests, 2);
    expect(openAi.contentRequests, 1);
    expect(openAi.receivedContent, isTrue);
    expect(openAi.bytesSent, 10);
    expect(openAi.bytesReceived, 300);
    expect(openAi.purposes, {EgressPurpose.aiModel, EgressPurpose.catalog});
    expect(openAi.lastAt, DateTime(2026, 10, 22, 9, 0, 3));
    expect(openAi.viaProxy, isTrue);
    expect(openAi.unencrypted, isFalse);
    expect(summaries[1].unencrypted, isTrue);
    final models = summaries.last;
    expect(models.requests, 3);
    expect(models.receivedContent, isFalse);
    expect(models.bytesReceived, 5000);
  });

  test('summaries with the same weight are sorted by name', () {
    begin(_lan, purpose: EgressPurpose.catalog);
    begin(_models, purpose: EgressPurpose.modelDownload);
    expect(ledger.summarize().map((s) => s.destination.authority), [
      '192.168.1.5:3000',
      'huggingface.co',
    ]);
  });

  test('after dispose nothing changes any more', () async {
    final entry = begin(_openAi);
    await ledger.dispose();

    begin(_models);
    ledger
      ..update(entry.copyWith(outcome: EgressOutcome.succeeded))
      ..clear();

    expect(ledger.entries, isEmpty);
  });
}
