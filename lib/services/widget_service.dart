import 'package:home_widget/home_widget.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';
import '../services/settings_service.dart';

/// Writes latest baby stats to shared preferences so the native Android
/// widget can read and display them. Call [update] after every data change.
class WidgetService {
  final FirestoreService firestore;
  final TrackerSettings settings;

  WidgetService({required this.firestore, required this.settings});

  Future<void> update() async {
    try {
      final ongoing = await firestore.getOngoing();

      // Feed
      if (settings.trackFeed) {
        if (ongoing != null && ongoing.type == EventType.feed) {
          final elapsed = _fmtDur(DateTime.now().difference(ongoing.startTime));
          final sideStr = ongoing.side != null ? ' (${ongoing.side})' : '';
          await HomeWidget.saveWidgetData<String>('feed_line1', '🍼 Feeding$sideStr $elapsed');
        } else {
          final lastFeed = await firestore.getLastOfType(EventType.feed);
          final sideRec = await firestore.getSideRecommendation();
          if (lastFeed != null) {
            final endT = lastFeed.endTime ?? lastFeed.startTime;
            final ago = _fmtDur(DateTime.now().difference(endT));
            final nextSide = sideRec['recommendedSide'];
            final nextStr = nextSide != null ? ' · next: ${nextSide.toUpperCase()}' : '';
            await HomeWidget.saveWidgetData<String>('feed_line1', '🍼 $ago ago$nextStr');
          } else {
            await HomeWidget.saveWidgetData<String>('feed_line1', '🍼 --');
          }
        }
      } else {
        await HomeWidget.saveWidgetData<String>('feed_line1', '');
      }

      // Sleep
      if (settings.trackSleep) {
        if (ongoing != null && ongoing.type == EventType.sleep) {
          final elapsed = _fmtDur(DateTime.now().difference(ongoing.startTime));
          await HomeWidget.saveWidgetData<String>('sleep_line1', '😴 Sleeping $elapsed');
        } else {
          final lastSleep = await firestore.getLastOfType(EventType.sleep);
          if (lastSleep != null) {
            final endT = lastSleep.endTime ?? lastSleep.startTime;
            final ago = _fmtDur(DateTime.now().difference(endT));
            await HomeWidget.saveWidgetData<String>('sleep_line1', '😴 $ago ago');
          } else {
            await HomeWidget.saveWidgetData<String>('sleep_line1', '😴 --');
          }
        }
      } else {
        await HomeWidget.saveWidgetData<String>('sleep_line1', '');
      }

      // Diaper
      if (settings.trackDiaper) {
        final lastDiaper = await firestore.getLastOfType(EventType.diaper);
        if (lastDiaper != null) {
          final ago = _fmtDur(DateTime.now().difference(lastDiaper.startTime));
          final what = lastDiaper.pee && lastDiaper.poop ? 'pee+💩' : lastDiaper.poop ? '💩' : '💧';
          await HomeWidget.saveWidgetData<String>('diaper_line1', '🧷 $ago ago ($what)');
        } else {
          await HomeWidget.saveWidgetData<String>('diaper_line1', '🧷 --');
        }
      } else {
        await HomeWidget.saveWidgetData<String>('diaper_line1', '');
      }

      // Pump
      if (settings.trackPump) {
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
        if (total > 0) {
          await HomeWidget.saveWidgetData<String>('pump_line1', '🥛 Stock: ${total}ml (${parts.join(' ')})');
        } else {
          await HomeWidget.saveWidgetData<String>('pump_line1', '🥛 Stock: empty');
        }
      } else {
        await HomeWidget.saveWidgetData<String>('pump_line1', '');
      }

      // Tell widget how many rows to show
      int rows = 0;
      if (settings.trackFeed) rows++;
      if (settings.trackSleep) rows++;
      if (settings.trackDiaper) rows++;
      if (settings.trackPump) rows++;
      await HomeWidget.saveWidgetData<int>('row_count', rows);

      await HomeWidget.updateWidget(qualifiedAndroidName: 'com.example.baby_tracker.YuliWidgetProvider');
      await HomeWidget.updateWidget(qualifiedAndroidName: 'com.example.baby_tracker.FeedWidgetProvider');
    } catch (e) {
      // Widget update is best-effort
    }
  }

  String _fmtDur(Duration d) {
    if (d.inHours > 0) {
      final m = d.inMinutes.remainder(60);
      return m > 0 ? '${d.inHours}h${m}m' : '${d.inHours}h';
    }
    return '${d.inMinutes}m';
  }
}
