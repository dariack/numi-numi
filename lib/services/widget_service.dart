import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';
import '../services/settings_service.dart';

class WidgetService {
  final FirestoreService firestore;
  final TrackerSettings settings;

  WidgetService({required this.firestore, required this.settings});

  // Returns the 2 widget slots chosen by the user (defaults: feed + diaper)
  static Future<List<String>> getWidgetSlots() async {
    final prefs = await SharedPreferences.getInstance();
    final s1 = prefs.getString('widget_slot1_type') ?? 'feed';
    final s2 = prefs.getString('widget_slot2_type') ?? 'diaper';
    return [s1, s2];
  }

  static Future<void> setWidgetSlots(String slot1, String slot2) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('widget_slot1_type', slot1);
    await prefs.setString('widget_slot2_type', slot2);
  }

  Future<void> update() async {
    try {
      final slots = await getWidgetSlots();
      final ongoing = await firestore.getOngoing();

      for (int i = 0; i < 2; i++) {
        final type = slots[i];
        final key = 'widget_slot${i + 1}';
        final typeKey = 'widget_slot${i + 1}_type';
        final data = await _buildSlotData(type, ongoing);
        await HomeWidget.saveWidgetData<String>(key, data);
        await HomeWidget.saveWidgetData<String>(typeKey, type);
      }

      await HomeWidget.updateWidget(
          qualifiedAndroidName: 'com.example.baby_tracker.YuliWidgetProvider');
      await HomeWidget.updateWidget(
          qualifiedAndroidName: 'com.example.baby_tracker.FeedWidgetProvider');
    } catch (_) {}
  }

  /// Returns "label|value|sub" string for a given action type.
  Future<String> _buildSlotData(String type, BabyEvent? ongoing) async {
    switch (type) {
      case 'feed':
        return _buildFeed(ongoing);
      case 'sleep':
        return _buildSleep(ongoing);
      case 'diaper':
        return _buildDiaper();
      case 'pump':
        return _buildPump();
      default:
        return '';
    }
  }

  Future<String> _buildFeed(BabyEvent? ongoing) async {
    if (ongoing != null && ongoing.type == EventType.feed) {
      final elapsed = _fmtDur(DateTime.now().difference(ongoing.startTime));
      final side = ongoing.side != null ? ongoing.side![0].toUpperCase() : '';
      return '🍼 Feed|$elapsed|Feeding${side.isNotEmpty ? " ($side)" : ""}';
    }
    final lastFeed = await firestore.getLastOfType(EventType.feed);
    final sideRec = await firestore.getSideRecommendation();
    if (lastFeed == null) return '🍼 Feed|--|no data';
    final endT = lastFeed.endTime ?? lastFeed.startTime;
    final ago = _fmtDur(DateTime.now().difference(endT));
    final nextSide = sideRec['recommendedSide'];
    final sub = nextSide != null ? 'Next: ${nextSide.toUpperCase()}' : '';
    return '🍼 Feed|$ago ago|$sub';
  }

  Future<String> _buildSleep(BabyEvent? ongoing) async {
    if (ongoing != null && ongoing.type == EventType.sleep) {
      final elapsed = _fmtDur(DateTime.now().difference(ongoing.startTime));
      return '😴 Sleep|$elapsed|Sleeping';
    }
    final last = await firestore.getLastOfType(EventType.sleep);
    if (last == null) return '😴 Sleep|--|no data';
    final endT = last.endTime ?? last.startTime;
    final ago = _fmtDur(DateTime.now().difference(endT));
    return '😴 Sleep|$ago ago|';
  }

  Future<String> _buildDiaper() async {
    final last = await firestore.getLastOfType(EventType.diaper);
    if (last == null) return '🧷 Diaper|--|no data';
    final ago = _fmtDur(DateTime.now().difference(last.startTime));
    final what = last.pee && last.poop ? 'pee+💩' : last.poop ? '💩' : '💧';
    return '🧷 Diaper|$ago ago|$what';
  }

  Future<String> _buildPump() async {
    final stockMap = await firestore.getStockByStorage();
    int total = 0;
    final parts = <String>[];
    for (final entry in stockMap.entries) {
      final ml = entry.value.fold<int>(0, (s, i) => s + (i['remaining'] as int));
      total += ml;
      if (ml > 0) {
        final icon = entry.key == 'room' ? '🏠' : entry.key == 'fridge' ? '❄️' : '🧊';
        parts.add('$icon${ml}ml');
      }
    }
    if (total == 0) return '🥛 Pump|empty|';
    return '🥛 Pump|${total}ml|${parts.join(' ')}';
  }

  String _fmtDur(Duration d) {
    if (d.inHours > 0) {
      final m = d.inMinutes.remainder(60);
      return m > 0 ? '${d.inHours}h${m}m' : '${d.inHours}h';
    }
    return '${d.inMinutes}m';
  }
}
