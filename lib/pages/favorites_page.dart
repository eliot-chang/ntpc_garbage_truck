import 'package:flutter/material.dart';
import '../models/route_stop.dart';
import '../services/favorites_service.dart';

const _dayLabels = ['一', '二', '三', '四', '五', '六', '日'];

class FavoritesPage extends StatelessWidget {
  final FavoritesService favoritesService;
  const FavoritesPage({super.key, required this.favoritesService});

  static bool _isStopPassed(RouteStop stop) {
    final now = DateTime.now();
    if (!stop.hasServiceOnWeekday(now.weekday)) return false;
    final parts = stop.time.split(':');
    if (parts.length != 2) return false;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return false;
    return h * 60 + m < now.hour * 60 + now.minute;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: favoritesService,
      builder: (context, _) {
        final favorites = favoritesService.favorites;

        if (favorites.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.favorite_border, size: 64, color: Colors.grey.shade300),
                const SizedBox(height: 16),
                Text('尚無最愛站點', style: TextStyle(fontSize: 18, color: Colors.grey.shade500)),
                const SizedBox(height: 8),
                Text('在地圖上點擊站點，按 ❤ 加入最愛',
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade400)),
              ],
            ),
          );
        }

        // 依時間排序（最早在最上面）
        final sorted = List<RouteStop>.from(favorites)
          ..sort((a, b) => a.time.compareTo(b.time));

        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: sorted.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final stop = sorted[index];
            final passed = _isStopPassed(stop);
            final services = stop.todayServices();

            final isDark = theme.brightness == Brightness.dark;
            return Card(
              elevation: passed ? 0.5 : 2,
              color: passed
                  ? (isDark ? const Color(0xFF2C2C2C) : const Color(0xFFF0F0F0))
                  : theme.cardColor,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ─── 主要：時間 + 過站狀態 + 愛心 ───
                    Row(
                      children: [
                        Text(
                          stop.time,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: passed ? Colors.grey.shade400 : Colors.green.shade700,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: passed
                                ? Colors.grey.shade200
                                : Colors.green.shade50,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            passed ? '✓ 已過站' : '● 未到站',
                            style: TextStyle(
                              fontSize: 12,
                              color: passed ? Colors.grey.shade500 : Colors.green.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.favorite, color: Colors.red, size: 22),
                          onPressed: () => favoritesService.remove(stop.lineId, stop.rank),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),

                    // ─── 次要：站名 ───
                    Text(stop.name,
                        style: TextStyle(
                          fontSize: 15,
                          color: passed ? Colors.grey.shade500 : theme.textTheme.bodyLarge?.color,
                        )),
                    const SizedBox(height: 2),

                    // ─── 次要：路線名 ───
                    Text('${stop.lineName}・${stop.city}',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                    const SizedBox(height: 8),

                    // ─── 次要：星期幾有服務 ───
                    Row(
                      children: List.generate(7, (i) {
                        final weekday = i + 1; // 1=一 ... 7=日
                        final hasService = stop.hasServiceOnWeekday(weekday);
                        final isToday = weekday == DateTime.now().weekday;
                        return Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Container(
                            width: 28,
                            height: 28,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: hasService
                                  ? (isToday ? Colors.green.shade600 : Colors.green.shade100)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: isToday
                                    ? Colors.green.shade600
                                    : (hasService ? Colors.green.shade200 : Colors.grey.shade300),
                                width: isToday ? 2 : 1,
                              ),
                            ),
                            child: Text(
                              _dayLabels[i],
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                                color: hasService
                                    ? (isToday ? Colors.white : Colors.green.shade800)
                                    : Colors.grey.shade400,
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 8),

                    // ─── 更次要：今日服務類型 ───
                    if (services.isNotEmpty)
                      Wrap(spacing: 6, children: [
                        if (stop.isGarbageToday())
                          _serviceChip('垃圾', Colors.green),
                        if (stop.isRecyclingToday())
                          _serviceChip('回收', Colors.blue),
                        if (stop.isFoodScrapsToday())
                          _serviceChip('廚餘', Colors.orange),
                      ])
                    else
                      Text('今日無收運', style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _serviceChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500)),
    );
  }
}
