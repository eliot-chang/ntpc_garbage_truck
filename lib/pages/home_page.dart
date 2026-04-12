import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import '../models/route_stop.dart';
import '../models/truck_location.dart';
import '../services/favorites_service.dart';
import '../services/settings_service.dart';
import '../services/notification_service.dart';
import '../services/garbage_data_service.dart';
import '../services/spatial_index.dart';

enum TimePeriod {
  morning('上午'), afternoon('下午'), evening('晚上');
  final String label;
  const TimePeriod(this.label);
}

const _weekdayLabels = {
  1: '一', 2: '二', 3: '三', 4: '四',
  5: '五', 6: '六', 7: '日',
};

class HomePage extends StatefulWidget {
  final FavoritesService favoritesService;
  final SettingsService settingsService;
  const HomePage({super.key, required this.favoritesService, required this.settingsService});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  GoogleMapController? _mapController;
  final GarbageDataService _dataService = GarbageDataService();

  // 兩市資料分開存
  List<RouteStop> _ntpcStops = [];
  List<RouteStop> _taipeiStops = [];
  List<TruckLocation> _truckLocations = [];

  // 空間索引
  final SpatialIndex _ntpcIndex = SpatialIndex();
  final SpatialIndex _taipeiIndex = SpatialIndex();
  SpatialIndex get _currentIndex => _citySource == CitySource.taipei ? _taipeiIndex : _ntpcIndex;

  // 目前選中的市 → 對應的 stops
  CitySource _citySource = CitySource.newTaipei;
  List<RouteStop> get _allStops => _citySource == CitySource.taipei ? _taipeiStops : _ntpcStops;
  List<String> _allCities = [];
  double _currentZoom = 16;

  bool _isLoadingRoutes = true;
  bool _isLoadingTrucks = false;
  bool _iconsReady = false;
  String? _errorMessage;
  String? _dataSourceInfo;
  Timer? _dataSourceTimer;
  Timer? _progressTimer;
  Timer? _cameraDebounce;
  static const _refreshIntervalSec = 30;
  int _loadedPages = 0;
  int _loadedItems = 0;
  String? _selectedCity;
  int _selectedWeekday = DateTime.now().weekday;
  TimePeriod _selectedPeriod = _defaultPeriod();
  final Set<String> _selectedRouteIds = {};
  LatLng _pinPosition = _defaultPosition;

  // icon 快取
  final Map<int, BitmapDescriptor> _dotIconCache = {};
  BitmapDescriptor? _passedGreyIcon;
  final Map<int, BitmapDescriptor> _truckAtStopIconCache = {};
  final Map<int, BitmapDescriptor> _arrowIconCache = {};
  BitmapDescriptor? _passedArrowIcon;

  // 地圖元素快取（避免每次 build 重算）
  Set<Polyline> _cachedPolylines = {};
  Set<Marker> _cachedMarkers = {};
  Set<Circle> _cachedCircles = {};
  Map<String, List<RouteStop>> _cachedVisibleRoutes = {};
  List<String> _cachedRouteKeys = [];

  // 進度條用 ValueNotifier，不觸發整棵 widget tree rebuild
  final ValueNotifier<double> _refreshProgressNotifier = ValueNotifier(0.0);

  static const LatLng _defaultPosition = LatLng(25.0143, 121.4611);
  static const double _radiusKm = 1.0;

  // WCAG AA 高對比色（4.5:1+ 對白底）
  static const List<Color> _routeColors = [
    Color(0xFF0055B8), // 深藍
    Color(0xFFC62828), // 深紅
    Color(0xFF2E7D32), // 深綠
    Color(0xFF6A1B9A), // 深紫
    Color(0xFF00695C), // 深青
    Color(0xFFAD1457), // 深粉
    Color(0xFF283593), // 深靛
    Color(0xFF4E342E), // 深棕
    Color(0xFF00838F), // 深藍綠
    Color(0xFFE65100), // 深橘
  ];

  static TimePeriod _defaultPeriod() {
    final hour = DateTime.now().hour;
    if (hour < 12) return TimePeriod.morning;
    if (hour < 17) return TimePeriod.afternoon;
    return TimePeriod.evening;
  }

  @override
  void initState() {
    super.initState();
    _init();
    widget.settingsService.addListener(_onSettingsChanged);
    _startProgressTimer();
  }

  Future<void> _createIcons() async {
    for (final color in _routeColors) {
      _dotIconCache[color.hashCode] = await _createCircleIcon(color, 10);
      _truckAtStopIconCache[color.hashCode] = await _createTruckIcon(color);
      _arrowIconCache[color.hashCode] = await _createArrowIcon(color);
    }
    _passedGreyIcon = await _createCircleIcon(const Color(0xFFD0D0D0), 10);
    _passedArrowIcon = await _createArrowIcon(const Color(0xFFD0D0D0));
  }

