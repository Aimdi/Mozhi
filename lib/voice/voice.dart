/// Voice input (speech-to-text): the app-wide [SpeechInputService] (the
/// system recogniser and offline Whisper, [WhisperSpeechRecognizerAdapter]
/// over [OfflineSpeech]), the [VoiceInputButton] microphone toggle, the
/// [PreferOnDeviceSpeechTile] setting and the [VoiceSettingsCubit] behind
/// the "Voice input" settings.
library;

import 'package:mozhi/voice/cubit/voice_settings_cubit.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/offline/whisper_speech_recognizer_adapter.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/widgets/prefer_on_device_speech_tile.dart';
import 'package:mozhi/voice/widgets/voice_input_button.dart';

export 'cubit/voice_settings_cubit.dart';
export 'offline/offline_speech.dart';
export 'offline/pcm_recorder.dart';
export 'offline/phrase_transcriber.dart';
export 'offline/speech_frames.dart';
export 'offline/utterance_segmenter.dart';
export 'offline/voice_activity.dart';
export 'offline/whisper_speech_recognizer_adapter.dart';
export 'speech_input_service.dart';
export 'speech_input_state.dart';
export 'speech_locale_matcher.dart';
export 'speech_recognizer_adapter.dart';
export 'widgets/browser_speech_notice.dart';
export 'widgets/prefer_on_device_speech_tile.dart';
export 'widgets/voice_error_message.dart';
export 'widgets/voice_input_button.dart';
export 'widgets/voice_model_cancel_button.dart';
export 'widgets/voice_model_offer.dart';
