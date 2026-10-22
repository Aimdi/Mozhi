import 'package:bergamot_translator/src/engine/web/bergamot_worker.dart';
import 'package:bergamot_translator/src/engine/web/worker_values.dart';
import 'package:bergamot_translator/src/native_language_identifier.dart';

/// [NativeLanguageIdentifier] of the web app: CLD2 compiled into the
/// WebAssembly engine in the worker behind [channel]
/// (`mozhi_bergamot_detect`, both passes in one request).
///
/// The worker handles one request at a time, so an identification waits
/// for a translation that is running there (at most one batch: requests
/// queued by the engine are sent after it).
final class WorkerLanguageIdentifier implements NativeLanguageIdentifier {
  const new(this.channel);

  final BergamotWorkerChannel channel;

  @override
  Future<Cld2Detection?> identify(
    String text, {
    List<String> hints = const [],
  }) async {
    final Object? result;
    try {
      result = await channel.request('identify', {
        'text': text,
        if (hints.isNotEmpty) 'hints': hints.join(','),
      });
    } on BergamotWorkerException catch (error) {
      throw error.toEngineException();
    }
    final map = result.asMap;
    return Cld2Detection(
      precise: readWorkerDetection(map['precise']),
      bestEffort: readWorkerDetection(map['bestEffort']),
    );
  }
}

/// A [Cld2Result] from the worker's copy of `MozhiBergamotDetection`
/// (`{language, languages: [{code, percent, score}], textBytes,
/// reliable}`); `un` slots are dropped.
Cld2Result readWorkerDetection(Object? json) {
  final map = json.asMap;
  return Cld2Result(
    language: map['language'].asString('un'),
    languages: [
      for (final language in map['languages'].asList)
        if (language.asMap case final entry
            when entry['code'].asString().isNotEmpty &&
                entry['code'].asString() != 'un')
          Cld2Language(
            entry['code'].asString(),
            percent: entry['percent'].asInt(),
            score: entry['score'].asInt(),
          ),
    ],
    textBytes: map['textBytes'].asInt(),
    reliable: map['reliable'].asBool,
  );
}
