import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import '../models/route_stop.dart';
import '../models/truck_location.dart';
import 'csv_parser.dart';

class ApiException implements Exception {
  final String message;
  const ApiException(this.message);

  @override
  String toString() => message;
}

class ApiService {
  static const _baseUrl = 'https://data.ntpc.gov.tw/api/datasets';
  static const _routeDatasetId = 'edc3ad26-8ae7-4916-a00b-bc6048d19bf8';
  static const _locationDatasetId = '28ab4122-60e1-4065-98e5-abccb69aaca6';
  static const _pageSize = 1000;
  static const _timeout = Duration(seconds: 15);

  final http.Client _client;

  // 記憶體快取
  List<RouteStop>? _cachedRouteStops;
  List<TruckLocation>? _cachedTruckLocations;

  ApiService({http.Client? client}) : _client = client ?? http.Client();

  // ─── 路線時刻表（離線優先）───

  /// 取得所有路線站點
  /// 策略：先讀內建 CSV asset，若無快取則載入
  Future<List<RouteStop>> fetchAllRouteStops({
    void Function(int loadedPages, int loadedItems)? onProgress,
    bool forceRefresh = false,
  }) async {
    if (_cachedRouteStops != null && !forceRefresh) {
      return _cachedRouteStops!;
    }

    // 1. 嘗試從內建 CSV asset 載入
    try {
      final stops = await _loadRouteStopsFromAsset();
      _cachedRouteStops = stops;
      onProgress?.call(1, stops.length);
      return stops;
    } catch (_) {
      // asset 載入失敗，嘗試 API
    }

    // 2. Fallback: 嘗試從 API 載入
    try {
      final stops = await _fetchRouteStopsFromApi(onProgress: onProgress);
      _cachedRouteStops = stops;
      return stops;
    } catch (e) {
      throw ApiException('無法載入路線資料：$e');
    }
  }

  /// 從內建 asset CSV 載入路線資料
  Future<List<RouteStop>> _loadRouteStopsFromAsset() async {
    final csvString = await rootBundle.loadString('assets/route_stops.csv');
    final rows = CsvParser.parse(csvString);
    return rows.map((row) => RouteStop.fromJson(row)).toList();
  }

  /// 從 CSV API 分頁載入路線資料（不被 WAF 擋）
  Future<List<RouteStop>> _fetchRouteStopsFromApi({
    void Function(int loadedPages, int loadedItems)? onProgress,
  }) async {
    final allStops = <RouteStop>[];
    int page = 0;

    while (true) {
      final url = '$_baseUrl/$_routeDatasetId/csv?page=$page&size=$_pageSize';
      try {
        final response = await _client.get(Uri.parse(url)).timeout(_timeout);
        if (response.statusCode != 200 || response.body.trimLeft().startsWith('<')) break;

        final rows = CsvParser.parse(response.body);
        if (rows.isEmpty) break;

        allStops.addAll(rows.map((row) => RouteStop.fromJson(row)));
        page++;
        onProgress?.call(page, allStops.length);

        if (page > 50) break;
      } catch (_) {
        break;
      }
    }

    return allStops;
  }

  // ─── 即時車輛位置（離線 + 線上）───

  /// 取得即時車輛位置
  /// 策略：先嘗試 CSV API（不被 WAF 擋），再 fallback JSON API，最後用離線 CSV
  Future<List<TruckLocation>> fetchTruckLocations() async {
    // 1. 嘗試 CSV API（即時資料，不被 WAF 擋）
    try {
      final url = '$_baseUrl/$_locationDatasetId/csv?page=0&size=500';
      final response = await _client.get(Uri.parse(url)).timeout(_timeout);
      if (response.statusCode == 200 && !response.body.trimLeft().startsWith('<')) {
        final rows = CsvParser.parse(response.body);
        if (rows.isNotEmpty) {
          final locations = rows
              .map((row) => TruckLocation.fromJson(row))
              .where((t) => t.hasValidCoordinates)
              .toList();
          _cachedTruckLocations = locations;
          return locations;
        }
      }
    } catch (_) {}

    // 2. Fallback: JSON API
    try {
      final url = '$_baseUrl/$_locationDatasetId/json?size=500';
      final data = await _fetchJson(url);
      if (data is List && data.isNotEmpty) {
        final locations = data
            .map((e) => TruckLocation.fromJson(e as Map<String, dynamic>))
            .where((t) => t.hasValidCoordinates)
            .toList();
        _cachedTruckLocations = locations;
        return locations;
      }
    } catch (_) {}

    // 3. Fallback: 內建 CSV
    try {
      final locations = await _loadTruckLocationsFromAsset();
      _cachedTruckLocations = locations;
      return locations;
    } catch (_) {}

    return _cachedTruckLocations ?? [];
  }

  /// 從內建 asset CSV 載入車輛位置
  Future<List<TruckLocation>> _loadTruckLocationsFromAsset() async {
    final csvString =
        await rootBundle.loadString('assets/truck_locations.csv');
    final rows = CsvParser.parse(csvString);
    return rows
        .map((row) => TruckLocation.fromJson(row))
        .where((t) => t.hasValidCoordinates)
        .toList();
  }

  // ─── 通用 HTTP ───

  Future<dynamic> _fetchJson(String url) async {
    try {
      final response = await _client.get(Uri.parse(url)).timeout(_timeout);

      if (response.statusCode == 200) {
        final contentType = response.headers['content-type'] ?? '';
        final body = response.body;
        if (contentType.contains('text/html') || body.trimLeft().startsWith('<')) {
          throw const ApiException('伺服器拒絕存取，已改用離線資料。');
        }
        return jsonDecode(body);
      } else if (response.statusCode == 403) {
        throw const ApiException('伺服器拒絕存取 (403)');
      } else if (response.statusCode >= 500) {
        throw ApiException('伺服器錯誤 (${response.statusCode})');
      } else {
        throw ApiException('請求失敗 (${response.statusCode})');
      }
    } on TimeoutException {
      throw const ApiException('連線逾時');
    } on FormatException {
      throw const ApiException('資料格式錯誤');
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('無法連線：${e.runtimeType}');
    }
  }

  /// 檢查資料來源（供 UI 顯示）
  bool get isUsingOfflineData => _cachedRouteStops != null;

  void clearCache() {
    _cachedRouteStops = null;
    _cachedTruckLocations = null;
  }

  List<RouteStop>? get cachedRouteStops => _cachedRouteStops;

  void dispose() {
    _client.close();
  }
}
