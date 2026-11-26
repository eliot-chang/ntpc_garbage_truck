import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../models/route_stop.dart';

/// 在背景 Isolate 將站點編碼為精簡 JSON 並 gzip 壓縮
Uint8List _encodeStopsGzip(List<RouteStop> stops) {
  final compact = stops.map((s) => s.toCompact()).toList(growable: false);
  final jsonBytes = utf8.encode(jsonEncode(compact));
  return Uint8List.fromList(gzip.encode(jsonBytes));
}

/// 在背景 Isolate 解壓縮 gzip 並還原站點列表
List<RouteStop> _decodeStopsGzip(Uint8List compressed) {
  final jsonStr = utf8.decode(gzip.decode(compressed));
  final list = jsonDecode(jsonStr) as List;
  return list
      .map((e) => RouteStop.fromCompact(e as List<dynamic>))
      .toList(growable: false);
}

/// SQLite 快取服務
/// 將垃圾車路線資料以精簡格式 + gzip 壓縮存入本地 DB（24 小時內有效）
class CacheService {
  static const _dbName = 'garbage_cache.db';
  static const _tableName = 'route_stops_cache';
  static const _dbVersion = 2;
  static const _cacheValidityHours = 24;

  Database? _db;

  Future<String> _getDbFilePath() async {
    final dbPath = await getDatabasesPath();
    return p.join(dbPath, _dbName);
  }

  Future<Database> _getDb() async {
    if (_db != null) return _db!;
    final fullPath = await _getDbFilePath();
    bool needsVacuum = false;

    _db = await openDatabase(
      fullPath,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            city_source TEXT PRIMARY KEY,
            data BLOB NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v1 → v2：清除舊版未壓縮 JSON 資料表，改用 gzip BLOB
        await db.execute('DROP TABLE IF EXISTS $_tableName');
        await db.execute('''
          CREATE TABLE $_tableName (
            city_source TEXT PRIMARY KEY,
            data BLOB NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        needsVacuum = true;
      },
    );

    if (needsVacuum) {
      try {
        await _db!.execute('VACUUM');
      } catch (_) {}
    }

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
        return null;
      }

      final rawData = rows.first['data'];
      if (rawData is! Uint8List) return null;

      return await compute(_decodeStopsGzip, rawData);
    } catch (_) {
      return null;
    }
  }

  /// 壓縮並儲存至快取
  Future<void> save(String citySource, List<RouteStop> stops) async {
    try {
      final db = await _getDb();
      final compressed = await compute(_encodeStopsGzip, stops);
      await db.insert(
        _tableName,
        {
          'city_source': citySource,
          'data': compressed,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  /// 取得 SQLite 快取檔案佔用大小（bytes）
  Future<int> getCacheSizeBytes() async {
    try {
      final fullPath = await _getDbFilePath();
      int total = 0;
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final file = File('$fullPath$suffix');
        if (await file.exists()) {
          total += await file.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清除所有快取並回收磁碟空間
  Future<void> clear() async {
    try {
      final db = await _getDb();
      await db.delete(_tableName);
      await db.execute('VACUUM');
    } catch (_) {}
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
