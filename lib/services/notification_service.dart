import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import '../models/event.dart';
import '../models/reminder_settings.dart';

// Notification IDs — fixed so we can cancel/replace them
const int kFeedNotificationId = 1001;
const int kDiaperNotificationId = 1002;
const int kPartnerActivityId = 1003;
const int kOngoingFeedId = 1004;

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // Android notification channels
  static const _channel = AndroidNotificationChannel(
    'yuli_reminders',
    'Yuli Reminders',
    description: 'Feed and diaper reminders for Yuli',
    importance: Importance.high,
    playSound: true,
  );

  static const _ongoingChannel = AndroidNotificationChannel(
    'feeding_ongoing',
    'Ongoing Feed',
    description: 'Live timer shown while a feeding session is active',
    importance: Importance.low,
    playSound: false,
    enableVibration: false,
  );

  Future<void> initialize() async {
    if (_initialized) return;

    tz_data.initializeTimeZones();
    try {
      final tzInfo = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(tzInfo.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.UTC);
    }

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );

    await _plugin.initialize(initSettings);

    // Create Android notification channels
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(_channel);
    await androidPlugin?.createNotificationChannel(_ongoingChannel);

    // Request Android 13+ notification permission
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();


    // Request iOS permission explicitly
    await _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    _initialized = true;
  }

  NotificationDetails get _details => NotificationDetails(
    android: AndroidNotificationDetails(
      _channel.id,
      _channel.name,
      channelDescription: _channel.description,
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    ),
    iOS: const DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    ),
    macOS: const DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    ),
  );

  /// Schedule a feed reminder X hours after [lastFeedEnd].
  /// Cancels any existing feed reminder first.
  Future<void> scheduleFeedReminder(
      DateTime lastFeedEnd, ReminderSettings settings) async {
    await cancelFeedReminder();
    if (!settings.feedEnabled) return;

    final fireAt = lastFeedEnd.add(Duration(hours: settings.feedThresholdHours));
    if (fireAt.isBefore(DateTime.now())) return; // already past

    await _scheduleNotification(
      id: kFeedNotificationId,
      title: '🍼 Time to feed Yuli',
      body: '${settings.feedThresholdHours}h since last feed',
      fireAt: fireAt,
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

  /// Shows a sticky chronometer notification on Android while a feed is active.
  /// Safe to call repeatedly — replaces the same notification ID in place.
  /// No-op on iOS/macOS (no equivalent without Live Activities).
  Future<void> showOngoingFeed(DateTime startTime) async {
    if (!Platform.isAndroid) return;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _ongoingChannel.id,
        _ongoingChannel.name,
        channelDescription: _ongoingChannel.description,
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        showWhen: true,
        when: startTime.millisecondsSinceEpoch,
        usesChronometer: true,
        icon: '@mipmap/ic_launcher',
      ),
    );
    await _plugin.show(
      kOngoingFeedId,
      '🍼 Feeding in progress',
      'Tap to open the app',
      details,
    );
  }

  Future<void> cancelOngoingFeed() async {
    await _plugin.cancel(kOngoingFeedId);
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
      final f = feeds.first;
      final dur = f.durationMinutes;
      final feedEnd = (dur != null && dur > 0 && f.source != 'pump')
          ? f.startTime.add(Duration(minutes: dur))
          : (f.endTime ?? f.startTime);
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
  }) async {
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tz.TZDateTime.from(fireAt, tz.local),
      _details,
      // ignore: deprecated_member_use
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  /// Fires an immediate notification when a partner logs an event.
  Future<void> showPartnerActivity({
    required String caregiverName,
    required String eventName,
  }) async {
    await _plugin.show(
      kPartnerActivityId,
      '🤝 $caregiverName logged $eventName',
      'Tap to open the app',
      _details,
    );
  }

  Future<List<PendingNotificationRequest>> getPending() async {
    return _plugin.pendingNotificationRequests();
  }
}
