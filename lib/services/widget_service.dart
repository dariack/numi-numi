import 'package:home_widget/home_widget.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';

/// Writes latest baby stats to shared preferences so the native Android
/// widget can read and display them. Call [update] after every data change.
class WidgetService {
  final FirestoreService firestore;

  WidgetService({required this.firestore});

  Future<void> update() async {
    try {
      final lastSleep = await firestore.getLastOfType(EventType.sleep);
      final lastFeed = await firestore.getLastOfType(EventType.feed);
      final ongoing = await firestore.getOngoing();

      // Feed data — all stored as strings for cross-platform safety
      if (ongoing != null && ongoing.type == EventType.feed) {
        final elapsed = _fmtDuration(DateTime.now().difference(ongoing.startTime));
        final sideStr = ongoing.side != null ? ' (${ongoing.side})' : '';
        await HomeWidget.saveWidgetData<String>('feed_line1', 'Feeding now$sideStr');
        await HomeWidget.saveWidgetData<String>('feed_line2', '$elapsed and counting');
        await HomeWidget.saveWidgetData<String>('has_ongoing_feed', 'true');
      } else if (lastFeed != null) {
        final endT = lastFeed.endTime ?? lastFeed.startTime;
        final ago = _fmtDuration(DateTime.now().difference(endT));
        final side = lastFeed.side ?? await _findLastSide();
        final sideStr = side != null ? ' · $side' : '';
        await HomeWidget.saveWidgetData<String>('feed_line1', 'Feed: $ago ago$sideStr');
        final dur = lastFeed.durationMinutes != null ? 'Duration: ${_fmtMinutes(lastFeed.durationMinutes!)}' : '';
        await HomeWidget.saveWidgetData<String>('feed_line2', dur);
        await HomeWidget.saveWidgetData<String>('has_ongoing_feed', 'false');
      } else {
        await HomeWidget.saveWidgetData<String>('feed_line1', 'Feed: --');
        await HomeWidget.saveWidgetData<String>('feed_line2', '');
        await HomeWidget.saveWidgetData<String>('has_ongoing_feed', 'false');
      }

      // Sleep data
      if (ongoing != null && ongoing.type == EventType.sleep) {
        final elapsed = _fmtDuration(DateTime.now().difference(ongoing.startTime));
        await HomeWidget.saveWidgetData<String>('sleep_line1', 'Sleeping now');
        await HomeWidget.saveWidgetData<String>('sleep_line2', '$elapsed and counting');
      } else if (lastSleep != null) {
        final endT = lastSleep.endTime ?? lastSleep.startTime;
        final ago = _fmtDuration(DateTime.now().difference(endT));
        await HomeWidget.saveWidgetData<String>('sleep_line1', 'Sleep: $ago ago');
        final dur = lastSleep.durationMinutes != null ? 'Duration: ${_fmtMinutes(lastSleep.durationMinutes!)}' : '';
        await HomeWidget.saveWidgetData<String>('sleep_line2', dur);
      } else {
        await HomeWidget.saveWidgetData<String>('sleep_line1', 'Sleep: --');
        await HomeWidget.saveWidgetData<String>('sleep_line2', '');
      }

      // Trigger native widget refreshes
      await HomeWidget.updateWidget(
        qualifiedAndroidName: 'com.example.baby_tracker.YuliWidgetProvider',
      );
      await HomeWidget.updateWidget(
        qualifiedAndroidName: 'com.example.baby_tracker.FeedWidgetProvider',
      );
    } catch (e) {
      // Widget update is best-effort, don't crash the app
    }
  }

  Future<String?> _findLastSide() async {
    try {
      final events = await firestore.getRecentFeeds(10);
      for (final e in events) {
        if (e.side != null) return e.side;
      }
    } catch (_) {}
    return null;
  }

  String _fmtDuration(Duration d) {
    if (d.inHours > 0) {
      final m = d.inMinutes.remainder(60);
      return m > 0 ? '${d.inHours}h ${m}m' : '${d.inHours}h';
    }
    return '${d.inMinutes}m';
  }

  String _fmtMinutes(int min) {
    if (min >= 60) {
      final h = min ~/ 60;
      final m = min % 60;
      return m > 0 ? '${h}h ${m}m' : '${h}h';
    }
    return '${min}m';
  }
}
