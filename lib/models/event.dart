import 'package:cloud_firestore/cloud_firestore.dart';

enum EventType { sleep, feed, diaper, pump }

class BabyEvent {
  final String id;
  final EventType type;
  final DateTime startTime;
  final DateTime? endTime;
  final int? durationMinutes;
  final String? side; // left/right/both for feed & pump
  final bool pee;
  final bool poop;
  final String? createdBy;
  final DateTime createdAt;

  // Pump fields
  final int? ml;
  final String? storage; // room/fridge/freezer
  final DateTime? expiresAt;
  final bool spoiled;
  final String? pumpId;

  // Feed-from-pump fields
  final String? source; // breast/pump
  final String? linkedPumpId; // legacy single pump link
  final String? linkedPumps; // JSON: [{"id":"abc","ml":80},...]
  final int? mlFed;

  BabyEvent({
    required this.id,
    required this.type,
    required this.startTime,
    this.endTime,
    this.durationMinutes,
    this.side,
    this.pee = false,
    this.poop = false,
    this.createdBy,
    DateTime? createdAt,
    this.ml,
    this.storage,
    this.expiresAt,
    this.spoiled = false,
    this.pumpId,
    this.source,
    this.linkedPumpId,
    this.linkedPumps,
    this.mlFed,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isOngoing =>
      (type == EventType.sleep || type == EventType.feed) &&
      source != 'pump' &&
      durationMinutes == null &&
      endTime == null;

  Duration? get duration {
    if (durationMinutes != null) return Duration(minutes: durationMinutes!);
    if (endTime != null) return endTime!.difference(startTime);
    return null;
  }

  String get durationText {
    final d = duration;
    if (d == null) return 'ongoing';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    return '${d.inMinutes}m';
  }

  String get displayName {
    switch (type) {
      case EventType.sleep:
        return '😴 Sleep';
      case EventType.feed:
        if (source == 'pump') return '🍼 Feed (pumped)';
        return '🍼 Feed';
      case EventType.diaper:
        if (pee && poop) return '🧷 Pee + Poop';
        if (poop) return '💩 Poop';
        if (pee) return '💧 Pee';
        return '🧷 Diaper';
      case EventType.pump:
        return '🥛 Pump';
    }
  }

  String get emoji {
    switch (type) {
      case EventType.sleep:
        return '😴';
      case EventType.feed:
        return '🍼';
      case EventType.diaper:
        if (pee && poop) return '🧷';
        if (poop) return '💩';
        return '💧';
      case EventType.pump:
        return '🥛';
    }
  }

  String get readablePumpId {
    if (pumpId != null) return pumpId!;
    if (type != EventType.pump) return '';
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final d = startTime;
    final dateStr =
        '${months[d.month - 1]} ${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final mlStr = ml != null ? ' · ${ml}ml' : '';
    final storStr = storage != null ? ' · $storage' : '';
    return '$dateStr$mlStr$storStr';
  }

  static DateTime? calcExpiration(DateTime start, String? storage) {
    if (storage == null) return null;
    switch (storage) {
      case 'room':
        return start.add(const Duration(hours: 4));
      case 'fridge':
        return start.add(const Duration(days: 4));
      case 'freezer':
        return start.add(const Duration(days: 180));
      default:
        return null;
    }
  }

  bool get isExpired {
    if (spoiled) return true;
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  Duration? get timeUntilExpiry {
    if (expiresAt == null) return null;
    final diff = expiresAt!.difference(DateTime.now());
    return diff.isNegative ? null : diff;
  }

  factory BabyEvent.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return BabyEvent(
      id: doc.id,
      type: EventType.values.firstWhere((e) => e.name == d['type']),
      startTime: (d['startTime'] as Timestamp).toDate(),
      endTime: d['endTime'] != null ? (d['endTime'] as Timestamp).toDate() : null,
      durationMinutes: d['duration'] as int?,
      side: d['side'] as String?,
      pee: d['pee'] ?? false,
      poop: d['poop'] ?? false,
      createdBy: d['createdBy'] as String?,
      createdAt: d['createdAt'] != null
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      ml: d['ml'] as int?,
      storage: d['storage'] as String?,
      expiresAt: d['expiresAt'] != null
          ? (d['expiresAt'] as Timestamp).toDate()
          : null,
      spoiled: d['spoiled'] ?? false,
      pumpId: d['pumpId'] as String?,
      source: d['source'] as String?,
      linkedPumpId: d['linkedPumpId'] as String?,
      linkedPumps: d['linkedPumps'] as String?,
      mlFed: d['mlFed'] as int?,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'type': type.name,
      'startTime': Timestamp.fromDate(startTime),
      if (endTime != null) 'endTime': Timestamp.fromDate(endTime!),
      if (durationMinutes != null) 'duration': durationMinutes,
      if (side != null) 'side': side,
      'pee': pee,
      'poop': poop,
      if (createdBy != null) 'createdBy': createdBy,
      'createdAt': Timestamp.fromDate(createdAt),
      if (ml != null) 'ml': ml,
      if (storage != null) 'storage': storage,
      if (expiresAt != null) 'expiresAt': Timestamp.fromDate(expiresAt!),
      'spoiled': spoiled,
      if (pumpId != null) 'pumpId': pumpId,
      if (source != null) 'source': source,
      if (linkedPumpId != null) 'linkedPumpId': linkedPumpId,
      if (linkedPumps != null) 'linkedPumps': linkedPumps,
      if (mlFed != null) 'mlFed': mlFed,
    };
  }

  BabyEvent copyWith({
    DateTime? startTime,
    DateTime? endTime,
    int? durationMinutes,
    String? side,
    bool? pee,
    bool? poop,
    int? ml,
    String? storage,
    DateTime? expiresAt,
    bool? spoiled,
    String? pumpId,
    String? source,
    String? linkedPumpId,
    String? linkedPumps,
    int? mlFed,
    bool clearEndTime = false,
    bool clearDuration = false,
    bool clearSide = false,
  }) {
    return BabyEvent(
      id: id,
      type: type,
      startTime: startTime ?? this.startTime,
      endTime: clearEndTime ? null : (endTime ?? this.endTime),
      durationMinutes: clearDuration ? null : (durationMinutes ?? this.durationMinutes),
      side: clearSide ? null : (side ?? this.side),
      pee: pee ?? this.pee,
      poop: poop ?? this.poop,
      createdBy: createdBy,
      createdAt: createdAt,
      ml: ml ?? this.ml,
      storage: storage ?? this.storage,
      expiresAt: expiresAt ?? this.expiresAt,
      spoiled: spoiled ?? this.spoiled,
      pumpId: pumpId ?? this.pumpId,
      source: source ?? this.source,
      linkedPumpId: linkedPumpId ?? this.linkedPumpId,
      linkedPumps: linkedPumps ?? this.linkedPumps,
      mlFed: mlFed ?? this.mlFed,
    );
  }
}
