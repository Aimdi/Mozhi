import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/sync/models/sync_status.dart';

/// What [failure] means for the user, in a sentence. [cause] is the error
/// behind a [SyncFailure.policy] (which policy rule refused the address).
String describeSyncFailure(
  AppLocalizations l10n,
  SyncFailure failure, {
  Object? cause,
}) => switch (failure) {
  SyncFailure.authFailed => l10n.syncFailureAuth,
  SyncFailure.forbidden => l10n.syncFailureForbidden,
  SyncFailure.notFound => l10n.syncFailureNotFound,
  SyncFailure.notAFolder => l10n.syncFailureNotAFolder,
  SyncFailure.notWebDav => l10n.syncFailureNotWebDav,
  SyncFailure.locked => l10n.syncFailureLocked,
  SyncFailure.insufficientStorage => l10n.syncFailureStorage,
  SyncFailure.tooLarge => l10n.syncFailureTooLarge,
  SyncFailure.tooManyRequests => l10n.syncFailureTooManyRequests,
  SyncFailure.redirected => l10n.syncFailureRedirected,
  SyncFailure.server => l10n.syncFailureServer,
  SyncFailure.offline => l10n.syncFailureOffline,
  SyncFailure.timeout => l10n.syncFailureTimeout,
  SyncFailure.tls => l10n.syncFailureTls,
  SyncFailure.blockedByBrowser => l10n.syncFailureBrowser,
  SyncFailure.policy =>
    describeNetworkPolicyError(l10n, cause) ?? l10n.syncFailurePolicy,
  SyncFailure.conflict => l10n.syncFailureConflict,
  SyncFailure.wrongPassphrase => l10n.syncFailureWrongPassphrase,
  SyncFailure.passphraseChanged => l10n.syncFailurePassphraseChanged,
  SyncFailure.damaged => l10n.syncFailureDamaged,
  SyncFailure.notSyncFile => l10n.syncFailureNotSyncFile,
  SyncFailure.newerVersion => l10n.syncFailureNewerVersion,
  SyncFailure.localData => l10n.syncFailureLocalData,
  SyncFailure.needsUnlock => l10n.syncFailureNeedsUnlock,
  SyncFailure.offlineOnly => l10n.syncOfflineOnlyNotice,
};

/// What a successful sync did, in a sentence.
String describeSyncResult(AppLocalizations l10n, SyncResult result) =>
    switch (result) {
      SyncResult.unchanged => l10n.syncResultUnchanged,
      SyncResult.received => l10n.syncResultReceived,
      SyncResult.sent => l10n.syncResultSent,
      SyncResult.exchanged => l10n.syncResultExchanged,
    };
