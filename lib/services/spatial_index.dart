import 'dart:math';
import '../models/route_stop.dart';

/// 簡易 Grid 空間索引
/// 將站點依經緯度分配到 gridSize° × gridSize° 的格子中
/// 查詢時只掃描目標周圍的格子，大幅減少距離計算次數
class SpatialIndex {
  static const double _gridSize = 0.01; // ~1.1km × 1km
  static const double _kmPerDegLat = 111.32;

  final Map<String, List<RouteStop>> _grid = {};
  final List<RouteStop> _allStops = [];

  /// 建立索引
  void build(List<RouteStop> stops) {
    _grid.clear();
    _allStops.clear();
    _allStops.addAll(stops);

    for (final stop in stops) {
      if (!stop.hasValidCoordinates) continue;
      final key = _gridKey(stop.latitude, stop.longitude);
      _grid.putIfAbsent(key, () => []).add(stop);
    }
  }

  /// 查詢指定座標半徑 radiusKm 內的站點
  List<RouteStop> queryRadius(double lat, double lng, double radiusKm) {
    final cosLat = cos(lat * pi / 180);
    // 計算需要搜索的格子範圍
    final latRange = radiusKm / _kmPerDegLat;
    final lngRange = radiusKm / (_kmPerDegLat * cosLat);

    final minLatIdx = ((lat - latRange) / _gridSize).floor();
    final maxLatIdx = ((lat + latRange) / _gridSize).ceil();
    final minLngIdx = ((lng - lngRange) / _gridSize).floor();
    final maxLngIdx = ((lng + lngRange) / _gridSize).ceil();

    final result = <RouteStop>[];
    final radiusKmSq = radiusKm * radiusKm;

    for (int latI = minLatIdx; latI <= maxLatIdx; latI++) {
      for (int lngI = minLngIdx; lngI <= maxLngIdx; lngI++) {
        final key = '${latI}_$lngI';
        final cell = _grid[key];
        if (cell == null) continue;

        for (final stop in cell) {
          if (_fastDistKmSq(lat, lng, stop.latitude, stop.longitude, cosLat) <=
              radiusKmSq) {
            result.add(stop);
          }
        }
      }
    }
    return result;
  }

  /// 找離指定座標最近的站點
  RouteStop? findNearest(double lat, double lng, {double maxRadiusKm = 5.0}) {
    final cosLat = cos(lat * pi / 180);
    RouteStop? nearest;
    double minDist = double.infinity;

    // 從小範圍開始找，逐步擴大
    for (double r = _gridSize * 111; r <= maxRadiusKm; r *= 2) {
      final candidates = queryRadius(lat, lng, r);
      for (final stop in candidates) {
        final dist = _fastDistKmSq(lat, lng, stop.latitude, stop.longitude, cosLat);
        if (dist < minDist) {
          minDist = dist;
          nearest = stop;
        }
      }
      if (nearest != null) break; // 找到就不用擴大了
    }
    return nearest;
  }

  bool get isEmpty => _allStops.isEmpty;
  int get length => _allStops.length;

  static String _gridKey(double lat, double lng) {
    final latIdx = (lat / _gridSize).floor();
    final lngIdx = (lng / _gridSize).floor();
    return '${latIdx}_$lngIdx';
  }

  /// 等距平面近似距離平方（1–5 km 誤差 < 0.05%，完全避免 sqrt 與逐點三角函數）
  static double _fastDistKmSq(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
    double cosLat,
  ) {
    final dLatKm = (lat2 - lat1) * _kmPerDegLat;
    final dLngKm = (lng2 - lng1) * _kmPerDegLat * cosLat;
    return dLatKm * dLatKm + dLngKm * dLngKm;
  }
}
