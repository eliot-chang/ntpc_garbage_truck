class TruckLocation {
  final String lineId;
  final String car;
  final DateTime? time;
  final String location;
  final double longitude;
  final double latitude;
  final String cityId;
  final String cityName;

  const TruckLocation({
    required this.lineId,
    required this.car,
    required this.time,
    required this.location,
    required this.longitude,
    required this.latitude,
    required this.cityId,
    required this.cityName,
  });

  factory TruckLocation.fromJson(Map<String, dynamic> json) {
    return TruckLocation(
      lineId: json['lineid'] ?? '',
      car: json['car'] ?? '',
      time: _parseTime(json['time']?.toString()),
      location: json['location'] ?? '',
      longitude: double.tryParse(json['longitude']?.toString() ?? '') ?? 0.0,
      latitude: double.tryParse(json['latitude']?.toString() ?? '') ?? 0.0,
      cityId: json['cityid'] ?? '',
      cityName: json['cityname'] ?? '',
    );
  }

  /// 解析 "2026/04/06 15:13:52" 格式
  static DateTime? _parseTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      // "2026/04/06 15:13:52" → "2026-04-06 15:13:52"
      return DateTime.parse(raw.replaceAll('/', '-'));
    } catch (_) {
      return null;
    }
  }

  bool get hasValidCoordinates => longitude != 0.0 && latitude != 0.0;

  /// 是否在 10 分鐘內回報
  bool get isRecent {
    if (time == null) return false;
    return DateTime.now().difference(time!).inMinutes < 10;
  }

  /// 中文友善時間，例如「3分鐘前」「1小時前」
  String get timeAgo {
    if (time == null) return '未知';
    final diff = DateTime.now().difference(time!);
    if (diff.inMinutes < 1) return '剛剛';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分鐘前';
    if (diff.inHours < 24) return '${diff.inHours}小時前';
    return '${diff.inDays}天前';
  }

  /// 行駛狀態文字
  String get statusText {
    if (time == null) return '未發車';
    if (isRecent) return '行駛中';
    final diff = DateTime.now().difference(time!);
    if (diff.inMinutes < 30) return '${diff.inMinutes}分鐘前';
    return '已離線';
  }
}
