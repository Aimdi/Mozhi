/// Voice input (speech-to-text): the app-wide [SpeechInputService], the
/// [VoiceInputButton] microphone toggle and the
/// [PreferOnDeviceSpeechTile] setting.
library;

import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/widgets/prefer_on_device_speech_tile.dart';
import 'package:mozhi/voice/widgets/voice_input_button.dart';

export 'speech_input_service.dart';
export 'speech_input_state.dart';
export 'speech_locale_matcher.dart';
export 'speech_recognizer_adapter.dart';
export 'widgets/prefer_on_device_speech_tile.dart';
export 'widgets/voice_error_message.dart';
export 'widgets/voice_input_button.dart';
