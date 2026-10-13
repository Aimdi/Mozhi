import 'package:equatable/equatable.dart';
import 'package:mozhi/presets/models/glossary.dart';

enum GlossaryStatus { initial, loading, ready, failure }

class GlossaryState extends Equatable {
  const new({
    this.status = GlossaryStatus.initial,
    this.glossaries = const [],
  });

  final GlossaryStatus status;

  /// All glossaries in display order (earlier ones win on conflicts between
  /// equally specific glossaries).
  final List<Glossary> glossaries;

  Glossary? byId(String id) {
    for (final glossary in glossaries) {
      if (glossary.id == id) return glossary;
    }
    return null;
  }

  /// See [mergeActiveGlossaries].
  Map<String, String> activeGlossary({
    required String sourceCode,
    required String targetCode,
  }) => mergeActiveGlossaries(
    glossaries,
    sourceCode: sourceCode,
    targetCode: targetCode,
  );

  GlossaryState copyWith({
    GlossaryStatus? status,
    List<Glossary>? glossaries,
  }) => GlossaryState(
    status: status ?? this.status,
    glossaries: glossaries ?? this.glossaries,
  );

  @override
  List<Object?> get props => [status, glossaries];
}
