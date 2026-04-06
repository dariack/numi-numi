import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:home_widget/home_widget.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'screens/history_screen.dart';
import 'screens/patterns_screen.dart';
import 'services/firestore_service.dart';
import 'models/event.dart';

/// Handle widget tap actions via deep link URI
Future<void> handleWidgetAction(Uri? uri, FirestoreService service) async {
  if (uri == null) return;
  final db = FirebaseFirestore.instance;
  final ref = db.collection('families').doc(service.familyId).collection('events');

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
    if (ongoing != null && ongoing.type == EventType.feed) {
      // There's an ongoing feed — don't auto-end, user will see it in the app
      return;
    }
    // Start a new feed with no side
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
  runApp(const BabyTrackerApp());
}

class BabyTrackerApp extends StatelessWidget {
  const BabyTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Baby Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF6B4EFF), brightness: Brightness.light, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF6B4EFF), brightness: Brightness.dark, useMaterial3: true),
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
    setState(() { _familyId = prefs.getString('familyId'); _loading = false; });
  }

  Future<void> _setFamilyId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('familyId', id);
    setState(() => _familyId = id);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_familyId == null || _familyId!.isEmpty) return _FamilyCodeScreen(onSet: _setFamilyId);
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
  bool _migrating = false;

  @override
  void initState() {
    super.initState();
    _service = FirestoreService(familyId: widget.familyId);
    _checkMigration();
    _handleWidgetLaunch();
  }

  Future<void> _handleWidgetLaunch() async {
    try {
      const channel = MethodChannel('app.channel.shared.data');
      final String? action = await channel.invokeMethod('getIntentAction');
      if (action != null && action.isNotEmpty) {
        await handleWidgetAction(Uri.parse('yuliTracker://$action'), _service);
        if (mounted) {
          if (action == 'logPoop') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('💩 Poop logged!'), duration: Duration(seconds: 2)),
            );
          } else if (action == 'toggleFeed') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('🍼 Feed started!'), duration: Duration(seconds: 2)),
            );
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
            SnackBar(content: Text('Migrated $count events to new format')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Migration error: $e')),
          );
        }
      }
      if (mounted) setState(() => _migrating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_migrating) {
      return const Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Migrating data...'),
      ])));
    }

    final screens = [
      HomeScreen(service: _service),
      HistoryScreen(service: _service),
      PatternsScreen(service: _service),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Baby Tracker'),
        actions: [
          PopupMenuButton(itemBuilder: (_) => [
            const PopupMenuItem(value: 'change', child: Text('Change family code')),
          ], onSelected: (v) { if (v == 'change') widget.onChangeFamilyId(); }),
        ],
      ),
      body: screens[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.history_outlined), selectedIcon: Icon(Icons.history), label: 'History'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Patterns'),
        ],
      ),
    );
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
    return Scaffold(body: SafeArea(child: Padding(padding: const EdgeInsets.all(32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Text('👶', style: TextStyle(fontSize: 64)),
        const SizedBox(height: 16),
        Text('Baby Tracker', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Enter a family code to get started.\nShare this code with your partner.',
          textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade500)),
        const SizedBox(height: 32),
        TextField(controller: _c, decoration: InputDecoration(
          labelText: 'Family code', hintText: 'e.g. smith-family',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          prefixIcon: const Icon(Icons.family_restroom)),
          onSubmitted: (_) => _submit()),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, height: 48, child: FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Get Started'))),
      ]))));
  }

  @override
  void dispose() { _c.dispose(); super.dispose(); }
}
