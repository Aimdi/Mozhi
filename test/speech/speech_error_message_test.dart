import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_error_message.dart';
import 'package:mozhi/speech/speech_service.dart';

void main() {
  group('speechErrorMessage', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    test('explains that no voice is available', () {
      expect(
        speechErrorMessage(l10n, const SpeechUnavailableException('fr')),
        l10n.speechUnavailable,
      );
    });

    test('falls back to the generic playback error', () {
      expect(
        speechErrorMessage(l10n, StateError('codec')),
        l10n.translateSpeechError,
      );
    });
  });
}