  /// 圓點 icon
  Future<BitmapDescriptor> _createCircleIcon(Color color, int size) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawCircle(Offset(size.toDouble(), size.toDouble()), size - 1,
        Paint()..color = color);
    canvas.drawCircle(Offset(size.toDouble(), size.toDouble()), size - 1,
        Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = (size <= 5 ? 1 : 2));
    final picture = recorder.endRecording();
    final image = await picture.toImage(size * 2, size * 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
  }

  /// 🚛 icon：路線色邊框圓形 + 🚛 emoji
  Future<BitmapDescriptor> _createTruckIcon(Color color) async {
    const size = 15;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final s = size.toDouble();

    // 白色填充圓
    canvas.drawCircle(Offset(s, s), s - 1, Paint()..color = Colors.white);
    // 路線色邊框
    canvas.drawCircle(Offset(s, s), s - 1,
        Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2.5);

    // 繪製 🚛 文字
    final textPainter = TextPainter(
      text: const TextSpan(text: '🚛', style: TextStyle(fontSize: 12)),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, Offset(
      s - textPainter.width / 2,
      s - textPainter.height / 2,
    ));

    final picture = recorder.endRecording();
    final image = await picture.toImage(size * 2, size * 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
  }

  /// 實心小箭頭 icon（朝上，rotation 由 Marker 控制）
  Future<BitmapDescriptor> _createArrowIcon(Color color) async {
    const size = 8;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final s = size.toDouble();

    // 實心三角形（朝上）
    final path = Path()
      ..moveTo(s, 2)        // 頂點
      ..lineTo(s * 2 - 2, s * 2 - 2) // 右下
      ..lineTo(2, s * 2 - 2)         // 左下
      ..close();
    canvas.drawPath(path, Paint()..color = color);

    final picture = recorder.endRecording();
    final image = await picture.toImage(size * 2, size * 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
  }

  Future<void> _init() async {
    try {
      await _createIcons();
    } catch (e) {
      debugPrint('Icon creation failed: $e');
    }
    if (mounted) setState(() => _iconsReady = true);
    await _getCurrentLocation();
    // 先載入兩市資料
    await _loadBothCities();
    // 載入後用資料判斷最近的市
    _citySource = _detectCityFromData(_pinPosition);
    _refreshCityList();
    _autoSelectCity();
    _updateVisibleRoutes();
    _loadTruckLocations();
  }

  Future<void> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }
      if (permission == LocationPermission.deniedForever) return;
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 10)),
      );
      final latLng = LatLng(position.latitude, position.longitude);
      _pinPosition = latLng;
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(latLng, 16));
    } catch (_) {}
  }

  /// 同時載入兩市資料
  Future<void> _loadBothCities() async {
    setState(() { _isLoadingRoutes = true; _errorMessage = null; _loadedPages = 0; _loadedItems = 0; });
    try {
      // 並行載入
      await Future.wait([
        _dataService.loadRouteStops(
          city: CitySource.newTaipei,
          onProgress: (pages, items) { if (mounted) setState(() { _loadedPages = pages; _loadedItems = items; }); },
        ).then((_) { _ntpcStops = List.from(_dataService.allStops); }),
        _dataService.loadRouteStops(
          city: CitySource.taipei,
          onProgress: (_, __) {},
        ).then((_) { _taipeiStops = List.from(_dataService.allStops); }),
      ]);

      // 建立空間索引
      _ntpcIndex.build(_ntpcStops);
      _taipeiIndex.build(_taipeiStops);

      if (mounted) {
        final total = _ntpcStops.length + _taipeiStops.length;
        setState(() {
          _isLoadingRoutes = false;
          _dataSourceInfo = '已載入 $total 個站點（雙北）';
        });
        _dataSourceTimer?.cancel();
        _dataSourceTimer = Timer(const Duration(seconds: 3), () { if (mounted) setState(() => _dataSourceInfo = null); });
      }
    } catch (e) {
      if (mounted) setState(() { _errorMessage = e.toString(); _isLoadingRoutes = false; });
    }
  }

  void _refreshCityList() {
    _allCities = _allStops.map((s) => s.city).toSet().toList()..sort();
  }

  Future<void> _loadTruckLocations() async {
    _isLoadingTrucks = true;
    try {
      List<TruckLocation> newLocations;
      if (_citySource == CitySource.newTaipei) {
        await _dataService.loadTruckLocations();
        newLocations = _dataService.truckLocations;
      } else {
        newLocations = _estimateTaipeiTrucks();
      }

      if (mounted) {
        // 只在車輛資料有變化時才重建（避免不必要的 marker 替換）
        final changed = newLocations.length != _truckLocations.length ||
            (newLocations.isNotEmpty && _truckLocations.isNotEmpty &&
             newLocations.first.location != _truckLocations.first.location);
        _truckLocations = newLocations;
        _isLoadingTrucks = false;
        if (changed) _rebuildMapData();

        if (widget.settingsService.notificationsEnabled) {
          await NotificationService().checkAndNotify(
            allStops: _allStops,
            truckLocations: _truckLocations,
            favorites: widget.favoritesService.favorites,
            stopsBeforeArrival: widget.settingsService.stopsBeforeArrival,
          );
        }
      }
    } catch (_) {
      if (mounted) { _isLoadingTrucks = false; }
    }
  }

  /// 台北市：根據當前時間推估每條路線的車輛在哪個站
  List<TruckLocation> _estimateTaipeiTrucks() {
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final today = now.weekday;

    // 依路線分組
    final grouped = <String, List<RouteStop>>{};
    for (final s in _taipeiStops) {
      if (!s.hasServiceOnWeekday(today)) continue;
      grouped.putIfAbsent(s.lineId, () => []).add(s);
    }

    final trucks = <TruckLocation>[];
    for (final entry in grouped.entries) {
      final stops = entry.value..sort((a, b) => a.rank.compareTo(b.rank));

      // 找目前時間最接近的站（車輛正在前往或剛離開）
      RouteStop? currentStop;
      for (final stop in stops) {
        final min = _timeToMinutes(stop.time);
        if (min == null) continue;
        if (min <= nowMinutes) {
          currentStop = stop;
        } else {
          break;
        }
      }

      if (currentStop != null && currentStop.hasValidCoordinates) {
        trucks.add(TruckLocation(
          lineId: entry.key,
          car: '台北${stops.first.lineName}',
          time: now,
          location: currentStop.name,
          longitude: currentStop.longitude,
          latitude: currentStop.latitude,
          cityId: '',
          cityName: currentStop.city,
        ));
      }
    }
    return trucks;
  }

  void _onSettingsChanged() {
    _applyMapStyle();
  }

  /// 30 秒進度條 + 自動 reload（不觸發 setState）
  void _startProgressTimer() {
    _progressTimer?.cancel();
    _refreshProgressNotifier.value = 0.0;
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _refreshProgressNotifier.value += 1.0 / _refreshIntervalSec;
      if (_refreshProgressNotifier.value >= 1.0) {
        _refreshProgressNotifier.value = 0.0;
        _loadTruckLocations();
      }
    });
  }

  void _applyMapStyle() {
    if (_mapController == null) return;
    if (widget.settingsService.darkMode) {
      _mapController!.setMapStyle(_darkMapStyle);
    } else {
      _mapController!.setMapStyle(null);
    }
  }

  static const _darkMapStyle = '''[
    {"elementType":"geometry","stylers":[{"color":"#242f3e"}]},
    {"elementType":"labels.text.stroke","stylers":[{"color":"#242f3e"}]},
    {"elementType":"labels.text.fill","stylers":[{"color":"#746855"}]},
    {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},
    {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},
    {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#263c3f"}]},
    {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#6b9a76"}]},
    {"featureType":"road","elementType":"geometry","stylers":[{"color":"#38414e"}]},
    {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#212a37"}]},
    {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#9ca5b3"}]},
    {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#746855"}]},
    {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#1f2835"}]},
    {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#f3d19c"}]},
    {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#2f3948"}]},
    {"featureType":"transit.station","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},
    {"featureType":"water","elementType":"geometry","stylers":[{"color":"#17263c"}]},
    {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#515c6d"}]},
    {"featureType":"water","elementType":"labels.text.stroke","stylers":[{"color":"#17263c"}]}
  ]''';


  Future<void> _onCameraIdle() async {
    if (_mapController == null || _isLoadingRoutes) return;

    // Debounce：300ms 內不重複觸發，避免點擊 marker 時的微移中斷 onTap
    _cameraDebounce?.cancel();
    _cameraDebounce = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted || _mapController == null) return;

      final zoom = await _mapController!.getZoomLevel();
      final bounds = await _mapController!.getVisibleRegion();
      final center = LatLng(
        (bounds.northeast.latitude + bounds.southwest.latitude) / 2,
        (bounds.northeast.longitude + bounds.southwest.longitude) / 2,
      );
      final moved = _distanceKm(_pinPosition, center) >= 0.05;
      final zoomChanged = (zoom - _currentZoom).abs() > 0.5;
      if (!moved && !zoomChanged) return;
      _pinPosition = center;
      _currentZoom = zoom;

      // 跨城市時自動切換
      final newCity = _detectCityFromData(center);
      if (newCity != _citySource) {
        _citySource = newCity;
        _refreshCityList();
        _loadTruckLocations();
      }

      _autoSelectCity();
      _updateVisibleRoutes();
    });
  }

  void _onMapTap(LatLng _) {}  // InfoWindow 自動關閉

  /// 用空間索引比較，找離座標最近的站點屬於哪個市
  CitySource _detectCityFromData(LatLng pos) {
    final ntpcNearest = _ntpcIndex.findNearest(pos.latitude, pos.longitude, maxRadiusKm: 3);
    final tpNearest = _taipeiIndex.findNearest(pos.latitude, pos.longitude, maxRadiusKm: 3);

    if (ntpcNearest == null && tpNearest == null) return CitySource.newTaipei;
    if (ntpcNearest == null) return CitySource.taipei;
    if (tpNearest == null) return CitySource.newTaipei;

    final dNtpc = _distanceKm(pos, LatLng(ntpcNearest.latitude, ntpcNearest.longitude));
    final dTp = _distanceKm(pos, LatLng(tpNearest.latitude, tpNearest.longitude));
    return dTp < dNtpc ? CitySource.taipei : CitySource.newTaipei;
  }

  void _autoSelectCity() {
    if (_currentIndex.isEmpty) return;
    final nearest = _currentIndex.findNearest(_pinPosition.latitude, _pinPosition.longitude);
    if (nearest != null && nearest.city != _selectedCity) {
      _selectedCity = nearest.city;
    }
  }

  void _updateVisibleRoutes() {
    // 先計算可見路線，更新選取狀態，再重建地圖資料
    final visibleRoutes = _computeVisibleRoutes();
    _selectedRouteIds.retainAll(visibleRoutes.keys);
    for (final key in visibleRoutes.keys) {
      if (!_selectedRouteIds.contains(key)) _selectedRouteIds.add(key);
    }
    _rebuildMapData();
  }

  static double _distanceKm(LatLng a, LatLng b) {
    const R = 6371.0;
    final dLat = _deg2rad(b.latitude - a.latitude);
    final dLng = _deg2rad(b.longitude - a.longitude);
    final sinDLat = sin(dLat / 2); final sinDLng = sin(dLng / 2);
    final h = sinDLat * sinDLat + cos(_deg2rad(a.latitude)) * cos(_deg2rad(b.latitude)) * sinDLng * sinDLng;
    return R * 2 * atan2(sqrt(h), sqrt(1 - h));
  }
  static double _deg2rad(double deg) => deg * pi / 180;

  /// 從路線名稱判斷時段，若名稱無關鍵字則用站點時間推斷
  static TimePeriod _periodFromRoute(String lineName, List<RouteStop> stops) {
    if (lineName.contains('上午')) return TimePeriod.morning;
    if (lineName.contains('下午')) return TimePeriod.afternoon;
    if (lineName.contains('晚上')) return TimePeriod.evening;

    // 路線名稱沒有時段關鍵字，用第一個站點時間推斷
    if (stops.isNotEmpty) {
      final minutes = _timeToMinutes(stops.first.time);
      if (minutes != null) {
        if (minutes < 720) return TimePeriod.morning;   // < 12:00
        if (minutes < 1020) return TimePeriod.afternoon; // < 17:00
        return TimePeriod.evening;                        // >= 17:00
      }
    }
    return TimePeriod.evening; // 預設晚上
  }

  static int? _timeToMinutes(String timeStr) {
    final parts = timeStr.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]); final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  bool _isStopPassed(RouteStop stop) {
    final now = DateTime.now();
    if (_selectedWeekday != now.weekday) return false;
    if (!stop.hasServiceOnWeekday(now.weekday)) return false;
    final stopMinutes = _timeToMinutes(stop.time);
    if (stopMinutes == null) return false;
    return stopMinutes < now.hour * 60 + now.minute;
  }

  int? _findNearestStopRank(String lineId, TruckLocation truck) {
    final routeStops = _allStops.where((s) => s.lineId == lineId && s.hasValidCoordinates).toList();
    if (routeStops.isEmpty) return null;
    int? nearestRank; double minDist = double.infinity;
    final truckPos = LatLng(truck.latitude, truck.longitude);
    for (final stop in routeStops) {
      final dist = _distanceKm(truckPos, LatLng(stop.latitude, stop.longitude));
      if (dist < minDist) { minDist = dist; nearestRank = stop.rank; }
    }
    return nearestRank;
  }

  // ─── 地圖資料重建（核心效能優化：只在資料變更時計算一次）───

  void _rebuildMapData() {
    // 1. 計算可見路線
    _cachedVisibleRoutes = _computeVisibleRoutes();
    _cachedRouteKeys = _cachedVisibleRoutes.keys.toList();

    // 2. 取得選中路線的 nearby stops（空間索引 + 路線篩選）
    final validLineIds = _cachedVisibleRoutes.keys.where(_selectedRouteIds.contains).toSet();
    final nearbyStops = _currentIndex
        .queryRadius(_pinPosition.latitude, _pinPosition.longitude, _radiusKm)
        .where((s) => validLineIds.contains(s.lineId))
        .toList();

    // 3. 建構 color map（lineId → color）
    final colorMap = <String, Color>{};
    for (int i = 0; i < _cachedRouteKeys.length; i++) {
      colorMap[_cachedRouteKeys[i]] = _routeColors[i % _routeColors.length];
    }

    // 4. Truck nearest stops
    final truckNearestStops = <String, int>{};
    for (final truck in _truckLocations) {
      if (!_selectedRouteIds.contains(truck.lineId) || !truck.hasValidCoordinates) continue;
      final rank = _findNearestStopRank(truck.lineId, truck);
      if (rank != null) truckNearestStops[truck.lineId] = rank;
    }

    // 5. Build polylines
    _cachedPolylines = _computePolylines(nearbyStops, colorMap);

    // 6. Build markers
    _cachedMarkers = _computeMarkers(nearbyStops, colorMap, truckNearestStops);

    // 7. Build circles
    _cachedCircles = {
      Circle(
        circleId: const CircleId('range'),
        center: _pinPosition,
        radius: _radiusKm * 1000,
        fillColor: Colors.green.withValues(alpha: 0.05),
        strokeColor: Colors.green.withValues(alpha: 0.3),
        strokeWidth: 1,
      ),
    };

    if (mounted) setState(() {});
  }

  Map<String, List<RouteStop>> _computeVisibleRoutes() {
    if (_selectedCity == null) return {};
    // 用空間索引查詢 1km 內站點（O(~100) 而非 O(26000)）
    final nearbyStops = _currentIndex.queryRadius(
      _pinPosition.latitude, _pinPosition.longitude, _radiusKm,
    );
    final grouped = <String, List<RouteStop>>{};
    for (final stop in nearbyStops) grouped.putIfAbsent(stop.lineId, () => []).add(stop);
    final filtered = <String, List<RouteStop>>{};
    for (final entry in grouped.entries) {
      final stops = entry.value;
      if (stops.isEmpty) continue;
      final period = _periodFromRoute(stops.first.lineName, stops);
      if (period != _selectedPeriod) continue;
      if (!stops.any((s) => s.hasServiceOnWeekday(_selectedWeekday))) continue;
      stops.sort((a, b) => a.rank.compareTo(b.rank));
      filtered[entry.key] = stops;
    }
    return filtered;
  }

  // ─── 地圖元素計算 ───

  static const _passedColor = Color(0xFFD0D0D0);

  Set<Polyline> _computePolylines(List<RouteStop> stops, Map<String, Color> colorMap) {
    final grouped = <String, List<RouteStop>>{};
    for (final stop in stops) grouped.putIfAbsent(stop.lineId, () => []).add(stop);

    final polylines = <Polyline>{};
    for (final entry in grouped.entries) {
      final sorted = entry.value..sort((a, b) => a.rank.compareTo(b.rank));
      final validStops = sorted.where((s) => s.hasValidCoordinates).toList();
      if (validStops.length < 2) continue;

      final color = colorMap[entry.key] ?? _routeColors[0];

      for (int i = 0; i < validStops.length - 1; i++) {
        final from = validStops[i];
        final to = validStops[i + 1];
        final bothPassed = _isStopPassed(from) && _isStopPassed(to);

        polylines.add(Polyline(
          polylineId: PolylineId('${entry.key}_seg_$i'),
          points: [
            LatLng(from.latitude, from.longitude),
            LatLng(to.latitude, to.longitude),
          ],
          color: bothPassed ? _passedColor : color,
          width: bothPassed ? 3 : 4,
        ));
      }
    }
    return polylines;
  }

  Set<Marker> _computeMarkers(List<RouteStop> stops, Map<String, Color> colorMap, Map<String, int> truckNearestStops) {
    if (!_iconsReady) return {};
    final markers = <Marker>{};

    // zoom < 11：不顯示站點和箭頭（極遠距離）
    if (_currentZoom < 11) return markers;
    final showArrows = _currentZoom >= 15;

    // 避免重疊：追蹤已用座標（精度到小數 4 位 ≈ 11m）
    final usedPositions = <String>{};

    for (final stop in stops) {
      if (!stop.hasValidCoordinates) continue;

      // 座標去重，防止同位置多個 marker 堆疊導致點擊困難
      final posKey = '${stop.latitude.toStringAsFixed(4)}_${stop.longitude.toStringAsFixed(4)}';
      if (usedPositions.contains(posKey)) continue;
      usedPositions.add(posKey);

      final color = colorMap[stop.lineId] ?? _routeColors[0];
      final isPassed = _isStopPassed(stop);
      final isNearestToTruck = truckNearestStops[stop.lineId] == stop.rank;

      BitmapDescriptor icon;
      if (isNearestToTruck) {
        icon = _truckAtStopIconCache[color.hashCode] ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
      } else if (isPassed) {
        icon = _passedGreyIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
      } else {
        icon = _dotIconCache[color.hashCode] ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
      }

      // 用 lineId+rank 確保唯一性，即使座標重疊也不會互相覆蓋
      markers.add(Marker(
        markerId: MarkerId('s_${stop.lineId}_${stop.rank}'),
        position: LatLng(stop.latitude, stop.longitude),
        icon: icon,
        anchor: const Offset(0.5, 0.5),
        zIndex: isNearestToTruck ? 20 : (isPassed ? 0 : 5),
        onTap: () => _showStopSheet(stop, isNearestToTruck, isPassed),
      ));
    }

    // 箭頭 markers（zoom >= 15 才顯示）
    if (!showArrows) return markers;
    final grouped = <String, List<RouteStop>>{};
    for (final stop in stops) grouped.putIfAbsent(stop.lineId, () => []).add(stop);

    for (final entry in grouped.entries) {
      final sorted = entry.value..sort((a, b) => a.rank.compareTo(b.rank));
      final coords = sorted.where((s) => s.hasValidCoordinates).toList();
      if (coords.length < 2) continue;

      final color = colorMap[entry.key] ?? _routeColors[0];

      for (int i = 0; i < coords.length - 1; i++) {
        final fromStop = coords[i];
        final toStop = coords[i + 1];
        final bothPassed = _isStopPassed(fromStop) && _isStopPassed(toStop);
        final arrowIcon = bothPassed ? _passedArrowIcon : _arrowIconCache[color.hashCode];
        if (arrowIcon == null) continue;

        final from = LatLng(fromStop.latitude, fromStop.longitude);
        final to = LatLng(toStop.latitude, toStop.longitude);
        final midLat = (from.latitude + to.latitude) / 2;
        final midLng = (from.longitude + to.longitude) / 2;

        final angle = atan2(to.longitude - from.longitude, to.latitude - from.latitude);
        markers.add(Marker(
          markerId: MarkerId('arrow_${entry.key}_$i'),
          position: LatLng(midLat, midLng),
          icon: arrowIcon,
          anchor: const Offset(0.5, 0.5),
          rotation: angle * 180 / pi,
          flat: true,
          zIndex: 1,
        ));
      }
    }

    return markers;
  }

  // ─── 站點詳情 Bottom Sheet ───

  void _showStopSheet(RouteStop stop, bool isNearestToTruck, bool isPassed) {
    final favService = widget.favoritesService;
    final services = stop.todayServices();
    final serviceText = services.isEmpty ? '今日無收運' : services.join(' / ');

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final isFav = favService.isFavorite(stop.lineId, stop.rank);
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 拖曳條
                  Center(
                    child: Container(width: 40, height: 4,
                      decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2))),
                  ),
                  const SizedBox(height: 12),
                  // 標題列
                  Row(
                    children: [
                      if (isNearestToTruck) const Text('🚛 ', style: TextStyle(fontSize: 20)),
                      if (isPassed) Icon(Icons.check_circle, size: 18, color: Colors.grey.shade400),
                      if (isPassed) const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '${stop.time}  ${stop.name}',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                      // ❤️ 最愛按鈕
                      IconButton(
                        icon: Icon(
                          isFav ? Icons.favorite : Icons.favorite_border,
                          color: isFav ? Colors.red : Colors.grey,
                        ),
                        onPressed: () async {
                          await favService.toggle(stop);
                          setSheetState(() {});
                          if (mounted) setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 路線資訊
                  Row(children: [
                    Icon(Icons.route, size: 16, color: Colors.grey.shade600),
                    const SizedBox(width: 6),
                    Text(stop.lineName, style: TextStyle(fontSize: 14, color: Colors.grey.shade700)),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Icon(Icons.location_city, size: 16, color: Colors.grey.shade600),
                    const SizedBox(width: 6),
                    Text('${stop.city} ${stop.village}', style: TextStyle(fontSize: 14, color: Colors.grey.shade700)),
                  ]),
                  const SizedBox(height: 8),
                  // 今日服務
                  Wrap(spacing: 6, children: [
                    if (stop.isGarbageToday())
                      Chip(label: const Text('垃圾', style: TextStyle(fontSize: 12)), backgroundColor: Colors.green.shade50,
                          visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    if (stop.isRecyclingToday())
                      Chip(label: const Text('回收', style: TextStyle(fontSize: 12)), backgroundColor: Colors.blue.shade50,
                          visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    if (stop.isFoodScrapsToday())
                      Chip(label: const Text('廚餘', style: TextStyle(fontSize: 12)), backgroundColor: Colors.orange.shade50,
                          visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    if (services.isEmpty)
                      Text(serviceText, style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                  ]),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ─── 事件 ───

  void _onCityChanged(String? city) { if (city == null) return; _selectedCity = city; _updateVisibleRoutes(); }
  void _onWeekdayChanged(int? w) { if (w == null) return; _selectedWeekday = w; _updateVisibleRoutes(); }
  void _onPeriodChanged(TimePeriod? p) { if (p == null) return; _selectedPeriod = p; _updateVisibleRoutes(); }

  // ─── UI ───

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(target: _pinPosition, zoom: 16),
          onMapCreated: (c) {
            _mapController = c;
            _applyMapStyle();
          },
          onCameraIdle: _onCameraIdle,
          onTap: _onMapTap,
          polylines: _cachedPolylines,
          markers: _cachedMarkers,
          circles: _cachedCircles,
          myLocationEnabled: true, myLocationButtonEnabled: false,
          zoomControlsEnabled: false, mapToolbarEnabled: false,
          padding: const EdgeInsets.only(bottom: 80),
        ),
        // 上方篩選面板
        if (!_isLoadingRoutes && _allCities.isNotEmpty)
          Positioned(
            top: topPadding + 8, left: 12, right: 12,
            child: _buildFilterPanel(context),
          ),

        if (_isLoadingRoutes) _buildLoadingOverlay(),
        if (_errorMessage != null) _buildErrorBanner(),

        // 底部進度條（30 秒自動刷新，不觸發 setState）
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: ValueListenableBuilder<double>(
            valueListenable: _refreshProgressNotifier,
            builder: (_, progress, __) => LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation<Color>(
                _isLoadingTrucks ? Colors.orange : Colors.green.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),

        // 右下角：縮放 + 定位
        Positioned(
          right: 16, bottom: 16,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            FloatingActionButton.small(
              heroTag: 'zoom_in', backgroundColor: Theme.of(context).colorScheme.surface,
              onPressed: () => _mapController?.animateCamera(CameraUpdate.zoomIn()),
              child: const Icon(Icons.add, size: 20),
            ),
            const SizedBox(height: 4),
            FloatingActionButton.small(
              heroTag: 'zoom_out', backgroundColor: Theme.of(context).colorScheme.surface,
              onPressed: () => _mapController?.animateCamera(CameraUpdate.zoomOut()),
              child: const Icon(Icons.remove, size: 20),
            ),
            const SizedBox(height: 12),
            FloatingActionButton.small(
              heroTag: 'relocate', backgroundColor: Theme.of(context).colorScheme.surface,
              onPressed: () async {
                await _getCurrentLocation();
                final newCity = _detectCityFromData(_pinPosition);
                if (newCity != _citySource) {
                  _citySource = newCity;
                  _refreshCityList();
                  _loadTruckLocations();
                }
                _autoSelectCity();
                _updateVisibleRoutes();
              },
              child: const Icon(Icons.my_location, color: Colors.green, size: 20),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _buildFilterPanel(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      color: surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 第一排：市 + 區 下拉
            Row(
              children: [
                // 市下拉
                DropdownButtonHideUnderline(
                  child: DropdownButton<CitySource>(
                    value: _citySource,
                    isDense: true,
                    icon: const Icon(Icons.arrow_drop_down, size: 18, color: Colors.green),
                    style: TextStyle(fontSize: 13, color: onSurface, fontWeight: FontWeight.bold),
                    items: CitySource.values.map((c) => DropdownMenuItem(
                      value: c,
                      child: Text(c.label, style: TextStyle(
                        fontSize: 13,
                        color: c == CitySource.taipei ? Colors.blue.shade700 : Colors.green.shade700,
                        fontWeight: FontWeight.bold,
                      )),
                    )).toList(),
                    onChanged: (c) {
                      if (c == null || c == _citySource) return;
                      _citySource = c;
                      _refreshCityList();
                      _selectedCity = null;
                      _autoSelectCity();
                      _updateVisibleRoutes();
                      _loadTruckLocations();
                    },
                  ),
                ),
                const SizedBox(width: 4),
                Container(width: 1, height: 20, color: onSurface.withValues(alpha: 0.15)),
                const SizedBox(width: 4),
                // 區下拉
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedCity,
                      hint: Text('選擇區', style: TextStyle(fontSize: 13, color: onSurface.withValues(alpha: 0.5))),
                      isExpanded: true, isDense: true,
                      icon: const Icon(Icons.arrow_drop_down, size: 18, color: Colors.green),
                      style: TextStyle(fontSize: 13, color: onSurface),
                      items: _allCities.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                      onChanged: _onCityChanged,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // 第二排：星期 + 時段（自適應寬度）
            Row(
              children: [
                // 星期選擇
                Expanded(
                  flex: 7,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(7, (i) {
                      final wd = i + 1;
                      final isSelected = _selectedWeekday == wd;
                      final isToday = wd == DateTime.now().weekday;
                      return InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => _onWeekdayChanged(wd),
                        child: Container(
                          width: 26, height: 26,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.green : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isToday && !isSelected ? Colors.green : Colors.transparent,
                              width: isToday ? 1.5 : 0,
                            ),
                          ),
                          child: Text(
                            _weekdayLabels[wd]!,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: isSelected || isToday ? FontWeight.bold : FontWeight.normal,
                              color: isSelected ? Colors.white : onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
                Container(width: 1, height: 20, color: onSurface.withValues(alpha: 0.15), margin: const EdgeInsets.symmetric(horizontal: 4)),
                // 時段
                Expanded(
                  flex: 4,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: TimePeriod.values.map((p) {
                      final isSelected = _selectedPeriod == p;
                      return InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => _onPeriodChanged(p),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.green : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            p.label,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              color: isSelected ? Colors.white : onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
            // 第三排：路線 chips
            if (_selectedCity != null) ...[
              const SizedBox(height: 6),
              _buildRouteChipsInline(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRouteChipsInline() {
    final routes = _cachedVisibleRoutes;
    if (routes.isEmpty) {
      return Text('範圍內無符合條件的路線', style: TextStyle(fontSize: 12, color: Colors.grey.shade500));
    }
    final keys = routes.keys.toList();
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: routes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (context, i) {
          final id = keys[i];
          final name = routes[id]!.first.lineName;
          final color = _routeColors[i % _routeColors.length];
          final sel = _selectedRouteIds.contains(id);
          return FilterChip(
            label: Text(name, style: TextStyle(fontSize: 10, color: sel ? color : Colors.grey)),
            selected: sel,
            onSelected: (s) { if (s) _selectedRouteIds.add(id); else _selectedRouteIds.remove(id); _rebuildMapData(); },
            selectedColor: color.withValues(alpha: 0.15),
            checkmarkColor: color,
            backgroundColor: Theme.of(context).colorScheme.surface,
            side: BorderSide(color: sel ? color : Colors.grey.shade300, width: 0.5),
            elevation: 0, shadowColor: Colors.transparent,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 4),
          );
        },
      ),
    );
  }

  Widget _buildRouteChips() {
    final routes = _cachedVisibleRoutes;
    if (routes.isEmpty) return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text('範圍內無符合條件的路線', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
    );
    final keys = routes.keys.toList();
    return SizedBox(height: 40, child: ListView.separated(
      scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: routes.length, separatorBuilder: (_, __) => const SizedBox(width: 6),
      itemBuilder: (context, i) {
        final id = keys[i]; final name = routes[id]!.first.lineName;
        final color = _routeColors[i % _routeColors.length]; final sel = _selectedRouteIds.contains(id);
        return FilterChip(
          label: Text(name, style: TextStyle(fontSize: 11, color: sel ? color : Colors.grey)),
          selected: sel,
          onSelected: (s) { if (s) _selectedRouteIds.add(id); else _selectedRouteIds.remove(id); _rebuildMapData(); },
          selectedColor: color.withValues(alpha: 0.15), checkmarkColor: color, backgroundColor: Colors.white,
          side: BorderSide(color: sel ? color : Colors.grey.shade300),
          elevation: 2, shadowColor: Colors.black26, visualDensity: VisualDensity.compact,
        );
      },
    ));
  }

  Widget _buildLoadingOverlay() => Center(child: Card(elevation: 8, child: Padding(
    padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const CircularProgressIndicator(), const SizedBox(height: 16),
      const Text('正在載入路線資料...', style: TextStyle(fontSize: 16)),
      if (_loadedPages > 0) Padding(padding: const EdgeInsets.only(top: 8),
        child: Text('已載入 $_loadedPages 頁 / $_loadedItems 筆', style: TextStyle(fontSize: 13, color: Colors.grey.shade600))),
    ]),
  )));

  Widget _buildErrorBanner() => Positioned(
    top: MediaQuery.of(context).padding.top + 8, left: 16, right: 16,
    child: Card(color: Colors.red.shade50, child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
      const Icon(Icons.error_outline, color: Colors.red), const SizedBox(width: 8),
      Expanded(child: Text(_errorMessage!, style: const TextStyle(fontSize: 13))),
      TextButton(onPressed: _loadBothCities, child: const Text('重試')),
    ]))),
  );

  @override
  void dispose() {
    _dataSourceTimer?.cancel();
    _progressTimer?.cancel();
    _cameraDebounce?.cancel();
    _refreshProgressNotifier.dispose();
    widget.settingsService.removeListener(_onSettingsChanged);
    _mapController?.dispose();
    _dataService.dispose();
    super.dispose();
  }
}
