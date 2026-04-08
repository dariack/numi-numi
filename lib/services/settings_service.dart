import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

class TrackerSettings {
  final bool trackSleep;
  final bool trackFeed;
  final bool trackDiaper;
  final bool trackPump;

  const TrackerSettings({
    this.trackSleep = true,
    this.trackFeed = true,
    this.trackDiaper = true,
    this.trackPump = false,
  });

  factory TrackerSettings.fromMap(Map<String, dynamic> d) {
    return TrackerSettings(
      trackSleep: d['trackSleep'] ?? true,
      trackFeed: d['trackFeed'] ?? true,
      trackDiaper: d['trackDiaper'] ?? true,
      trackPump: d['trackPump'] ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
        'trackSleep': trackSleep,
        'trackFeed': trackFeed,
        'trackDiaper': trackDiaper,
        'trackPump': trackPump,
      };

  TrackerSettings copyWith({
    bool? trackSleep,
    bool? trackFeed,
    bool? trackDiaper,
    bool? trackPump,
  }) {
    return TrackerSettings(
      trackSleep: trackSleep ?? this.trackSleep,
      trackFeed: trackFeed ?? this.trackFeed,
      trackDiaper: trackDiaper ?? this.trackDiaper,
      trackPump: trackPump ?? this.trackPump,
    );
  }
}

class SettingsService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final String familyId;

  SettingsService({required this.familyId});

  DocumentReference get _ref =>
      _db.collection('families').doc(familyId).collection('settings').doc('config');

  Stream<TrackerSettings> stream() {
    return _ref.snapshots().map((snap) {
      if (!snap.exists) return const TrackerSettings();
      return TrackerSettings.fromMap(snap.data() as Map<String, dynamic>);
    });
  }

  Future<TrackerSettings> get() async {
    final snap = await _ref.get();
    if (!snap.exists) return const TrackerSettings();
    return TrackerSettings.fromMap(snap.data() as Map<String, dynamic>);
  }

  Future<void> save(TrackerSettings settings) async {
    await _ref.set(settings.toMap());
  }
}
