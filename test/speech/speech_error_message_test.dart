import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_error_message.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

ConsentRequiredException _consent(
  DataDestination destination, {
  ConsentKind kind = ConsentKind.pair,
}) => ConsentRequiredException(
  kind: kind,
  destination: destination,
  engineId: 'mozhi:google',
  source: 'fr',
  target: 'fr',
);

void main() {
  group('speechErrorMessage', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    test('explains that no voice is available', () {
      expect(
        speechErrorMessage(l10n, const SpeechUnavailableException('fr')),
        l10n.speechUnavailable,
      );
    });

    test('names the instance that could read it with consent', () {
      final error = SpeechUnavailableException(
        'fr',
        cause: _consent(const PublicInstanceDestination('mozhi.example')),
      );

      expect(
        speechErrorMessage(l10n, error),
        l10n.speechUnavailableOnline('mozhi.example'),
      );
      expect(speechListenOnlineLabel(l10n, error), 'Listen online');
    });

    group('online voices', () {
      const google = DeviceVoice(
        name: 'Google français',
        locale: 'fr-FR',
        networkRequired: true,
      );

      test('names the voice and who receives the text', () {
        final error = SpeechUnavailableException(
          'fr',
          cause: SpeechService.onlineVoiceConsent(google),
        );

        expect(
          speechErrorMessage(l10n, error),
          l10n.speechOnlineVoiceConsent('Google français', 'Google'),
        );
        expect(speechListenOnlineLabel(l10n, error), 'Listen online');
      });

      test('says when it is unknown who runs the voice', () {
        final error = SpeechUnavailableException(
          'fr',
          cause: SpeechService.onlineVoiceConsent(
            const DeviceVoice(
              name: 'fr-fr-x-abc-network',
              locale: 'fr-FR',
              networkRequired: true,
            ).withNetworkRequired(online: true),
          ),
        );
        // Google's engine names are shown by variant.
        expect(
          speechErrorMessage(l10n, error),
          l10n.speechOnlineVoiceConsent('Voice ABC', 'Google'),
        );
        final unknown = SpeechUnavailableException(
          'fr',
          cause: SpeechService.onlineVoiceConsent(
            const DeviceVoice(
              name: 'Remote',
              locale: 'fr-FR',
              networkRequired: true,
            ),
          ),
        );
        expect(
          speechErrorMessage(l10n, unknown),
          l10n.speechOnlineVoiceConsentUnknown('Remote'),
        );
      });

      test('says that it may not read in offline-only mode', () {
        final error = SpeechUnavailableException(
          'fr',
          cause: SpeechService.onlineVoiceConsent(
            google,
            kind: ConsentKind.offlineOnly,
          ),
        );

        expect(
          speechErrorMessage(l10n, error),
          l10n.speechOnlineVoiceOfflineOnly('Google français'),
        );
        expect(speechListenOnlineLabel(l10n, error), isNull);
      });
    });

    test('says that offline-only mode sends nothing', () {
      final error = SpeechUnavailableException(
        'fr',
        cause: _consent(
          const PublicInstanceDestination('mozhi.example'),
          kind: ConsentKind.offlineOnly,
        ),
      );

      expect(
        speechErrorMessage(l10n, error),
        l10n.speechUnavailableOfflineOnly,
      );
      expect(speechListenOnlineLabel(l10n, error), isNull);
    });

    test('explains a request the network policy refused', () {
      expect(
        speechErrorMessage(
          l10n,
          const SpeechUnavailableException(
            'fr',
            cause: MozhiApiException(CleartextRefusedException.defaultMessage),
          ),
        ),
        l10n.commonErrorCleartextRefused,
      );
    });

    test('falls back to the generic playback error', () {
      expect(
        speechErrorMessage(l10n, StateError('codec')),
        l10n.translateSpeechError,
      );
      expect(speechListenOnlineLabel(l10n, StateError('codec')), isNull);
    });
  });

  test('speechConsentHost names every destination', () {
    expect(
      speechConsentHost(_consent(const SelfHostedDestination('mozhi.lan'))),
      'mozhi.lan',
    );
    expect(
      speechConsentHost(
        _consent(
          const CloudProviderDestination('DeepL', host: 'api.deepl.com'),
        ),
      ),
      'DeepL',
    );
    expect(speechConsentHost(_consent(const OnDeviceDestination())), isEmpty);
  });
}
