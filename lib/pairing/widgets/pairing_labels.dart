import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/pairing/models/pairing_failure.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:translation_repository/translation_repository.dart';

/// The name of [item] on the screen: "Your data", "Translation: German",
/// ... [language] is the app language it is for, as this phone knows it
/// (`PairingPlan.language`, `PairingOutgoingItem.language`); without it
/// the item's key is shown as it is.
String pairingItemTitle(
  AppLocalizations l10n,
  PairingItem item, {
  String? language,
}) {
  String name() {
    final code = language ?? item.key;
    return LanguageCatalog.byCode(code)?.name ?? code;
  }

  return switch (item.kind) {
    PairingItemKind.data => l10n.pairingItemData,
    PairingItemKind.translation => l10n.pairingItemTranslation(name()),
    // The voice activity model (`silero-vad`) and the Whisper models.
    PairingItemKind.speech when item.key.contains('vad') =>
      l10n.pairingItemSpeechDetector,
    PairingItemKind.speech => l10n.pairingItemSpeech('Whisper ${item.key}'),
    PairingItemKind.ocr => l10n.pairingItemOcr(name()),
    PairingItemKind.dictionary => l10n.pairingItemDictionary(name()),
  };
}

/// The icon of an item of [kind].
IconData pairingItemIcon(PairingItemKind kind) => switch (kind) {
  PairingItemKind.data => Icons.inventory_2_outlined,
  PairingItemKind.translation => Icons.translate,
  PairingItemKind.speech => Icons.mic_none,
  PairingItemKind.ocr => Icons.document_scanner_outlined,
  PairingItemKind.dictionary => Icons.menu_book_outlined,
};

/// What became of an item, for the results list.
String pairingOutcomeText(
  AppLocalizations l10n,
  PairingItemOutcome outcome, {
  required bool isData,
}) => switch (outcome) {
  PairingItemOutcome.installed when isData => l10n.pairingResultRestored,
  PairingItemOutcome.installed => l10n.pairingResultInstalled,
  PairingItemOutcome.damaged => l10n.pairingResultDamaged,
  PairingItemOutcome.noSpace => l10n.pairingResultNoSpace,
  PairingItemOutcome.incompatible => l10n.pairingItemIncompatible,
  PairingItemOutcome.failed => l10n.pairingResultFailed,
};

/// Why phone to phone stopped, in a sentence.
String pairingFailureMessage(AppLocalizations l10n, PairingFailure failure) =>
    switch (failure) {
      PairingFailure.invalidCode => l10n.pairingFailureInvalidCode,
      PairingFailure.unreachable => l10n.pairingFailureUnreachable,
      PairingFailure.refused => l10n.pairingFailureRefused,
      PairingFailure.expired => l10n.pairingFailureExpired,
      PairingFailure.tooManyAttempts => l10n.pairingFailureTooManyAttempts,
      PairingFailure.sasMismatch => l10n.pairingFailureSasMismatch,
      PairingFailure.declined => l10n.pairingFailureDeclined,
      PairingFailure.cancelled => l10n.pairingFailureCancelled,
      PairingFailure.connectionLost => l10n.pairingFailureConnectionLost,
      PairingFailure.timedOut => l10n.pairingFailureTimedOut,
      PairingFailure.protocol => l10n.pairingFailureProtocol,
      PairingFailure.noSpace => l10n.pairingFailureNoSpace,
      PairingFailure.unknown => l10n.pairingFailureUnknown,
    };
