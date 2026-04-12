import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/route_stop.dart';

/// 最愛站點服務（使用 SharedPreferences 持久化）
class FavoritesService extends ChangeNotifier {
  static const _key = 'favorite_stops';
  final List<RouteStop> _favorites = [];

  List<RouteStop> get favorites => List.unmodifiable(_favorites);

  bool isFavorite(String lineId, int rank) {
    return _favorites.any((s) => s.lineId == lineId && s.rank == rank);
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_key);
    if (jsonStr == null) return;

    try {
      final list = jsonDecode(jsonStr) as List;
      _favorites.clear();
      for (final item in list) {
        _favorites.add(RouteStop.fromJson(Map<String, dynamic>.from(item)));
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> add(RouteStop stop) async {
    if (isFavorite(stop.lineId, stop.rank)) return;
    _favorites.add(stop);
    notifyListeners();
    await _save();
  }

  Future<void> remove(String lineId, int rank) async {
    _favorites.removeWhere((s) => s.lineId == lineId && s.rank == rank);
    notifyListeners();
    await _save();
  }

  Future<void> toggle(RouteStop stop) async {
    if (isFavorite(stop.lineId, stop.rank)) {
      await remove(stop.lineId, stop.rank);
    } else {
      await add(stop);
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _favorites.map((s) => s.toJson()).toList();
    await prefs.setString(_key, jsonEncode(list));
  }
}
