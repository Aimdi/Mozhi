import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

enum EngineListStatus { initial, loading, ready, failure }

/// The engines [EngineListCubit] loaded.
class EngineListState extends Equatable {
  const new({this.status = EngineListStatus.initial, this.engines = const []});

  final EngineListStatus status;

  /// In [TranslationRepository.getEngines] order; kept while reloading.
  final List<TranslationEngine> engines;

  /// The engine with [id], or null when it is not available.
  TranslationEngine? engine(String? id) =>
      id == null ? null : engines.where((e) => e.id == id).firstOrNull;

  EngineListState copyWith({
    EngineListStatus? status,
    List<TranslationEngine>? engines,
  }) => EngineListState(
    status: status ?? this.status,
    engines: engines ?? this.engines,
  );

  @override
  List<Object?> get props => [status, engines];
}

/// Loads the available engines from [TranslationRepository.getEngines],
/// e.g. to pick the engines of the quality modes. Errors switch to
/// [EngineListStatus.failure] and are reported via `addError`.
class EngineListCubit extends Cubit<EngineListState> {
  new({required this._repository}) : super(const EngineListState());

  final TranslationRepository _repository;

  /// Loads the engines; [refresh] reloads the Mozhi engine lists.
  Future<void> load({bool refresh = false}) async {
    emit(state.copyWith(status: EngineListStatus.loading));
    try {
      final engines = await _repository.getEngines(refresh: refresh);
      if (isClosed) return;
      emit(
        EngineListState(
          status: EngineListStatus.ready,
          engines: List.unmodifiable(engines),
        ),
      );
    } on Object catch (error, stackTrace) {
      if (!isClosed) emit(state.copyWith(status: EngineListStatus.failure));
      addError(error, stackTrace);
    }
  }
}
