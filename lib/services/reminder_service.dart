import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/event.dart';
import '../models/reminder_settings.dart';
import 'notification_service.dart';

class ReminderService {
  final String familyId;
  ReminderService({required this.familyId});

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  DocumentReference get _settingsRef => _db
      .collection('families')
      .doc(familyId)
      .collection('settings')
      .doc('notifications');

  ReminderSettings _current = const ReminderSettings();
  StreamSubscription<DocumentSnapshot>? _settingsSub;

  ReminderSettings get current => _current;

  // ── Firestore sync ──────────────────────────────────────────────

  /// Start listening to settings changes from Firestore.
  /// When the other parent updates settings, we reschedule immediately.
  void startListening({
    required Stream<List<BabyEvent>> eventsStream,
  }) {
    _settingsSub?.cancel();
    _settingsSub = _settingsRef.snapshots().listen((snap) async {
      if (snap.exists && snap.data() != null) {
        _current = ReminderSettings.fromFirestore(
            snap.data() as Map<String, dynamic>);
      } else {
        // No settings yet — use defaults and write them
        _current = const ReminderSettings();
        await _settingsRef.set(_current.toFirestore());
      }
    });
  }

  void dispose() {
    _settingsSub?.cancel();
  }

  // ── Settings updates ────────────────────────────────────────────

  Future<void> updateSettings(ReminderSettings newSettings) async {
    _current = newSettings;
    await _settingsRef.set(newSettings.toFirestore());
  }

  Future<ReminderSettings> loadSettings() async {
    try {
      final snap = await _settingsRef.get();
      if (snap.exists && snap.data() != null) {
        _current = ReminderSettings.fromFirestore(
            snap.data() as Map<String, dynamic>);
      } else {
        _current = const ReminderSettings();
        await _settingsRef.set(_current.toFirestore());
      }
    } catch (_) {
      _current = const ReminderSettings();
    }
    return _current;
  }

  // ── Scheduling ──────────────────────────────────────────────────

  /// Called whenever a new event is received (from stream or on app open).
  /// Reschedules reminders based on the latest event times.
  Future<void> onNewEvent(BabyEvent event) async {
    if (_current.isQuietNow()) return;

    switch (event.type) {
      case EventType.feed:
        if (_current.feedEnabled) {
          final dur = event.durationMinutes;
          final feedEnd = (dur != null && dur > 0 && event.source != 'pump')
              ? event.startTime.add(Duration(minutes: dur))
              : (event.endTime ?? event.startTime);
          await NotificationService.instance
              .scheduleFeedReminder(feedEnd, _current);
        }
        break;
      case EventType.diaper:
        if (_current.diaperEnabled) {
          await NotificationService.instance
              .scheduleDiaperReminder(event.startTime, _current);
        }
        break;
      default:
        break;
    }
  }

  /// Full reschedule from a list of recent events.
  /// Called on app open and when settings change.
  Future<void> rescheduleAll(List<BabyEvent> recentEvents) async {
    if (_current.isQuietNow()) {
      await NotificationService.instance.cancelAll();
      return;
    }
    await NotificationService.instance
        .rescheduleFromEvents(recentEvents, _current);
  }
}
