import 'package:cloud_firestore/cloud_firestore.dart';

class ReminderSettings {
  final bool feedEnabled;
  final int feedThresholdHours;
  final bool diaperEnabled;
  final int diaperThresholdHours;
  final bool quietHoursEnabled;
  final String quietFrom; // "HH:MM"
  final String quietTo;   // "HH:MM"

  const ReminderSettings({
    this.feedEnabled = true,
    this.feedThresholdHours = 3,
    this.diaperEnabled = true,
    this.diaperThresholdHours = 3,
    this.quietHoursEnabled = false,
    this.quietFrom = '22:00',
    this.quietTo = '07:00',
  });

  bool get hasAnyEnabled => feedEnabled || diaperEnabled;

  /// Returns true if current time is within quiet hours window.
  bool isQuietNow() {
    if (!quietHoursEnabled) return false;
    final now = DateTime.now();
    final nowMins = now.hour * 60 + now.minute;

    final fromParts = quietFrom.split(':');
    final toParts = quietTo.split(':');
    final fromMins = int.parse(fromParts[0]) * 60 + int.parse(fromParts[1]);
    final toMins = int.parse(toParts[0]) * 60 + int.parse(toParts[1]);

    if (fromMins <= toMins) {
      return nowMins >= fromMins && nowMins < toMins;
    } else {
      // Wraps midnight e.g. 22:00 → 07:00
      return nowMins >= fromMins || nowMins < toMins;
    }
  }

  factory ReminderSettings.fromFirestore(Map<String, dynamic> d) {
    return ReminderSettings(
      feedEnabled: d['feedEnabled'] as bool? ?? true,
      feedThresholdHours: (d['feedThresholdHours'] as num?)?.toInt() ?? 3,
      diaperEnabled: d['diaperEnabled'] as bool? ?? true,
      diaperThresholdHours: (d['diaperThresholdHours'] as num?)?.toInt() ?? 3,
      quietHoursEnabled: d['quietHoursEnabled'] as bool? ?? false,
      quietFrom: d['quietFrom'] as String? ?? '22:00',
      quietTo: d['quietTo'] as String? ?? '07:00',
    );
  }

  Map<String, dynamic> toFirestore() => {
    'feedEnabled': feedEnabled,
    'feedThresholdHours': feedThresholdHours,
    'diaperEnabled': diaperEnabled,
    'diaperThresholdHours': diaperThresholdHours,
    'quietHoursEnabled': quietHoursEnabled,
    'quietFrom': quietFrom,
    'quietTo': quietTo,
  };

  ReminderSettings copyWith({
    bool? feedEnabled,
    int? feedThresholdHours,
    bool? diaperEnabled,
    int? diaperThresholdHours,
    bool? quietHoursEnabled,
    String? quietFrom,
    String? quietTo,
  }) => ReminderSettings(
    feedEnabled: feedEnabled ?? this.feedEnabled,
    feedThresholdHours: feedThresholdHours ?? this.feedThresholdHours,
    diaperEnabled: diaperEnabled ?? this.diaperEnabled,
    diaperThresholdHours: diaperThresholdHours ?? this.diaperThresholdHours,
    quietHoursEnabled: quietHoursEnabled ?? this.quietHoursEnabled,
    quietFrom: quietFrom ?? this.quietFrom,
    quietTo: quietTo ?? this.quietTo,
  );
}
