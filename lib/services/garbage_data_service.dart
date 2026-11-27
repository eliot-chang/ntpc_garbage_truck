import 'package:flutter/foundation.dart';
import '../models/route_stop.dart';
import '../models/truck_location.dart';
import 'api_service.dart';
import 'taipei_api_service.dart';
import 'cache_service.dart';

/// 資料來源城市
enum CitySource {
  newTaipei('新北市'),
  taipei('台北市');

  final String label;
  const CitySource(this.label);
}

/// 統一管理台北市與新北市的垃圾車資料
class GarbageDataService extends ChangeNotifier {
  final ApiService _ntpcService;
  final TaipeiApiService _taipeiService;
  final CacheService _cacheService = CacheService();

  CitySource _currentCity = CitySource.newTaipei;
  List<RouteStop> _allStops = [];
  List<TruckLocation> _truckLocations = [];
  List<String> _allCities = [];
  int _loadingCount = 0;

  CitySource get currentCity => _currentCity;
  List<RouteStop> get allStops => _allStops;
  List<TruckLocation> get truckLocations => _truckLocations;
  List<String> get allCities => _allCities;
  bool get isLoading => _loadingCount > 0;

  GarbageDataService({
    ApiService? ntpcService,
    TaipeiApiService? taipeiService,
  })  : _ntpcService = ntpcService ?? ApiService(),
        _taipeiService = taipeiService ?? TaipeiApiService();

  /// 載入路線資料並直接回傳結果（避免並行呼叫雙市時共用 _allStops 產生競態）
  /// 策略：SQLite 快取（24h）→ Asset CSV → API
  Future<List<RouteStop>> loadRouteStops({
    required CitySource city,
    void Function(int loadedPages, int loadedItems)? onProgress,
  }) async {
    _loadingCount++;
    _currentCity = city;
    notifyListeners();

    try {
      // 1. 嘗試 SQLite 快取（24h 內有效）
      final cached = await _cacheService.load(city.name);
      if (cached != null && cached.isNotEmpty) {
        _allStops = cached;
        _allCities = cached.map((s) => s.city).toSet().toList()..sort();
        onProgress?.call(1, cached.length);
        debugPrint('[Cache] ${city.label} 從 SQLite 快取載入 ${cached.length} 筆');
        return cached;
      }

      // 2. 從 Asset / API 載入
      final List<RouteStop> loaded;
      if (city == CitySource.taipei) {
        loaded = await _taipeiService.fetchRouteStops(
          onProgress: (count) => onProgress?.call(1, count),
        );
      } else {
        loaded = await _ntpcService.fetchAllRouteStops(
          onProgress: onProgress,
        );
      }
      _allStops = loaded;
      _allCities = loaded.map((s) => s.city).toSet().toList()..sort();

      // 3. 存入 SQLite 快取
      if (loaded.isNotEmpty) {
        _cacheService.save(city.name, loaded); // 不等待，背景壓縮儲存
        debugPrint('[Cache] ${city.label} 已存入 SQLite 快取 ${loaded.length} 筆');
      }
      return loaded;
    } catch (e) {
      debugPrint('Failed to load route stops: $e');
      rethrow;
    } finally {
      _loadingCount = (_loadingCount - 1).clamp(0, 999);
      notifyListeners();
    }
  }

  /// 載入即時車輛位置（僅新北市有）
  Future<void> loadTruckLocations() async {
    if (_currentCity == CitySource.taipei) {
      _truckLocations = [];
      notifyListeners();
      return;
    }

    try {
      _truckLocations = await _ntpcService.fetchTruckLocations();
    } catch (_) {
      _truckLocations = [];
    }
    notifyListeners();
  }

  void clearCache() {
    _ntpcService.clearCache();
    _taipeiService.clearCache();
    _cacheService.clear();
    _allStops = [];
    _truckLocations = [];
    _allCities = [];
  }

  @override
  void dispose() {
    _ntpcService.dispose();
    _taipeiService.dispose();
    _cacheService.close();
    super.dispose();
  }
}
