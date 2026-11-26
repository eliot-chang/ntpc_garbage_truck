import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../services/notification_service.dart';
import '../services/cache_service.dart';

class SettingsPage extends StatelessWidget {
  final SettingsService settingsService;
  const SettingsPage({super.key, required this.settingsService});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settingsService,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            // ─── 通知設定 ───
            _sectionHeader(context, '通知設定', Icons.notifications_outlined),
            SwitchListTile(
              title: const Text('啟用推播通知'),
              subtitle: const Text('垃圾車接近最愛站點時通知'),
              value: settingsService.notificationsEnabled,
              onChanged: (v) async {
                if (v) {
                  final granted = await NotificationService().requestPermission();
                  if (!granted) return;
                }
                settingsService.setNotificationsEnabled(v);
              },
              activeColor: Colors.green,
            ),
            ListTile(
              enabled: settingsService.notificationsEnabled,
              title: const Text('提前通知站數'),
              subtitle: Text(
                '車輛到達前 ${settingsService.stopsBeforeArrival} 站時通知',
                style: TextStyle(
                  color: settingsService.notificationsEnabled
                      ? null
                      : Colors.grey.shade400,
                ),
              ),
              trailing: SizedBox(
                width: 200,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${settingsService.stopsBeforeArrival}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: settingsService.notificationsEnabled
                              ? Colors.green
                              : Colors.grey.shade400,
                        )),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Slider(
                        value: settingsService.stopsBeforeArrival.toDouble(),
                        min: 1,
                        max: 10,
                        divisions: 9,
                        label: '${settingsService.stopsBeforeArrival} 站',
                        activeColor: Colors.green,
                        onChanged: settingsService.notificationsEnabled
                            ? (v) => settingsService.setStopsBeforeArrival(v.round())
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 32),

            // ─── 外觀設定 ───
            _sectionHeader(context, '外觀', Icons.palette_outlined),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Text('主題模式', style: TextStyle(fontSize: 16)),
                  const Spacer(),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.light_mode, size: 18),
                        label: Text('淺色'),
                      ),
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.dark_mode, size: 18),
                        label: Text('深色'),
                      ),
                    ],
                    selected: {settingsService.darkMode},
                    onSelectionChanged: (v) => settingsService.setDarkMode(v.first),
                    style: SegmentedButton.styleFrom(
                      selectedBackgroundColor: Colors.green.shade100,
                      selectedForegroundColor: Colors.green.shade800,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 32),

            // ─── 儲存空間 ───
            _sectionHeader(context, '儲存空間', Icons.storage_outlined),
            const _CacheTile(),
            const Divider(height: 32),

            // ─── 關於 ───
            _sectionHeader(context, '關於', Icons.info_outlined),
            const ListTile(
              title: Text('新北市垃圾車時刻表'),
              subtitle: Text('版本 1.0.1\n資料來源：新北市政府開放資料平臺'),
            ),
          ],
        );
      },
    );
  }

  Widget _sectionHeader(BuildContext context, String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.green.shade700),
          const SizedBox(width: 8),
          Text(title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.green.shade700,
              )),
        ],
      ),
    );
  }
}

class _CacheTile extends StatefulWidget {
  const _CacheTile();

  @override
  State<_CacheTile> createState() => _CacheTileState();
}

class _CacheTileState extends State<_CacheTile> {
  final CacheService _cacheService = CacheService();
  int? _cacheBytes;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _loadSize();
  }

  Future<void> _loadSize() async {
    final bytes = await _cacheService.getCacheSizeBytes();
    if (mounted) setState(() => _cacheBytes = bytes);
  }

  Future<void> _clearCache() async {
    setState(() => _clearing = true);
    await _cacheService.clear();
    await _loadSize();
    if (mounted) {
      setState(() => _clearing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已清除路線快取並回收空間')),
      );
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  void dispose() {
    _cacheService.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _cacheBytes == null
        ? '計算中...'
        : '本地路線快取：${_formatBytes(_cacheBytes!)}';
    return ListTile(
      title: const Text('清除路線快取'),
      subtitle: Text(subtitle),
      trailing: OutlinedButton(
        onPressed: _clearing ? null : _clearCache,
        child: _clearing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('清除'),
      ),
    );
  }
}
