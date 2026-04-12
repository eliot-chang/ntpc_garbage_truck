class RouteStop {
  final String city;
  final String lineId;
  final String lineName;
  final int rank;
  final String name;
  final String village;
  final double longitude;
  final double latitude;
  final String time;
  final String memo;

  // key = DateTime.weekday (1=Monday ... 7=Sunday)
  final Map<int, bool> garbageDays;
  final Map<int, bool> recyclingDays;
  final Map<int, bool> foodScrapsDays;

  const RouteStop({
    required this.city,
    required this.lineId,
    required this.lineName,
    required this.rank,
    required this.name,
    required this.village,
    required this.longitude,
    required this.latitude,
    required this.time,
    required this.memo,
    required this.garbageDays,
    required this.recyclingDays,
    required this.foodScrapsDays,
  });

  factory RouteStop.fromJson(Map<String, dynamic> json) {
    return RouteStop(
      city: json['city'] ?? '',
      lineId: json['lineid'] ?? '',
      lineName: json['linename'] ?? '',
      rank: int.tryParse(json['rank']?.toString() ?? '') ?? 0,
      name: json['name'] ?? '',
      village: json['village'] ?? '',
      longitude: double.tryParse(json['longitude']?.toString() ?? '') ?? 0.0,
      latitude: double.tryParse(json['latitude']?.toString() ?? '') ?? 0.0,
      time: json['time'] ?? '',
      memo: json['memo'] ?? '',
      garbageDays: _parseDays(json, 'garbage'),
      recyclingDays: _parseDays(json, 'recycling'),
      foodScrapsDays: _parseDays(json, 'foodscraps'),
    );
  }

  /// 解析星期欄位，回傳 {weekday: bool}
  static Map<int, bool> _parseDays(Map<String, dynamic> json, String prefix) {
    const dayMapping = {
      'monday': 1,
      'tuesday': 2,
      'wednesday': 3,
      'thursday': 4,
      'friday': 5,
      'saturday': 6,
      'sunday': 7,
    };
    final result = <int, bool>{};
    for (final entry in dayMapping.entries) {
      final value = json['$prefix${entry.key}']?.toString().toUpperCase();
      result[entry.value] = (value == 'Y');
    }
    return result;
  }

  bool get hasValidCoordinates => longitude != 0.0 && latitude != 0.0;

  /// 序列化為 JSON（供 SharedPreferences 儲存）
  Map<String, dynamic> toJson() {
    const dayNames = {1: 'monday', 2: 'tuesday', 3: 'wednesday', 4: 'thursday', 5: 'friday', 6: 'saturday', 7: 'sunday'};
    final map = <String, dynamic>{
      'city': city, 'lineid': lineId, 'linename': lineName,
      'rank': rank.toString(), 'name': name, 'village': village,
      'longitude': longitude.toString(), 'latitude': latitude.toString(),
      'time': time, 'memo': memo,
    };
    for (final e in dayNames.entries) {
      map['garbage${e.value}'] = garbageDays[e.key] == true ? 'Y' : '';
      map['recycling${e.value}'] = recyclingDays[e.key] == true ? 'Y' : '';
      map['foodscraps${e.value}'] = foodScrapsDays[e.key] == true ? 'Y' : '';
    }
    return map;
  }

  bool isGarbageToday([DateTime? now]) {
    final weekday = (now ?? DateTime.now()).weekday;
    return garbageDays[weekday] ?? false;
  }

  bool isRecyclingToday([DateTime? now]) {
    final weekday = (now ?? DateTime.now()).weekday;
    return recyclingDays[weekday] ?? false;
  }

  bool isFoodScrapsToday([DateTime? now]) {
    final weekday = (now ?? DateTime.now()).weekday;
    return foodScrapsDays[weekday] ?? false;
  }

  /// 回傳今日收運類型的中文文字列表
  List<String> todayServices([DateTime? now]) {
    final services = <String>[];
    if (isGarbageToday(now)) services.add('垃圾');
    if (isRecyclingToday(now)) services.add('回收');
    if (isFoodScrapsToday(now)) services.add('廚餘');
    return services;
  }

  bool hasServiceToday([DateTime? now]) => todayServices(now).isNotEmpty;

  /// 指定星期幾是否有任何服務（1=週一...7=週日）
  bool hasServiceOnWeekday(int weekday) {
    return (garbageDays[weekday] ?? false) ||
        (recyclingDays[weekday] ?? false) ||
        (foodScrapsDays[weekday] ?? false);
  }
}
