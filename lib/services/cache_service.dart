import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../models/route_stop.dart';

/// SQLite 快取服務
/// 將垃圾車路線資料存入本地 DB，24 小時內有效
class CacheService {
  static const _dbName = 'garbage_cache.db';
  static const _tableName = 'route_stops_cache';
  static const _cacheValidityHours = 24;

  Database? _db;

  Future<Database> _getDb() async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, _dbName),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            city_source TEXT PRIMARY KEY,
            data TEXT NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
      },
    );
    return _db!;
  }

  /// 從快取讀取（24h 內有效）
  Future<List<RouteStop>?> load(String citySource) async {
    try {
      final db = await _getDb();
      final rows = await db.query(
        _tableName,
        where: 'city_source = ?',
        whereArgs: [citySource],
      );

      if (rows.isEmpty) return null;

      final updatedAt = rows.first['updated_at'] as int;
      final age = DateTime.now().millisecondsSinceEpoch - updatedAt;
      if (age > _cacheValidityHours * 3600 * 1000) {
        // 快取過期
        return null;
      }

      final jsonStr = rows.first['data'] as String;
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((e) => RouteStop.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// 儲存至快取
  Future<void> save(String citySource, List<RouteStop> stops) async {
    try {
      final db = await _getDb();
      final jsonStr = jsonEncode(stops.map((s) => s.toJson()).toList());
      await db.insert(
        _tableName,
        {
          'city_source': citySource,
          'data': jsonStr,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  /// 清除所有快取
  Future<void> clear() async {
    try {
      final db = await _getDb();
      await db.delete(_tableName);
    } catch (_) {}
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
