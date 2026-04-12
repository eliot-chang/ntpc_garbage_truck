import 'dart:math';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/route_stop.dart';
import '../models/truck_location.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  final Set<String> _notifiedKeys = {};
  int _nextId = 0;

  Future<void> init() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(initSettings);
  }

  Future<bool> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }
    return false;
  }

  /// 檢查所有最愛站點，車輛接近時發送通知
  Future<void> checkAndNotify({
    required List<RouteStop> allStops,
    required List<TruckLocation> truckLocations,
    required List<RouteStop> favorites,
    required int stopsBeforeArrival,
  }) async {
    final now = DateTime.now();

    for (final fav in favorites) {
      // 今天沒服務就跳過
      if (!fav.hasServiceOnWeekday(now.weekday)) continue;

      // 已過站就跳過
      final parts = fav.time.split(':');
      if (parts.length == 2) {
        final h = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        if (h != null && m != null && h * 60 + m < now.hour * 60 + now.minute) continue;
      }

      // 找同路線的車輛
      TruckLocation? truck;
      for (final t in truckLocations) {
        if (t.lineId == fav.lineId && t.hasValidCoordinates && t.isRecent) {
          truck = t;
          break;
        }
      }
      if (truck == null) continue;

      // 找車輛最近的站點 rank
      final routeStops = allStops
          .where((s) => s.lineId == fav.lineId && s.hasValidCoordinates)
          .toList();
      final truckRank = _findNearestStopRank(routeStops, truck);
      if (truckRank == null) continue;

      // 車輛在最愛站點之前 X 站以內
      final stopsAway = fav.rank - truckRank;
      if (stopsAway > 0 && stopsAway <= stopsBeforeArrival) {
        final key = '${fav.lineId}_${fav.rank}_${now.year}_${now.month}_${now.day}';
        if (_notifiedKeys.contains(key)) continue;
        _notifiedKeys.add(key);

        await _showNotification(fav, stopsAway);
      }
    }
  }

  int? _findNearestStopRank(List<RouteStop> stops, TruckLocation truck) {
    int? nearestRank;
    double minDist = double.infinity;
    for (final stop in stops) {
      final dist = _distanceKm(
        truck.latitude, truck.longitude,
        stop.latitude, stop.longitude,
      );
      if (dist < minDist) {
        minDist = dist;
        nearestRank = stop.rank;
      }
    }
    return nearestRank;
  }

  static double _distanceKm(double lat1, double lng1, double lat2, double lng2) {
    const R = 6371.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLng / 2) * sin(dLng / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  Future<void> _showNotification(RouteStop stop, int stopsAway) async {
    const androidDetails = AndroidNotificationDetails(
      'truck_approaching',
      '垃圾車接近通知',
      channelDescription: '垃圾車即將到達最愛站點時通知',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      _nextId++,
      '🚛 垃圾車即將到達！',
      '${stop.lineName} 還有 $stopsAway 站到 ${stop.name}（${stop.time}）',
      details,
    );
  }

  /// 每日重置通知記錄
  void resetDailyKeys() => _notifiedKeys.clear();
}
