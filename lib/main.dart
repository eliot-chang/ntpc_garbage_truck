import 'package:flutter/material.dart';
import 'pages/home_page.dart';
import 'pages/favorites_page.dart';
import 'pages/settings_page.dart';
import 'services/favorites_service.dart';
import 'services/settings_service.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final favoritesService = FavoritesService();
  final settingsService = SettingsService();
  await Future.wait([
    favoritesService.load(),
    settingsService.load(),
  ]);

  final notificationService = NotificationService();
  await notificationService.init();

  runApp(MyApp(
    favoritesService: favoritesService,
    settingsService: settingsService,
  ));
}

class MyApp extends StatelessWidget {
  final FavoritesService favoritesService;
  final SettingsService settingsService;

  const MyApp({
    super.key,
    required this.favoritesService,
    required this.settingsService,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settingsService,
      builder: (context, _) {
        return MaterialApp(
          title: '新北市垃圾車時刻表',
          debugShowCheckedModeBanner: false,
          themeMode: settingsService.darkMode ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.green,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          home: MainScreen(
            favoritesService: favoritesService,
            settingsService: settingsService,
          ),
        );
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  final FavoritesService favoritesService;
  final SettingsService settingsService;

  const MainScreen({
    super.key,
    required this.favoritesService,
    required this.settingsService,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  late final List<Widget> _pages = [
    HomePage(
      favoritesService: widget.favoritesService,
      settingsService: widget.settingsService,
    ),
    FavoritesPage(favoritesService: widget.favoritesService),
    SettingsPage(settingsService: widget.settingsService),
  ];

  final List<String> _titles = const [
    '附近車況',
    '我的最愛',
    '設定',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _currentIndex == 0
          ? null
          : AppBar(
              title: Text(_titles[_currentIndex]),
              backgroundColor: Theme.of(context).colorScheme.inversePrimary,
            ),
      body: _pages[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.local_shipping_outlined),
            selectedIcon: Icon(Icons.local_shipping, color: Colors.green),
            label: '附近車況',
          ),
          NavigationDestination(
            icon: Icon(Icons.favorite_border),
            selectedIcon: Icon(Icons.favorite, color: Colors.green),
            label: '最愛',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings, color: Colors.green),
            label: '設定',
          ),
        ],
      ),
    );
  }
}
