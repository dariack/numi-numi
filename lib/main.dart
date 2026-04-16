import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:home_widget/home_widget.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'screens/history_screen.dart';
import 'screens/insights_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/medicine_screen.dart';
import 'services/firestore_service.dart';
import 'services/medicine_service.dart';
import 'models/medicine.dart';
import 'services/settings_service.dart';
import 'models/event.dart';

Future<void> handleWidgetAction(Uri? uri, FirestoreService service) async {
  if (uri == null) return;
  final db = FirebaseFirestore.instance;
  final ref =
      db.collection('families').doc(service.familyId).collection('events');

  if (uri.host == 'logPoop') {
    await ref.add({
      'type': 'diaper',
      'startTime': Timestamp.now(),
      'pee': false,
      'poop': true,
      'createdBy': 'widget',
      'createdAt': Timestamp.now(),
    });
  } else if (uri.host == 'toggleFeed') {
    final ongoing = await service.getOngoing();
    if (ongoing != null && ongoing.type == EventType.feed) return;
    await ref.add({
      'type': 'feed',
      'startTime': Timestamp.now(),
      'pee': false,
      'poop': false,
      'createdBy': 'widget',
      'createdAt': Timestamp.now(),
    });
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Enable offline persistence with generous cache
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  runApp(const BabyTrackerApp());
}

class BabyTrackerApp extends StatelessWidget {
  const BabyTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Baby Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          colorSchemeSeed: const Color(0xFF6B4EFF),
          brightness: Brightness.light,
          useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF6B4EFF),
          brightness: Brightness.dark,
          useMaterial3: true),
      themeMode: ThemeMode.system,
      home: const AppRouter(),
    );
  }
}

class AppRouter extends StatefulWidget {
  const AppRouter({super.key});
  @override
  State<AppRouter> createState() => _AppRouterState();
}

class _AppRouterState extends State<AppRouter> {
  String? _familyId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFamilyId();
  }

  Future<void> _loadFamilyId() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _familyId = prefs.getString('familyId');
      _loading = false;
    });
  }

  Future<void> _setFamilyId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('familyId', id);
    setState(() => _familyId = id);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_familyId == null || _familyId!.isEmpty) {
      return _FamilyCodeScreen(onSet: _setFamilyId);
    }
    return MainApp(
      familyId: _familyId!,
      onChangeFamilyId: () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('familyId');
        setState(() => _familyId = null);
      },
    );
  }
}

// Each nav tab has an id, icon, label, and builder
class _NavTab {
  final String id;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final Widget Function() builder;
  _NavTab({required this.id, required this.icon, required this.selectedIcon, required this.label, required this.builder});
}

class MainApp extends StatefulWidget {
  final String familyId;
  final VoidCallback onChangeFamilyId;
  const MainApp({super.key, required this.familyId, required this.onChangeFamilyId});
  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  int _tab = 0;
  late final FirestoreService _service;
  late final SettingsService _settingsService;
  late final MedicineService _medicineService;
  TrackerSettings _settings = const TrackerSettings();
  bool _migrating = false;
  StreamSubscription? _settingsSub;

  @override
  void initState() {
    super.initState();
    _service = FirestoreService(familyId: widget.familyId);
    _settingsService = SettingsService(familyId: widget.familyId);
    _medicineService = MedicineService(familyId: widget.familyId);
    _checkMigration();
    _handleWidgetLaunch();
    _listenSettings();
  }

  void _listenSettings() {
    _settingsSub = _settingsService.stream().listen((settings) {
      if (mounted) setState(() => _settings = settings);
    });
  }

