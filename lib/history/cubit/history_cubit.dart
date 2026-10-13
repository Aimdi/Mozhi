import 'package:bloc/bloc.dart';
import 'package:mozhi/history/cubit/history_state.dart';
import 'package:mozhi/history/models/history_entry.dart';

export 'history_state.dart';

class HistoryCubit extends Cubit<HistoryState> {
  new()
    : super(const HistoryState());

  Future<void> load() => throw UnimplementedError();
  Future<void> add(HistoryEntry entry) => throw UnimplementedError();
  Future<void> toggleFavorite(String id) => throw UnimplementedError();
  Future<void> delete(String id) => throw UnimplementedError();
  Future<void> clear({bool keepFavorites = false}) =>
      throw UnimplementedError();
  void search(String query) => throw UnimplementedError();
  void setFavoritesOnly({required bool enabled}) => throw UnimplementedError();
  Future<String> exportJson() => throw UnimplementedError();
  Future<void> importJson(String json) => throw UnimplementedError();
}
