import 'package:cloud_firestore/cloud_firestore.dart';

enum ScheduleType { onceDailyAt, customTimes, specificDays, asNeeded }

class Medicine {
  final String id;
  final String name;
  final String? dose;           // optional
  final ScheduleType scheduleType;
  final List<String> timesOfDay; // ["08:00", "20:00"]
  final List<int> daysOfWeek;   // 0=Mon…6=Sun, only for specificDays
  final bool active;
  final DateTime createdAt;

  const Medicine({
    required this.id,
    required this.name,
    this.dose,
    required this.scheduleType,
    required this.timesOfDay,
    this.daysOfWeek = const [],
    this.active = true,
    required this.createdAt,
  });

  String get displayName => dose != null ? '$name ($dose)' : name;

  /// Human-readable schedule description
  String get scheduleDescription {
    switch (scheduleType) {
      case ScheduleType.asNeeded:
        return 'As needed';
      case ScheduleType.onceDailyAt:
        return 'Once daily at ${timesOfDay.first}';
      case ScheduleType.customTimes:
        return '${timesOfDay.length}× daily at ${timesOfDay.join(', ')}';
      case ScheduleType.specificDays:
        const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        final days = daysOfWeek.map((d) => dayNames[d % 7]).join(', ');
        final times = timesOfDay.join(', ');
        return '$days at $times';
    }
  }

  factory Medicine.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return Medicine(
      id: doc.id,
      name: d['name'] as String,
      dose: d['dose'] as String?,
      scheduleType: ScheduleType.values.firstWhere(
        (e) => e.name == (d['scheduleType'] as String? ?? 'asNeeded'),
        orElse: () => ScheduleType.asNeeded,
      ),
      timesOfDay: List<String>.from(d['timesOfDay'] ?? []),
      daysOfWeek: List<int>.from(d['daysOfWeek'] ?? []),
      active: d['active'] as bool? ?? true,
      createdAt: (d['createdAt'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toFirestore() => {
    'name': name,
    if (dose != null) 'dose': dose,
    'scheduleType': scheduleType.name,
    'timesOfDay': timesOfDay,
    'daysOfWeek': daysOfWeek,
    'active': active,
    'createdAt': Timestamp.fromDate(createdAt),
  };
}

class MedicineGiven {
  final String id;
  final String medicineId;
  final String medicineName;
  final String? dose;
  final DateTime givenAt;
  final String givenBy;
  final String? scheduledTime; // which scheduled slot this satisfies

  const MedicineGiven({
    required this.id,
    required this.medicineId,
    required this.medicineName,
    this.dose,
    required this.givenAt,
    required this.givenBy,
    this.scheduledTime,
  });

  factory MedicineGiven.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return MedicineGiven(
      id: doc.id,
      medicineId: d['medicineId'] as String,
      medicineName: d['medicineName'] as String? ?? '',
      dose: d['dose'] as String?,
      givenAt: (d['givenAt'] as Timestamp).toDate(),
      givenBy: d['givenBy'] as String? ?? 'app',
      scheduledTime: d['scheduledTime'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() => {
    'medicineId': medicineId,
    'medicineName': medicineName,
    if (dose != null) 'dose': dose,
    'givenAt': Timestamp.fromDate(givenAt),
    'givenBy': givenBy,
    if (scheduledTime != null) 'scheduledTime': scheduledTime,
  };
}