  Future<void> _handleWidgetLaunch() async {
    try {
      const channel = MethodChannel('app.channel.shared.data');
      final String? action = await channel.invokeMethod('getIntentAction');
      if (action != null && action.isNotEmpty) {
        await handleWidgetAction(Uri.parse('yuliTracker://$action'), _service);
        if (mounted) {
          if (action == 'logPoop') {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('💩 Poop logged!'), duration: Duration(seconds: 2)));
          } else if (action == 'toggleFeed') {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('🍼 Feed started!'), duration: Duration(seconds: 2)));
          }
        }
      }
    } catch (e) {
      // Shortcut not used, normal launch
    }
  }

  Future<void> _checkMigration() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('migrated_v2') != true) {
      setState(() => _migrating = true);
      try {
        final count = await _service.migrateOldEvents();
        await prefs.setBool('migrated_v2', true);
        if (mounted && count > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Migrated $count events to new format')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Migration error: $e')));
        }
      }
      if (mounted) setState(() => _migrating = false);
    }
  }

  List<_NavTab> _buildTabs() {
    final tabs = <_NavTab>[
      _NavTab(
        id: 'home', icon: Icons.home_outlined, selectedIcon: Icons.home,
        label: 'Home',
        builder: () => HomeScreen(
          service: _service,
          settings: _settings,
          medicineService: _medicineService,
          onTabChange: (tabId) {
            final tabs = _buildTabs();
            final idx = tabs.indexWhere((t) => t.id == tabId);
            if (idx >= 0 && mounted) setState(() => _tab = idx);
          },
        ),
      ),
      _NavTab(
        id: 'history', icon: Icons.history_outlined, selectedIcon: Icons.history,
        label: 'History',
        builder: () => HistoryScreen(service: _service, medicineService: _medicineService),
      ),
    ];

    // Per-action tabs — only if tracked
    if (_settings.trackFeed) {
      tabs.add(_NavTab(
        id: 'feed', icon: Icons.restaurant_outlined, selectedIcon: Icons.restaurant,
        label: 'Feed',
        builder: () => ActionTabScreen(service: _service, type: EventType.feed),
      ));
    }
    if (_settings.trackSleep) {
      tabs.add(_NavTab(
        id: 'sleep', icon: Icons.bedtime_outlined, selectedIcon: Icons.bedtime,
        label: 'Sleep',
        builder: () => ActionTabScreen(service: _service, type: EventType.sleep),
      ));
    }
    if (_settings.trackDiaper) {
      tabs.add(_NavTab(
        id: 'diaper', icon: Icons.baby_changing_station_outlined, selectedIcon: Icons.baby_changing_station,
        label: 'Diaper',
        builder: () => ActionTabScreen(service: _service, type: EventType.diaper),
      ));
    }
    if (_settings.trackPump) {
      tabs.add(_NavTab(
        id: 'pump', icon: Icons.local_drink_outlined, selectedIcon: Icons.local_drink,
        label: 'Pump',
        builder: () => ActionTabScreen(service: _service, type: EventType.pump),
      ));
    }

    tabs.add(_NavTab(
      id: 'medicine', icon: Icons.medication_outlined, selectedIcon: Icons.medication,
      label: 'Medicine',
      builder: () => MedicineScreen(service: _medicineService),
    ));

    tabs.add(_NavTab(
      id: 'settings', icon: Icons.settings_outlined, selectedIcon: Icons.settings,
      label: 'Settings',
      builder: () => SettingsScreen(
        settingsService: _settingsService,
        familyId: widget.familyId,
        onChangeFamilyId: widget.onChangeFamilyId,
      ),
    ));

    return tabs;
  }

  @override
  Widget build(BuildContext context) {
    if (_migrating) {
      return const Scaffold(
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Migrating data...'),
      ])));
    }

    final tabs = _buildTabs();
    // Clamp tab index if tabs changed (e.g. user toggled an action off)
    final safeTab = _tab.clamp(0, tabs.length - 1);

    return PopScope(
      canPop: safeTab == 0, // only allow system back when on home tab
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && safeTab != 0) {
          setState(() => _tab = 0); // go back to home
        }
      },
      child: Scaffold(
      appBar: AppBar(title: const Text('Baby Tracker')),
      body: tabs[safeTab].builder(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: safeTab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        labelBehavior: tabs.length > 5
            ? NavigationDestinationLabelBehavior.onlyShowSelected
            : NavigationDestinationLabelBehavior.alwaysShow,
        destinations: tabs
            .map((t) => NavigationDestination(
                  icon: Icon(t.icon),
                  selectedIcon: Icon(t.selectedIcon),
                  label: t.label,
                ))
            .toList(),
      ),
    ));
  }

  @override
  void dispose() {
    _settingsSub?.cancel();
    super.dispose();
  }
}

class _FamilyCodeScreen extends StatefulWidget {
  final Future<void> Function(String) onSet;
  const _FamilyCodeScreen({required this.onSet});
  @override
  State<_FamilyCodeScreen> createState() => _FamilyCodeScreenState();
}

class _FamilyCodeScreenState extends State<_FamilyCodeScreen> {
  final _c = TextEditingController();
  bool _loading = false;

  void _submit() async {
    final code = _c.text.trim().toLowerCase().replaceAll(' ', '-');
    if (code.isEmpty) return;
    setState(() => _loading = true);
    await widget.onSet(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: SafeArea(
            child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('👶', style: TextStyle(fontSize: 64)),
                      const SizedBox(height: 16),
                      Text('Baby Tracker',
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(
                          'Enter a family code to get started.\nShare this code with your partner.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade500)),
                      const SizedBox(height: 32),
                      TextField(
                          controller: _c,
                          decoration: InputDecoration(
                              labelText: 'Family code',
                              hintText: 'e.g. smith-family',
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              prefixIcon: const Icon(Icons.family_restroom)),
                          onSubmitted: (_) => _submit()),
                      const SizedBox(height: 16),
                      SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: FilledButton(
                              onPressed: _loading ? null : _submit,
                              child: _loading
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Text('Get Started'))),
                    ]))));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }
}
