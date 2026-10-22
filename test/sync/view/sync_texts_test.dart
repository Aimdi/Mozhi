import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show Locale;
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/sync/models/sync_status.dart';
import 'package:mozhi/sync/view/sync_texts.dart';

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  test('every failure and result has its own sentence', () {
    final failures = {
      for (final failure in SyncFailure.values)
        describeSyncFailure(l10n, failure),
    };
    expect(failures, hasLength(SyncFailure.values.length));
    expect(failures, everyElement(isNotEmpty));
    final results = {
      for (final result in SyncResult.values) describeSyncResult(l10n, result),
    };
    expect(results, hasLength(SyncResult.values.length));
  });

  test('a policy failure says which rule refused the address', () {
    expect(
      describeSyncFailure(
        l10n,
        SyncFailure.policy,
        cause: CleartextRefusedException(null),
      ),
      l10n.commonErrorCleartextRefused,
    );
    expect(
      describeSyncFailure(l10n, SyncFailure.policy),
      l10n.syncFailurePolicy,
    );
  });
}
