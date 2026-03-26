import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/event.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final String familyId;

  FirestoreService({required this.familyId});

  CollectionReference get _ref =>
      _db.collection('families').doc(familyId).collection('events');

  // ===== WRITE =====

  Future<BabyEvent> addEvent(BabyEvent event) async {
    final docRef = await _ref.add(event.toFirestore());
    final doc = await docRef.get();
    return BabyEvent.fromFirestore(doc);
  }

  Future<void> updateEvent(BabyEvent event) async {
    await _ref.doc(event.id).set(event.toFirestore());
  }

  Future<void> deleteEvent(String eventId) async {
    await _ref.doc(eventId).delete();
  }

  /// Complete an ongoing event (baby woke up / stopped feeding)
  Future<void> completeOngoing(String eventId, {int? durationMinutes}) async {
    final now = DateTime.now();
    final doc = await _ref.doc(eventId).get();
    if (!doc.exists) return;
    final event = BabyEvent.fromFirestore(doc);
    final dur = durationMinutes ?? now.difference(event.startTime).inMinutes;
    await _ref.doc(eventId).update({
      'endTime': Timestamp.fromDate(now),
      'duration': dur,
    });
  }

  // ===== READ =====

  Stream<List<BabyEvent>> eventsStream({int limit = 200}) {
    return _ref
        .orderBy('startTime', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) {
              try { return BabyEvent.fromFirestore(d); }
              catch (e) { print('PARSE ERROR: \$e for doc \${d.id} data: \${d.data()}'); return null; }
            })
            .whereType<BabyEvent>()
            .toList());
  }

  Stream<List<BabyEvent>> eventsByTypeStream(EventType type, {int limit = 100}) {
    return _ref
        .where('type', isEqualTo: type.name)
        .orderBy('startTime', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) { try { return BabyEvent.fromFirestore(d); } catch (_) { return null; } })
            .whereType<BabyEvent>()
            .toList());
  }

  Future<BabyEvent?> getLastOfType(EventType type) async {
    final snap = await _ref
        .where('type', isEqualTo: type.name)
        .orderBy('startTime', descending: true)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    try { return BabyEvent.fromFirestore(snap.docs.first); }
    catch (_) { return null; }
  }

  Future<BabyEvent?> getOngoing() async {
    // Find events with no duration and no endTime, type sleep or feed
    // Check recent sleep events
    final sleepSnap = await _ref
        .where('type', isEqualTo: 'sleep')
        .orderBy('startTime', descending: true)
        .limit(1)
        .get();
    if (sleepSnap.docs.isNotEmpty) {
      final e = BabyEvent.fromFirestore(sleepSnap.docs.first);
      if (e.isOngoing) return e;
    }
    final feedSnap = await _ref
        .where('type', isEqualTo: 'feed')
        .orderBy('startTime', descending: true)
        .limit(1)
        .get();
    if (feedSnap.docs.isNotEmpty) {
      final e = BabyEvent.fromFirestore(feedSnap.docs.first);
      if (e.isOngoing) return e;
    }
    return null;
  }

  Future<Map<String, dynamic>> getQuickStats() async {
    final now = DateTime.now();
    final results = await Future.wait([
      getLastOfType(EventType.sleep),
      getLastOfType(EventType.feed),
      getLastOfType(EventType.diaper),
      getOngoing(),
    ]);
    final lastSleep = results[0];
    final lastFeed = results[1];
    final lastDiaper = results[2];
    final ongoing = results[3];

    // 24h diaper counts
    final dayAgo = now.subtract(const Duration(hours: 24));
    final diaperSnap = await _ref
        .where('type', isEqualTo: 'diaper')
        .where('startTime', isGreaterThanOrEqualTo: Timestamp.fromDate(dayAgo))
        .orderBy('startTime', descending: true)
        .get();
    final diapers24h = diaperSnap.docs
        .map((d) { try { return BabyEvent.fromFirestore(d); } catch (_) { return null; } })
        .whereType<BabyEvent>()
        .toList();
    final pees24h = diapers24h.where((e) => e.pee).length;
    final poops24h = diapers24h.where((e) => e.poop).length;

    // 3 day averages
    final threeDaysAgo = now.subtract(const Duration(days: 3));
    final diaper3dSnap = await _ref
        .where('type', isEqualTo: 'diaper')
        .where('startTime', isGreaterThanOrEqualTo: Timestamp.fromDate(threeDaysAgo))
        .orderBy('startTime', descending: true)
        .get();
    final diapers3d = diaper3dSnap.docs
        .map((d) { try { return BabyEvent.fromFirestore(d); } catch (_) { return null; } })
        .whereType<BabyEvent>()
        .toList();
    final pees3d = diapers3d.where((e) => e.pee).length;
    final poops3d = diapers3d.where((e) => e.poop).length;

    // Last side fed
    String? lastSide;
    if (lastFeed?.side != null) {
      lastSide = lastFeed!.side;
    } else {
      // Look further back for a feed with a side
      final feedSnap = await _ref
          .where('type', isEqualTo: 'feed')
          .orderBy('startTime', descending: true)
          .limit(10)
          .get();
      for (final doc in feedSnap.docs) {
        try {
          final e = BabyEvent.fromFirestore(doc);
          if (e.side != null) { lastSide = e.side; break; }
        } catch (_) {}
      }
    }

    final countResults = await Future.wait([
      _ref.where('type', isEqualTo: 'sleep').where('startTime', isGreaterThanOrEqualTo: Timestamp.fromDate(dayAgo)).orderBy('startTime', descending: true).get(),
      _ref.where('type', isEqualTo: 'feed').where('startTime', isGreaterThanOrEqualTo: Timestamp.fromDate(dayAgo)).orderBy('startTime', descending: true).get(),
      _ref.where('type', isEqualTo: 'sleep').where('startTime', isGreaterThanOrEqualTo: Timestamp.fromDate(threeDaysAgo)).orderBy('startTime', descending: true).get(),
      _ref.where('type', isEqualTo: 'feed').where('startTime', isGreaterThanOrEqualTo: Timestamp.fromDate(threeDaysAgo)).orderBy('startTime', descending: true).get(),
    ]);
    final sleeps24h = countResults[0].docs.length;
    final feeds24h = countResults[1].docs.length;
    final sleep3dSnap = countResults[2];
    final feed3dSnap = countResults[3];

    return {
      'lastSleep': lastSleep,
      'sleeps24h': sleeps24h,
      'feeds24h': feeds24h,
      'sleepsAvg3d': sleep3dSnap.docs.length / 3.0,
      'feedsAvg3d': feed3dSnap.docs.length / 3.0,
      'lastFeed': lastFeed,
      'lastDiaper': lastDiaper,
      'ongoing': ongoing,
      'pees24h': pees24h,
      'poops24h': poops24h,
      'peesAvg3d': pees3d / 3.0,
      'poopsAvg3d': poops3d / 3.0,
      'lastSide': lastSide,
    };
  }

  // ===== MIGRATION =====

  Future<int> migrateOldEvents() async {
    final cutoff = DateTime(2026, 3, 22);
    final oldSnap = await _ref.orderBy('timestamp', descending: false).get();
    int migrated = 0;

    final oldEvents = <Map<String, dynamic>>[];
    for (final doc in oldSnap.docs) {
      final data = doc.data() as Map<String, dynamic>;
      // Skip already migrated events (they have 'startTime' instead of 'timestamp')
      if (data.containsKey('startTime')) continue;
      if (!data.containsKey('timestamp')) continue;
      final ts = (data['timestamp'] as Timestamp).toDate();
      if (ts.isBefore(cutoff)) {
        await doc.reference.delete(); // delete old data before cutoff
        continue;
      }
      oldEvents.add({...data, '_id': doc.id, '_ts': ts});
    }

    // Sort by timestamp
    oldEvents.sort((a, b) => (a['_ts'] as DateTime).compareTo(b['_ts'] as DateTime));

    // Pair start/end events
    final processed = <String>{};

    for (int i = 0; i < oldEvents.length; i++) {
      final e = oldEvents[i];
      if (processed.contains(e['_id'])) continue;
      final type = e['type'] as String;
      final ts = e['_ts'] as DateTime;

      if (type == 'sleep_start') {
        // Find matching sleep_end
        DateTime? endTime;
        int? dur;
        for (int j = i + 1; j < oldEvents.length; j++) {
          if (oldEvents[j]['type'] == 'sleep_end') {
            endTime = oldEvents[j]['_ts'] as DateTime;
            dur = endTime.difference(ts).inMinutes;
            processed.add(oldEvents[j]['_id']);
            break;
          }
          if (oldEvents[j]['type'] == 'sleep_start') break; // another start before end
        }
        await _ref.add({
          'type': 'sleep',
          'startTime': Timestamp.fromDate(ts),
          if (endTime != null) 'endTime': Timestamp.fromDate(endTime),
          if (dur != null) 'duration': dur,
          'pee': false, 'poop': false,
          'createdBy': e['createdBy'] ?? 'migrated',
          'createdAt': Timestamp.fromDate(DateTime.now()),
        });
        processed.add(e['_id']);
        migrated++;
      } else if (type == 'feed_start') {
        DateTime? endTime;
        int? dur;
        for (int j = i + 1; j < oldEvents.length; j++) {
          if (oldEvents[j]['type'] == 'feed_end') {
            endTime = oldEvents[j]['_ts'] as DateTime;
            dur = endTime.difference(ts).inMinutes;
            processed.add(oldEvents[j]['_id']);
            break;
          }
          if (oldEvents[j]['type'] == 'feed_start') break;
        }
        await _ref.add({
          'type': 'feed',
          'startTime': Timestamp.fromDate(ts),
          if (endTime != null) 'endTime': Timestamp.fromDate(endTime),
          if (dur != null) 'duration': dur,
          if (e['side'] != null) 'side': e['side'],
          'pee': false, 'poop': false,
          'createdBy': e['createdBy'] ?? 'migrated',
          'createdAt': Timestamp.fromDate(DateTime.now()),
        });
        processed.add(e['_id']);
        migrated++;
      } else if (type == 'pee') {
        await _ref.add({
          'type': 'diaper',
          'startTime': Timestamp.fromDate(ts),
          'pee': true, 'poop': false,
          'createdBy': e['createdBy'] ?? 'migrated',
          'createdAt': Timestamp.fromDate(DateTime.now()),
        });
        processed.add(e['_id']);
        migrated++;
      } else if (type == 'poop') {
        await _ref.add({
          'type': 'diaper',
          'startTime': Timestamp.fromDate(ts),
          'pee': false, 'poop': true,
          'createdBy': e['createdBy'] ?? 'migrated',
          'createdAt': Timestamp.fromDate(DateTime.now()),
        });
        processed.add(e['_id']);
        migrated++;
      } else if (type == 'sleep_end' || type == 'feed_end') {
        // Orphaned end without start — skip
        processed.add(e['_id']);
      }
    }

    // Delete all old-format events
    for (final e in oldEvents) {
      await _ref.doc(e['_id'] as String).delete();
    }

    return migrated;
  }
}
