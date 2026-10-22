import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/transcribe/transcribe.dart';
import 'package:mozhi/voice/voice.dart';

void main() {
  test('events compare by value', () {
    const phrase = TranscribedPhrase(
      index: 0,
      start: Duration.zero,
      end: Duration(seconds: 1),
      status: PhraseStatus.transcribed,
      text: 'Hi',
    );
    expect(const TranscriberListening(), const TranscriberListening());
    expect(const TranscriberLevel(0.5), isNot(const TranscriberLevel(0.6)));
    expect(const TranscriberLevel(0.5, heardSpeech: true).props, [0.5, true]);
    expect(
      const TranscriberHeard(phrase, pending: 1),
      const TranscriberHeard(phrase, pending: 1),
    );
    expect(const TranscriberPending(2).props, [2]);
    expect(const TranscriberPartial('a'), isNot(const TranscriberPartial('b')));
    expect(const TranscriberFailed(SpeechInputFailure.audio).props, [
      SpeechInputFailure.audio,
    ]);
    expect(phrase.props, [
      0,
      Duration.zero,
      const Duration(seconds: 1),
      PhraseStatus.transcribed,
      'Hi',
      null,
    ]);
  });
}
