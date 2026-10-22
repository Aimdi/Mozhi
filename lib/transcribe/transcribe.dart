/// Transcribe: a rolling transcript of a lecture, a tour or a meeting,
/// phrase by phrase with times ([TranscribePage], [TranscribeCubit]), heard
/// by on-device Whisper ([WhisperTranscriber]) or a browser's continuous
/// recognition ([SystemTranscriber]), with a translation of each phrase
/// when the user turns it on, and text / SRT export ([TranscriptExport]).
library;

import 'package:mozhi/transcribe/cubit/transcribe_cubit.dart';
import 'package:mozhi/transcribe/data/transcriber.dart';
import 'package:mozhi/transcribe/data/transcript_export.dart';
import 'package:mozhi/transcribe/view/transcribe_page.dart';

export 'cubit/transcribe_cubit.dart';
export 'data/screen_awake.dart';
export 'data/transcriber.dart';
export 'data/transcript_export.dart';
export 'models/transcript_entry.dart';
export 'view/transcribe_page.dart';
export 'widgets/transcribe_controls.dart';
export 'widgets/transcribe_options.dart';
export 'widgets/transcript_list.dart';
