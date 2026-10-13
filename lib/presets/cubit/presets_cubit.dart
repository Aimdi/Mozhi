import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/presets/cubit/presets_state.dart';
import 'package:mozhi/presets/data/presets_repository.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:translation_repository/translation_repository.dart';

export 'presets_state.dart';

/// Manages the user's translation presets. `repository` defaults to a
/// [PresetsRepository] backed by the platform preferences.
///
/// Every change is emitted first and then written through; storage errors
/// are reported via `addError` and never thrown (the in-memory state is
/// kept). [importJson] throws [FormatException] for invalid input.
class PresetsCubit extends Cubit<PresetsState> {
  new({PresetsRepository? repository})
    : _repository = repository ?? PresetsRepository(),
      super(const PresetsState());

  final PresetsRepository _repository;

  Future<void> load() async {
    if (isClosed) return;
    emit(state.copyWith(status: PresetsStatus.loading));
    try {
      final collection = await _repository.load();
      if (isClosed) return;
      emit(
        PresetsState(
          status: PresetsStatus.ready,
          presets: collection.presets,
          defaultId: collection.defaultId,
        ),
      );
    } on Object catch (error, stackTrace) {
      if (!isClosed) emit(state.copyWith(status: PresetsStatus.failure));
      addError(error, stackTrace);
    }
  }

  /// Appends a new preset (and makes it the default when [makeDefault]).
  // Returns the created item so the caller can open or select it.
  // ignore: prefer_void_public_cubit_methods
  Future<Preset> add({
    required String name,
    required TranslationOptions options,
    bool makeDefault = false,
  }) async {
    final preset = Preset(
      id: _repository.newId(),
      name: name.trim(),
      options: Preset.settingsOf(options),
    );
    await _commit([
      ...state.presets,
      preset,
    ], defaultId: makeDefault ? preset.id : state.defaultId);
    return preset;
  }

  /// Replaces the preset with the same id (no-op when it is unknown).
  Future<void> update(Preset preset) async {
    final index = _indexOf(preset.id);
    if (index < 0) return;
    final presets = [...state.presets];
    presets[index] = preset.copyWith(
      name: preset.name.trim(),
      options: Preset.settingsOf(preset.options),
    );
    await _commit(presets);
  }

  /// Removes the preset; clears the default when it was the default.
  Future<void> delete(String id) async {
    if (_indexOf(id) < 0) return;
    await _commit([
      for (final preset in state.presets)
        if (preset.id != id) preset,
    ], defaultId: state.defaultId == id ? null : state.defaultId);
  }

  /// Puts a deleted [preset] back at [index] (clamped), e.g. for undo.
  Future<void> restore(
    Preset preset, {
    required int index,
    bool makeDefault = false,
  }) async {
    final presets = [
      for (final existing in state.presets)
        if (existing.id != preset.id) existing,
    ];
    presets.insert(index.clamp(0, presets.length), preset);
    await _commit(
      presets,
      defaultId: makeDefault ? preset.id : state.defaultId,
    );
  }

  /// Makes [id] the default preset, or clears the default when `null`.
  Future<void> setDefault(String? id) async {
    if (id != null && _indexOf(id) < 0) return;
    if (id == state.defaultId) return;
    await _commit(state.presets, defaultId: id);
  }

  /// Moves the preset at [from] so that it ends up at index [to]
  /// (`ReorderableListView.onReorderItem` semantics). Out-of-range indexes
  /// are ignored.
  Future<void> move(int from, int to) async {
    final length = state.presets.length;
    if (from == to || from < 0 || to < 0 || from >= length || to >= length) {
      return;
    }
    final presets = [...state.presets];
    presets.insert(to, presets.removeAt(from));
    await _commit(presets);
  }

  /// Inserts a copy of [id] right after it, named [name] (defaults to the
  /// original name). The copy is never the default.
  // Returns the created item so the caller can open or select it.
  // ignore: prefer_void_public_cubit_methods
  Future<Preset?> duplicate(String id, {String? name}) async {
    final index = _indexOf(id);
    if (index < 0) return null;
    final original = state.presets[index];
    final copy = Preset(
      id: _repository.newId(),
      name: (name ?? original.name).trim(),
      options: original.options,
    );
    await _commit([...state.presets]..insert(index + 1, copy));
    return copy;
  }

  /// Adds the built-in examples that are missing (by kind).
  // Returns how many examples were restored for the caller to report.
  // ignore: prefer_void_public_cubit_methods
  Future<int> restoreExamples() async {
    final present = {for (final preset in state.presets) preset.builtIn};
    final missing = [
      for (final builtIn in BuiltInPreset.values)
        if (!present.contains(builtIn)) builtIn,
    ];
    if (missing.isEmpty) return 0;
    final ids = {for (final preset in state.presets) preset.id};
    await _commit([
      ...state.presets,
      for (final builtIn in missing) _withFreeId(Preset.example(builtIn), ids),
    ]);
    return missing.length;
  }

  /// Pretty JSON of all presets, or only of [ids].
  // Returns the export for the caller to save or share; it is not state.
  // ignore: prefer_void_public_cubit_methods
  String exportJson({Set<String>? ids}) =>
      _repository.exportJson(state.collection, ids: ids);

  /// Appends the presets in [json] (with new ids) and returns how many were
  /// imported. Throws [FormatException] for invalid input; the state is
  /// unchanged then.
  // Returns how many items were imported for the caller to report.
  // ignore: prefer_void_public_cubit_methods
  Future<int> importJson(String json) async {
    final imported = _repository.parseImport(json);
    if (imported.isEmpty) return 0;
    await _commit([...state.presets, ...imported]);
    return imported.length;
  }

  int _indexOf(String id) => state.presets.indexWhere((p) => p.id == id);

  Preset _withFreeId(Preset preset, Set<String> ids) => ids.contains(preset.id)
      ? preset.copyWith(id: _repository.newId())
      : preset;

  /// Sentinel for "keep the current default".
  static const _keepDefault = '\u0000keep';

  Future<void> _commit(
    List<Preset> presets, {
    String? defaultId = _keepDefault,
  }) async {
    final wanted = defaultId == _keepDefault ? state.defaultId : defaultId;
    final next = PresetsState(
      status: PresetsStatus.ready,
      presets: List.unmodifiable(presets),
      defaultId: presets.any((preset) => preset.id == wanted) ? wanted : null,
    );
    if (isClosed) return;
    emit(next);
    try {
      await _repository.save(next.collection);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }
}
