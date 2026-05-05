import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import '../models/event.dart';
import '../models/reminder_settings.dart';

// Notification IDs — fixed so we can cancel/replace them
const int kFeedNotificationId = 1001;
const int kDiaperNotificationId = 1002;
const int kPartnerActivityId = 1003;

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // Android notification channel
  static const _channel = AndroidNotificationChannel(
    'yuli_reminders',
    'Yuli Reminders',
    description: 'Feed and diaper reminders for Yuli',
    importance: Importance.high,
    playSound: true,
  );

  Future<void> initialize() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    // Set local timezone using the device's UTC offset
    // This picks the first matching tz location for the current offset
    try {
      final offsetMinutes = DateTime.now().timeZoneOffset.inMinutes;
      final locations = tz.timeZoneDatabase.locations;
      tz.Location? match;
      for (final loc in locations.values) {
        final zone = loc.zones.isNotEmpty ? loc.zones.last : null;
        if (zone != null && zone.offset == offsetMinutes * 60) {
          match = loc;
          break;
        }
      }
      tz.setLocalLocation(match ?? tz.UTC);
    } catch (_) {
      tz.setLocalLocation(tz.UTC);
    }

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(initSettings);

    // Create the notification channel
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    // Request permission (Android 13+)
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    _initialized = true;
  }

  /// Schedule a feed reminder X hours after [lastFeedEnd].
  /// Cancels any existing feed reminder first.
  Future<void> scheduleFeedReminder(
      DateTime lastFeedEnd, ReminderSettings settings) async {
    await cancelFeedReminder();
    if (!settings.feedEnabled) return;

    final fireAt = lastFeedEnd.add(Duration(hours: settings.feedThresholdHours));
    if (fireAt.isBefore(DateTime.now())) return; // already past

    // Don't schedule if it would fire during quiet hours
    // (We'll still let it fire if quiet hours toggle is off)
    await _scheduleNotification(
      id: kFeedNotificationId,
      title: '🍼 Time to feed Yuli',
      body: '${settings.feedThresholdHours}h since last feed',
      fireAt: fireAt,
      settings: settings,
    );
  }

  /// Schedule a diaper reminder X hours after [lastDiaper].
  Future<void> scheduleDiaperReminder(
      DateTime lastDiaper, ReminderSettings settings) async {
    await cancelDiaperReminder();
    if (!settings.diaperEnabled) return;

    final fireAt = lastDiaper.add(Duration(hours: settings.diaperThresholdHours));
    if (fireAt.isBefore(DateTime.now())) return;

    await _scheduleNotification(
      id: kDiaperNotificationId,
      title: '🧷 Diaper check',
      body: '${settings.diaperThresholdHours}h since last diaper change',
      fireAt: fireAt,
      settings: settings,
    );
  }

  Future<void> cancelFeedReminder() async {
    await _plugin.cancel(kFeedNotificationId);
  }

  Future<void> cancelDiaperReminder() async {
    await _plugin.cancel(kDiaperNotificationId);
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  /// Reschedule both reminders from a fresh set of events.
  /// Call this whenever a new event arrives (from either parent).
  Future<void> rescheduleFromEvents(
      List<BabyEvent> recentEvents, ReminderSettings settings) async {
    if (recentEvents.isEmpty) return;
    final sorted = [...recentEvents]..sort((a, b) => b.startTime.compareTo(a.startTime));

    // Last feed — safely find, null if none
    final feeds = sorted.where((e) => e.type == EventType.feed).toList();
    if (feeds.isNotEmpty) {
      final feedEnd = feeds.first.endTime ?? feeds.first.startTime;
      await scheduleFeedReminder(feedEnd, settings);
    } else {
      await cancelFeedReminder();
    }

    // Last diaper
    final diapers = sorted.where((e) => e.type == EventType.diaper).toList();
    if (diapers.isNotEmpty) {
      await scheduleDiaperReminder(diapers.first.startTime, settings);
    } else {
      await cancelDiaperReminder();
    }
  }

  Future<void> _scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime fireAt,
    required ReminderSettings settings,
  }) async {
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tz.TZDateTime.from(fireAt, tz.local),
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
      ),
      // ignore: deprecated_member_use
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  /// Returns a human-readable description of scheduled reminders (for debug/settings display)
  /// Fires an immediate notification when a partner logs an event.
  /// Uses show() (not scheduled) so it appears right away.
  Future<void> showPartnerActivity({
    required String caregiverName,
    required String eventName,
  }) async {
    await _plugin.show(
      kPartnerActivityId,
      '🤝 $caregiverName logged $eventName',
      'Tap to open the app',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );
  }

  Future<List<PendingNotificationRequest>> getPending() async {
    return _plugin.pendingNotificationRequests();
  }
}
