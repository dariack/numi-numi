import 'package:cloud_firestore/cloud_firestore.dart';

enum EventType { sleep, feed, diaper }

class BabyEvent {
  final String id;
  final EventType type;
  final DateTime startTime;
  final DateTime? endTime;
  final int? durationMinutes; // null = ongoing
  final String? side; // left/right for feed
  final bool pee; // for diaper
  final bool poop; // for diaper
  final String? createdBy;
  final DateTime createdAt;

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
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isOngoing => type != EventType.diaper && durationMinutes == null && endTime == null;

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
      case EventType.sleep: return '😴 Sleep';
      case EventType.feed:
        return '🍼 Feed';
      case EventType.diaper:
        if (pee && poop) return '🧷 Pee + Poop';
        if (poop) return '💩 Poop';
        if (pee) return '💧 Pee';
        return '🧷 Diaper';
    }
  }

  String get emoji {
    switch (type) {
      case EventType.sleep: return '😴';
      case EventType.feed: return '🍼';
      case EventType.diaper:
        if (pee && poop) return '🧷';
        if (poop) return '💩';
        return '💧';
    }
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
      createdAt: d['createdAt'] != null ? (d['createdAt'] as Timestamp).toDate() : DateTime.now(),
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
    };
  }

  BabyEvent copyWith({
    DateTime? startTime,
    DateTime? endTime,
    int? durationMinutes,
    String? side,
    bool? pee,
    bool? poop,
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
    );
  }
}
