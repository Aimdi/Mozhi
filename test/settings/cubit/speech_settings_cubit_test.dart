import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/cubit/speech_settings_cubit.dart';
import 'package:mozhi/speech/speech_service.dart';

class _MockSpeechService extends Mock implements SpeechService;

const _amelie = DeviceVoice(name: 'Amélie', locale: 'fr-CA');

void main() {
  late _MockSpeechService speech;
  late StreamController<String?> speaking;

  setUpAll(() => registerFallbackValue(_amelie));

  setUp(() {
    speech = _MockSpeechService();
    speaking = StreamController<String?>.broadcast();
    when(() => speech.speaking).thenAnswer((_) => speaking.stream);
    when(() => speech.current).thenReturn(null);
    when(() => speech.deviceVoiceSupported).thenReturn(true);
    when(speech.loadSettings)
        .thenAnswer((_) async => const SpeechSettings(rate: 1.2));
    when(() => speech.setSpeechRate(any())).thenAnswer((_) async {});
    when(() => speech.setVoice(any(), any())).thenAnswer((_) async {});
    when(() => speech.deviceVoices(any()))
        .thenAnswer((_) async => const [_amelie]);
    when(
      () => speech.toggle(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
        remember: any(named: 'remember'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => speech.speak(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
        remember: any(named: 'remember'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => speech.previewVoice(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
        voice: any(named: 'voice'),
      ),
    ).thenAnswer((_) async {});
    when(speech.stop).thenAnswer((_) async {});
  });

  tearDown(() => speaking.close());

  SpeechSettingsCubit build() => SpeechSettingsCubit(speech);

  const ready = SpeechSettingsState(
    status: SpeechSettingsStatus.ready,
    settings: SpeechSettings(rate: 1.2),
    deviceVoiceSupported: true,
  );

  group(SpeechSettingsCubit, () {
    test('starts loading with the defaults', () {
      expect(build().state, const SpeechSettingsState());
      expect(build().state.previewingRate, isFalse);
    });

    group('load', () {
      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'reads the settings, device support and current playback',
        setUp: () => when(() => speech.current).thenReturn('target'),
        build: build,
        act: (cubit) => cubit.load(),
        expect: () => [ready.copyWith(speakingId: () => 'target')],
      );

      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'follows what the service reads aloud',
        build: build,
        act: (cubit) async {
          await cubit.load();
          speaking.add(SpeechSettingsCubit.ratePreviewId);
          await Future<void>.delayed(Duration.zero);
          speaking.add(null);
        },
        expect: () => [
          ready,
          ready.copyWith(speakingId: () => SpeechSettingsCubit.ratePreviewId),
          ready,
        ],
      );

      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'subscribes once when loaded twice',
        build: build,
        act: (cubit) async {
          await cubit.load();
          await cubit.load();
          speaking.add('target');
        },
        expect: () => [ready, ready.copyWith(speakingId: () => 'target')],
      );

      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'keeps the defaults when the service fails',
        setUp: () => when(speech.loadSettings).thenThrow(StateError('broken')),
        build: build,
        act: (cubit) => cubit.load(),
        expect: () => [
          const SpeechSettingsState(status: SpeechSettingsStatus.ready),
        ],
        errors: () => [isA<StateError>()],
      );

      group('with a chosen engine-named voice', () {
        const engineVoice = DeviceVoice(
          name: 'fr-fr-x-frd-local',
          locale: 'fr-FR',
        );
        const settings = SpeechSettings(
          voices: {'fr': engineVoice, 'de': _amelie},
        );
        const loaded = SpeechSettingsState(
          status: SpeechSettingsStatus.ready,
          settings: settings,
          deviceVoiceSupported: true,
        );

        blocTest<SpeechSettingsCubit, SpeechSettingsState>(
          'lists the voices of its language to number it',
          setUp: () =>
              when(speech.loadSettings).thenAnswer((_) async => settings),
          build: build,
          act: (cubit) => cubit.load(),
          expect: () => [
            loaded,
            loaded.copyWith(
              voices: const {
                'fr': [_amelie],
              },
            ),
          ],
          verify: (_) {
            verify(() => speech.deviceVoices('fr')).called(1);
            verifyNever(() => speech.deviceVoices('de'));
          },
        );

        blocTest<SpeechSettingsCubit, SpeechSettingsState>(
          'keeps voices listed meanwhile',
          setUp: () {
            when(speech.loadSettings).thenAnswer((_) async => settings);
            when(() => speech.deviceVoices('fr')).thenAnswer((_) async {
              await Future<void>.delayed(Duration.zero);
              return const [];
            });
          },
          build: build,
          act: (cubit) async {
            final loading = cubit.load();
            await Future<void>.delayed(Duration.zero);
            cubit.emit(
              cubit.state.copyWith(
                voices: const {
                  'fr': [engineVoice],
                },
              ),
            );
            await loading;
          },
          verify: (cubit) => expect(cubit.state.voices, const {
            'fr': [engineVoice],
          }),
        );

        test('stops listing after close', () async {
          final voices = Completer<List<DeviceVoice>>();
          when(speech.loadSettings).thenAnswer((_) async => settings);
          when(() => speech.deviceVoices(any()))
              .thenAnswer((_) => voices.future);
          final cubit = build();

          final loading = cubit.load();
          await Future<void>.delayed(Duration.zero);
          await cubit.close();
          voices.complete(const [engineVoice]);
          await loading;

          expect(cubit.state.voices, isEmpty);
        });
      });

      test('ignores settings that arrive after close', () async {
        final settings = Completer<SpeechSettings>();
        when(speech.loadSettings).thenAnswer((_) => settings.future);
        final cubit = build();
        final states = <SpeechSettingsState>[];
        cubit.stream.listen(states.add);

        final loading = cubit.load();
        await cubit.close();
        settings.complete(const SpeechSettings());
        await loading;

        expect(states, isEmpty);
      });
    });

    group('setRate', () {
      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'normalises, applies and saves the rate',
        build: build,
        seed: () => ready,
        act: (cubit) => cubit.setRate(0.74),
        expect: () => [
          ready.copyWith(settings: const SpeechSettings(rate: 0.7)),
        ],
        verify: (_) => verify(() => speech.setSpeechRate(0.7)).called(1),
      );

      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'ignores the same rate',
        build: build,
        seed: () => ready,
        act: (cubit) => cubit.setRate(1.21),
        expect: () => <SpeechSettingsState>[],
        verify: (_) => verifyNever(() => speech.setSpeechRate(any())),
      );

      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'keeps the rate when it cannot be saved',
        setUp: () =>
            when(() => speech.setSpeechRate(any()))
                .thenThrow(Exception('disk full')),
        build: build,
        seed: () => ready,
        act: (cubit) => cubit.setRate(1.5),
        expect: () => [
          ready.copyWith(settings: const SpeechSettings(rate: 1.5)),
        ],
        errors: () => [isException],
      );
    });

    group('setVoice', () {
      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'chooses and saves a voice',
        build: build,
        seed: () => ready,
        act: (cubit) => cubit.setVoice('fr', _amelie),
        expect: () => [
          ready.copyWith(
            settings: const SpeechSettings(rate: 1.2, voices: {'fr': _amelie}),
          ),
        ],
        verify: (_) => verify(() => speech.setVoice('fr', _amelie)).called(1),
      );

      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'resets the voice',
        build: build,
        seed: () => ready.copyWith(
          settings: const SpeechSettings(rate: 1.2, voices: {'fr': _amelie}),
        ),
        act: (cubit) => cubit.setVoice('fr', null),
        expect: () => [ready],
        verify: (_) => verify(() => speech.setVoice('fr', null)).called(1),
      );

      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'ignores unchanged choices',
        build: build,
        seed: () => ready,
        act: (cubit) => cubit.setVoice('fr', null),
        expect: () => <SpeechSettingsState>[],
        verify: (_) => verifyNever(() => speech.setVoice(any(), any())),
      );

      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'keeps the choice when it cannot be saved',
        setUp: () =>
            when(() => speech.setVoice(any(), any()))
                .thenThrow(Exception('disk full')),
        build: build,
        seed: () => ready,
        act: (cubit) => cubit.setVoice('fr', _amelie),
        expect: () => [
          ready.copyWith(
            settings: const SpeechSettings(rate: 1.2, voices: {'fr': _amelie}),
          ),
        ],
        errors: () => [isException],
      );
    });

    group('loadVoices', () {
      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'lists the voices by device tag',
        build: build,
        seed: () => ready,
        act: (cubit) => cubit.loadVoices('fr'),
        expect: () => [
          ready.copyWith(loadingVoicesFor: () => 'fr'),
          ready.copyWith(
            voices: const {
              'fr': [_amelie],
            },
          ),
        ],
      );

      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'ignores unspeakable languages',
        build: build,
        act: (cubit) => cubit.loadVoices('auto'),
        expect: () => <SpeechSettingsState>[],
      );

      test('ignores voices that arrive after close', () async {
        final voices = Completer<List<DeviceVoice>>();
        when(() => speech.deviceVoices(any())).thenAnswer((_) => voices.future);
        final cubit = build();

        final loading = cubit.loadVoices('fr');
        await cubit.close();
        voices.complete(const [_amelie]);
        await loading;

        expect(cubit.state.voices, isEmpty);
      });
    });

    group('previewRate', () {
      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'toggles the rate preview',
        build: build,
        act: (cubit) => cubit.previewRate(text: 'Sample', languageCode: 'en'),
        expect: () => <SpeechSettingsState>[],
        verify: (_) => verify(
          () => speech.toggle(
            id: SpeechSettingsCubit.ratePreviewId,
            text: 'Sample',
            languageCode: 'en',
            remember: false,
          ),
        ).called(1),
      );

      const error = SpeechUnavailableException('en');
      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'reports a failure, and clears it on the next preview',
        setUp: () => when(
          () => speech.toggle(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            remember: any(named: 'remember'),
          ),
        ).thenThrow(error),
        build: build,
        act: (cubit) async {
          await cubit.previewRate(text: 'Sample', languageCode: 'en');
          await cubit.previewRate(text: 'Sample', languageCode: 'en');
        },
        expect: () => [
          const SpeechSettingsState(
            previewError: error,
            failedPreviewId: SpeechSettingsCubit.ratePreviewId,
          ),
          const SpeechSettingsState(),
          const SpeechSettingsState(
            previewError: error,
            failedPreviewId: SpeechSettingsCubit.ratePreviewId,
          ),
        ],
        verify: (cubit) {
          expect(cubit.state.voicePreviewFailed('en'), isFalse);
          expect(
            SpeechSettingsCubit.isVoicePreviewId(cubit.state.failedPreviewId),
            isFalse,
          );
        },
      );
    });

    group('refreshRatePreview', () {
      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'restarts a playing rate preview',
        build: build,
        seed: () =>
            ready.copyWith(speakingId: () => SpeechSettingsCubit.ratePreviewId),
        act: (cubit) async {
          await cubit.previewRate(text: 'Sample', languageCode: 'en');
          await cubit.refreshRatePreview();
        },
        verify: (_) => verify(
          () => speech.speak(
            id: SpeechSettingsCubit.ratePreviewId,
            text: 'Sample',
            languageCode: 'en',
            remember: false,
          ),
        ).called(1),
      );

      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'does nothing when the preview is not playing',
        build: build,
        seed: () => ready,
        act: (cubit) async {
          await cubit.refreshRatePreview();
          await cubit.previewRate(text: 'Sample', languageCode: 'en');
          await cubit.refreshRatePreview();
        },
        verify: (_) => verifyNever(
          () => speech.speak(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            remember: any(named: 'remember'),
          ),
        ),
      );
    });

    group('previewVoice', () {
      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'plays the voice under its preview id',
        build: build,
        act: (cubit) => cubit.previewVoice(
          languageCode: 'iw',
          text: 'עברית',
          voice: _amelie,
        ),
        verify: (_) => verify(
          () => speech.previewVoice(
            id: SpeechSettingsCubit.voicePreviewId('he', _amelie),
            text: 'עברית',
            languageCode: 'iw',
            voice: _amelie,
          ),
        ).called(1),
      );

      const error = SpeechUnavailableException('fr');
      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'reports a failure for the voice picker of its language',
        setUp: () => when(
          () => speech.previewVoice(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            voice: any(named: 'voice'),
          ),
        ).thenThrow(error),
        build: build,
        act: (cubit) => cubit.previewVoice(languageCode: 'fr', text: 'Fr'),
        expect: () => [
          SpeechSettingsState(
            previewError: error,
            failedPreviewId: SpeechSettingsCubit.voicePreviewId('fr', null),
          ),
        ],
        verify: (cubit) {
          expect(cubit.state.voicePreviewFailed('fr'), isTrue);
          expect(cubit.state.voicePreviewFailed('de'), isFalse);
          expect(
            SpeechSettingsCubit.isVoicePreviewId(cubit.state.failedPreviewId),
            isTrue,
          );
        },
      );

      test('preview ids differ per language and voice', () {
        expect(
          SpeechSettingsCubit.voicePreviewId('fr', _amelie),
          isNot(SpeechSettingsCubit.voicePreviewId('fr', null)),
        );
        expect(
          SpeechSettingsCubit.voicePreviewId('fr', null),
          isNot(SpeechSettingsCubit.voicePreviewId('de', null)),
        );
      });
    });

    group('dismissPreviewError', () {
      const error = SpeechUnavailableException('fr');
      final failed = SpeechSettingsState(
        previewError: error,
        failedPreviewId: SpeechSettingsCubit.voicePreviewId('fr', null),
      );

      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'forgets the failed preview',
        build: build,
        seed: () => failed,
        act: (cubit) => cubit.dismissPreviewError(),
        expect: () => [const SpeechSettingsState()],
      );

      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'does nothing without an error',
        build: build,
        act: (cubit) => cubit.dismissPreviewError(),
        expect: () => <SpeechSettingsState>[],
      );

      test('does nothing after close', () async {
        final cubit = build()..emit(failed);
        await cubit.close();

        cubit.dismissPreviewError();

        expect(cubit.state, failed);
      });
    });

    group('stopPreview', () {
      /// A cubit whose service is reading [id] aloud; stopping it reports
      /// idle like the real service.
      Future<SpeechSettingsCubit> playing(String id) async {
        when(speech.stop).thenAnswer((_) async => speaking.add(null));
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.load();
        speaking.add(id);
        await Future<void>.delayed(Duration.zero);
        return cubit;
      }

      test('stops a preview started here', () async {
        final cubit = await playing(
          SpeechSettingsCubit.voicePreviewId('fr', null),
        );

        await cubit.stopPreview();
        await Future<void>.delayed(Duration.zero);

        verify(speech.stop).called(1);
        expect(cubit.state.speakingId, isNull);
      });

      test('leaves other playback alone', () async {
        final cubit = await playing('target');

        await cubit.stopPreview();
        await cubit.close();

        verifyNever(speech.stop);
      });

      blocTest<SpeechSettingsCubit, SpeechSettingsState>(
        'reports a failing stop',
        setUp: () => when(speech.stop).thenThrow(StateError('stuck')),
        build: build,
        seed: () =>
            ready.copyWith(speakingId: () => SpeechSettingsCubit.ratePreviewId),
        act: (cubit) => cubit.stopPreview(),
        // Once for the call and once more when the cubit closes, since the
        // preview is still playing.
        errors: () => [isA<StateError>(), isA<StateError>()],
      );
    });

    test('close stops a playing preview and the subscription', () async {
      final cubit = build();
      await cubit.load();
      speaking.add(SpeechSettingsCubit.ratePreviewId);
      await Future<void>.delayed(Duration.zero);

      await cubit.close();

      verify(speech.stop).called(1);
      expect(speaking.hasListener, isFalse);
    });

    test('ignores playback events after close', () async {
      final cubit = build();
      await cubit.load();
      when(speech.stop).thenAnswer((_) async => speaking.add(null));
      speaking.add(SpeechSettingsCubit.ratePreviewId);
      await Future<void>.delayed(Duration.zero);

      await cubit.close();
      await Future<void>.delayed(Duration.zero);

      expect(cubit.isClosed, isTrue);
    });
  });
}
