import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  static const _notificationsEnabledKey = 'notifications_enabled';
  static const _stopsBeforeArrivalKey = 'stops_before_arrival';
  static const _darkModeKey = 'dark_mode';

  bool _notificationsEnabled = false;
  int _stopsBeforeArrival = 3;
  bool _darkMode = false;

  bool get notificationsEnabled => _notificationsEnabled;
  int get stopsBeforeArrival => _stopsBeforeArrival;
  bool get darkMode => _darkMode;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _notificationsEnabled = prefs.getBool(_notificationsEnabledKey) ?? false;
    _stopsBeforeArrival = prefs.getInt(_stopsBeforeArrivalKey) ?? 3;
    _darkMode = prefs.getBool(_darkModeKey) ?? false;
    notifyListeners();
  }

  Future<void> setNotificationsEnabled(bool value) async {
    _notificationsEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationsEnabledKey, value);
  }

  Future<void> setStopsBeforeArrival(int value) async {
    _stopsBeforeArrival = value.clamp(1, 10);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_stopsBeforeArrivalKey, _stopsBeforeArrival);
  }

  Future<void> setDarkMode(bool value) async {
    _darkMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkModeKey, value);
  }
}
