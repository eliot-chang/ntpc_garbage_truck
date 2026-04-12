import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import '../models/route_stop.dart';
import 'csv_parser.dart';

/// 台北市垃圾車資料服務
class TaipeiApiService {
  static const _jsonApiUrl =
      'https://data.taipei/api/v1/dataset/a6e90031-7ec4-4089-afb5-361a4efe7202?scope=resourceAquire';
  static const _csvUrl =
      'https://data.taipei/api/frontstage/tpeod/dataset/resource.download?rid=a6e90031-7ec4-4089-afb5-361a4efe7202';
  static const _pageSize = 1000;
  static const _timeout = Duration(seconds: 15);

  final http.Client _client;
  List<RouteStop>? _cachedStops;

  TaipeiApiService({http.Client? client}) : _client = client ?? http.Client();

  /// 載入台北市路線資料
  /// 策略：內建 asset → JSON API → CSV API
  Future<List<RouteStop>> fetchRouteStops({
    void Function(int loaded)? onProgress,
  }) async {
    if (_cachedStops != null) return _cachedStops!;

    // 1. 內建 asset（秒載）
    try {
      final csv = await rootBundle.loadString('assets/taipei_route_stops.csv');
      final stops = _parseTaipeiCsv(csv);
      if (stops.isNotEmpty) {
        _cachedStops = stops;
        onProgress?.call(stops.length);
        return stops;
      }
    } catch (_) {}

    // 2. JSON API（分頁）
    try {
      final stops = await _fetchFromJsonApi(onProgress: onProgress);
      if (stops.isNotEmpty) {
        _cachedStops = stops;
        return stops;
      }
    } catch (_) {}

    // 3. CSV API fallback
    try {
      final response = await _client.get(Uri.parse(_csvUrl)).timeout(_timeout);
      if (response.statusCode == 200 && !response.body.trimLeft().startsWith('<')) {
        final stops = _parseTaipeiCsv(response.body);
        if (stops.isNotEmpty) {
          _cachedStops = stops;
          onProgress?.call(stops.length);
          return stops;
        }
      }
    } catch (_) {}

    return _cachedStops ?? [];
  }

  /// 從 JSON API 分頁載入
  Future<List<RouteStop>> _fetchFromJsonApi({
    void Function(int loaded)? onProgress,
  }) async {
    final allRows = <Map<String, dynamic>>[];
    int offset = 0;

    while (true) {
      final url = '$_jsonApiUrl&limit=$_pageSize&offset=$offset';
      final response = await _client.get(Uri.parse(url)).timeout(_timeout);
      if (response.statusCode != 200) break;

      final json = jsonDecode(response.body);
      final results = json['result']?['results'] as List?;
      if (results == null || results.isEmpty) break;

      allRows.addAll(results.cast<Map<String, dynamic>>());
      offset += _pageSize;
      onProgress?.call(allRows.length);

      final total = json['result']?['count'] as int? ?? 0;
      if (offset >= total) break;
    }

    return _convertJsonRows(allRows);
  }

  /// JSON API 回傳資料轉換為 RouteStop
  List<RouteStop> _convertJsonRows(List<Map<String, dynamic>> rows) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final key = '${row['局編'] ?? ''}_${row['車次'] ?? ''}';
      grouped.putIfAbsent(key, () => []).add(row);
    }

    final stops = <RouteStop>[];
    for (final group in grouped.values) {
      for (int i = 0; i < group.length; i++) {
        final row = group[i];
        final stop = _mapToRouteStop({
          '行政區': row['行政區']?.toString() ?? '',
          '里別': row['里別']?.toString() ?? '',
          '局編': row['局編']?.toString() ?? '',
          '車號': row['車號']?.toString() ?? '',
          '路線': row['路線']?.toString() ?? '',
          '車次': row['車次']?.toString() ?? '',
          '抵達時間': row['抵達時間']?.toString() ?? '',
          '地點': row['地點']?.toString() ?? '',
          '經度': row['經度']?.toString() ?? '',
          '緯度': row['緯度']?.toString() ?? '',
        }, i + 1);
        if (stop != null) stops.add(stop);
      }
    }
    return stops;
  }

  /// 將台北市 CSV 轉換為統一的 RouteStop 格式
  List<RouteStop> _parseTaipeiCsv(String csvContent) {
    // 移除 BOM
    final clean = csvContent.replaceAll('\uFEFF', '');
    final rows = CsvParser.parse(clean);

    // 依路線+車次分組，為每組內的站點編排 rank
    final grouped = <String, List<Map<String, String>>>{};
    for (final row in rows) {
      final key = '${row['局編'] ?? ''}_${row['車次'] ?? ''}';
      grouped.putIfAbsent(key, () => []).add(row);
    }

    final stops = <RouteStop>[];
    for (final entry in grouped.entries) {
      final group = entry.value;
      for (int i = 0; i < group.length; i++) {
        final row = group[i];
        final stop = _mapToRouteStop(row, i + 1);
        if (stop != null) stops.add(stop);
      }
    }

    return stops;
  }

  RouteStop? _mapToRouteStop(Map<String, dynamic> row, int rank) {
    final lat = double.tryParse(row['緯度'] ?? '');
    final lng = double.tryParse(row['經度'] ?? '');
    if (lat == null || lng == null) return null;

    // 抵達時間 "1630" → "16:30"
    final rawTime = row['抵達時間'] ?? '';
    final time = _formatTime(rawTime);

    // 台北市用 局編_車次 作為 lineId
    final lineId = '${row['局編'] ?? ''}_${row['車次'] ?? ''}';
    // 路線名含車次
    final lineName = '${row['路線'] ?? ''}${row['車次'] ?? ''}';

    // 台北市無星期資料，預設週一到週六有服務
    final weekdays = <int, bool>{
      1: true, 2: true, 3: true, 4: true, 5: true, 6: true, 7: false,
    };

    return RouteStop(
      city: row['行政區'] ?? '',
      lineId: lineId,
      lineName: lineName,
      rank: rank,
      name: row['地點'] ?? '',
      village: row['里別'] ?? '',
      longitude: lng,
      latitude: lat,
      time: time,
      memo: '',
      garbageDays: weekdays,
      recyclingDays: weekdays,
      foodScrapsDays: weekdays,
    );
  }

  /// "1630" → "16:30"
  String _formatTime(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 4) {
      return '${digits.substring(0, 2)}:${digits.substring(2)}';
    }
    if (digits.length == 3) {
      return '0${digits.substring(0, 1)}:${digits.substring(1)}';
    }
    return raw;
  }

  void clearCache() => _cachedStops = null;

  void dispose() => _client.close();
}
