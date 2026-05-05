import 'dart:convert';
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
    // Use Firestore's local cache — don't await server confirmation
    // This allows offline writes that sync when back online
    final docRef = _ref.doc(); // generate ID locally
    final data = event.toFirestore();
    docRef.set(data); // fire-and-forget — Firestore queues it for sync
    // Return the event with the local ID immediately
    return BabyEvent(
      id: docRef.id,
      type: event.type,
      startTime: event.startTime,
      endTime: event.endTime,
      durationMinutes: event.durationMinutes,
      side: event.side,
      pee: event.pee,
      poop: event.poop,
      createdBy: event.createdBy,
      ml: event.ml,
      storage: event.storage,
      expiresAt: event.expiresAt,
      spoiled: event.spoiled,
      pumpId: event.pumpId,
      source: event.source,
      linkedPumpId: event.linkedPumpId,
      linkedPumps: event.linkedPumps,
      mlFed: event.mlFed,
    );
  }

  Future<void> updateEvent(BabyEvent event) async {
    // Fire-and-forget for offline support
    _ref.doc(event.id).set(event.toFirestore());
  }

  /// Resume a previously ended event — clears endTime and duration.
  Future<void> resumeEvent(String eventId) async {
    await _ref.doc(eventId).update({
      'endTime': FieldValue.delete(),
      'duration': FieldValue.delete(),
    });
  }

  Future<void> deleteEvent(String eventId) async {
    _ref.doc(eventId).delete();
  }

  Future<void> completeOngoing(String eventId,
      {int? durationMinutes, String? side}) async {
    final now = DateTime.now();
    // Read from cache if offline
    final doc = await _ref.doc(eventId).get(const GetOptions(source: Source.cache)).catchError((_) => _ref.doc(eventId).get());
    if (!doc.exists) return;
    final event = BabyEvent.fromFirestore(doc);
    final dur = durationMinutes ?? now.difference(event.startTime).inMinutes;
    final update = <String, dynamic>{
      'endTime': Timestamp.fromDate(now),
      'duration': dur,
    };
    if (side != null) update['side'] = side;
    _ref.doc(eventId).update(update); // fire-and-forget
  }

  Future<void> markSpoiled(String eventId) async {
    _ref.doc(eventId).update({'spoiled': true});
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
              catch (e) { return null; }
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

  // Helper: try cache first, fall back to server. Prevents offline hangs.
  Future<QuerySnapshot> _getWithCache(Query query) async {
    try {
      final cached = await query.get(const GetOptions(source: Source.cache));
      if (cached.docs.isNotEmpty) {
        // Also trigger a background server fetch to refresh cache
        query.get(const GetOptions(source: Source.server)).catchError((_) => cached);
        return cached;
      }
    } catch (_) {}
    // Cache empty or failed — try server (will hang offline but no choice)
    return query.get();
  }

  Future<DocumentSnapshot> _getDocWithCache(DocumentReference ref) async {
    try {
      return await ref.get(const GetOptions(source: Source.cache));
    } catch (_) {}
    return ref.get();
  }

  Future<BabyEvent?> getLastOfType(EventType type) async {
    final snap = await _getWithCache(_ref.where('type', isEqualTo: type.name)
        .orderBy('startTime', descending: true).limit(1));
    if (snap.docs.isEmpty) return null;
    try { return BabyEvent.fromFirestore(snap.docs.first); }
    catch (_) { return null; }
  }

  Future<List<BabyEvent>> getRecentFeeds(int limit) async {
    final snap = await _getWithCache(_ref.where('type', isEqualTo: 'feed')
        .orderBy('startTime', descending: true).limit(limit));
    return snap.docs
        .map((d) { try { return BabyEvent.fromFirestore(d); } catch (_) { return null; } })
        .whereType<BabyEvent>().toList();
  }

  Future<List<BabyEvent>> getRecentEvents({int days = 10}) async {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final types = ['feed', 'diaper', 'pump', 'sleep'];
    final results = await Future.wait(types.map((t) =>
      _getWithCache(_ref.where('type', isEqualTo: t)
        .where('startTime', isGreaterThan: Timestamp.fromDate(cutoff))
        .orderBy('startTime', descending: true))));
    final all = results.expand((s) => s.docs
      .map((d) { try { return BabyEvent.fromFirestore(d); } catch (_) { return null; } })
      .whereType<BabyEvent>()).toList();
    all.sort((a, b) => a.startTime.compareTo(b.startTime));
    return all;
  }

  Future<void> updateDeviceName(String deviceId, String name) async {
    try {
      await _db.collection('families').doc(familyId)
          .collection('devices').doc(deviceId)
          .set({'name': name, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<Map<String, String>> getDeviceNames() async {
    try {
      final snap = await _db.collection('families').doc(familyId).collection('devices').get();
      final map = <String, String>{};
      for (final doc in snap.docs) {
        final name = doc.data()['name'] as String?;
        if (name != null && name.isNotEmpty) map[doc.id] = name;
      }
      return map;
    } catch (_) { return {}; }
  }

  /// Real-time stream of {deviceId → name} for all family devices.
  Stream<Map<String, String>> deviceNamesStream() {
    return _db.collection('families').doc(familyId).collection('devices')
        .snapshots()
        .map((snap) {
      final map = <String, String>{};
      for (final doc in snap.docs) {
        final name = doc.data()['name'] as String?;
        if (name != null && name.isNotEmpty) map[doc.id] = name;
      }
      return map;
    });
  }

  Future<DateTime?> getBirthDate() async {
    try {
      final doc = await _db.collection('families').doc(familyId)
          .collection('settings').doc('config').get();
      final val = doc.data()?['birthDate'] as String?;
      if (val == null) return null;
      return DateTime.tryParse(val);
    } catch (_) { return null; }
  }

  Future<BabyEvent?> getOngoing() async {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(hours: 12));
    final results = await Future.wait([
      _getWithCache(_ref.where('type', isEqualTo: 'sleep').orderBy('startTime', descending: true).limit(1)),
      _getWithCache(_ref.where('type', isEqualTo: 'feed').orderBy('startTime', descending: true).limit(1)),
    ]);
    for (final snap in results) {
      if (snap.docs.isNotEmpty) {
        final e = BabyEvent.fromFirestore(snap.docs.first);
        if (!e.isOngoing) continue;
        // Skip pump-source feeds (they have duration 0 but just in case)
        if (e.source == 'pump') continue;
        // Skip stale events older than 12h — likely a missed end
        if (e.startTime.isBefore(cutoff)) continue;
        return e;
      }
    }
    return null;
  }

  // ===== PUMP STOCK =====

  /// [excludeEventId] — feed event to exclude from 'used' calc so its linked pumps show up
  Future<List<Map<String, dynamic>>> getAvailableStock({String? excludeEventId}) async {
    final now = DateTime.now();
    final results = await Future.wait([
      _getWithCache(_ref.where('type', isEqualTo: 'pump').orderBy('startTime', descending: true)),
      _getWithCache(_ref.where('type', isEqualTo: 'feed').orderBy('startTime', descending: true)),
    ]);
    final pumps = results[0].docs
        .map((d) { try { return BabyEvent.fromFirestore(d); } catch (_) { return null; } })
        .whereType<BabyEvent>().toList();
    final feeds = results[1].docs
        .map((d) { try { return BabyEvent.fromFirestore(d); } catch (_) { return null; } })
        .whereType<BabyEvent>()
        .where((e) => e.source == 'pump').toList();

    final usedMl = <String, int>{};
    for (final f in feeds) {
      if (f.id == excludeEventId) continue; // exclude this feed from used calc
      // New multi-pump format
      if (f.linkedPumps != null) {
        try {
          final list = List<Map<String, dynamic>>.from(jsonDecode(f.linkedPumps!));
          for (final entry in list) {
            final pid = entry['id'] as String;
            final pml = (entry['ml'] as num).toInt();
            usedMl[pid] = (usedMl[pid] ?? 0) + pml;
          }
        } catch (_) {}
      }
      // Legacy single pump link
      else if (f.linkedPumpId != null) {
        usedMl[f.linkedPumpId!] = (usedMl[f.linkedPumpId!] ?? 0) + (f.mlFed ?? 0);
      }
    }

    final stock = <Map<String, dynamic>>[];
    for (final p in pumps) {
      if (p.spoiled || p.ml == null) continue;
      final remaining = p.ml! - (usedMl[p.id] ?? 0);
      if (remaining <= 0) continue;
      if (p.expiresAt != null && p.expiresAt!.isBefore(now)) continue;
      stock.add({'event': p, 'remaining': remaining, 'used': usedMl[p.id] ?? 0});
    }
    return stock;
  }

  /// Stock for editing a specific feed — includes pumps already linked to that feed
  Future<List<Map<String, dynamic>>> getStockForFeedEdit(String feedEventId, List<String> linkedPumpIds) async {
    final available = await getAvailableStock(excludeEventId: feedEventId);
    final availableIds = available.map((s) => (s['event'] as BabyEvent).id).toSet();
    // Fetch any linked pumps not in available stock (fully used by other feeds)
    for (final pid in linkedPumpIds) {
      if (availableIds.contains(pid)) continue;
      try {
        final doc = await _getDocWithCache(_ref.doc(pid));
        if (!doc.exists) continue;
        final p = BabyEvent.fromFirestore(doc);
        if (p.spoiled || p.ml == null) continue;
        available.add({'event': p, 'remaining': p.ml!, 'used': 0});
      } catch (_) {}
    }
    return available;
  }

  Future<Map<String, List<Map<String, dynamic>>>> getStockByStorage() async {
    final stock = await getAvailableStock();
    final grouped = <String, List<Map<String, dynamic>>>{'room': [], 'fridge': [], 'freezer': []};
    for (final s in stock) {
      final p = s['event'] as BabyEvent;
      grouped[p.storage ?? 'room']?.add(s);
    }
    return grouped;
  }

  Future<List<Map<String, dynamic>>> getExpirationWarnings() async {
    final stock = await getAvailableStock();
    final now = DateTime.now();
    final warnings = <Map<String, dynamic>>[];
    for (final s in stock) {
      final p = s['event'] as BabyEvent;
      if (p.expiresAt == null) continue;
      final diff = p.expiresAt!.difference(now);
      if (diff.inHours <= 24) {
        final urgency = diff.inHours <= 1 ? 'critical' : diff.inHours <= 4 ? 'warning' : 'info';
        warnings.add({...s, 'urgency': urgency, 'timeLeft': diff});
      }
    }
    return warnings;
  }

  // ===== SIDE RECOMMENDATION =====

  /// Smart side recommendation based on lactation consultant guidelines:
  /// - Alternate starting side for even stimulation
  /// - Short feed (< 10 min): offer same side (baby didn't reach hindmilk)
  /// - Very short feed (< 5 min): definitely same side
  /// - Long gap (> 2h): alternate regardless (breasts refilled)
  /// - Skip pump-source feeds when determining last breast side
  /// - Consider recent pumps: if one side was pumped, the other is fuller
  Future<Map<String, String?>> getSideRecommendation() async {
    final now = DateTime.now();

    // Get recent breast feeds (skip pump-source feeds) and recent pumps
    final allRecent = await getRecentFeeds(20);
    final breastFeeds = allRecent.where((f) => f.source != 'pump' && f.side != null).toList();

    // Also get recent pumps to check if one side was pumped
    final pumpSnap = await _getWithCache(_ref
        .where('type', isEqualTo: 'pump')
        .orderBy('startTime', descending: true)
        .limit(5));
    final recentPumps = pumpSnap.docs
        .map((d) { try { return BabyEvent.fromFirestore(d); } catch (_) { return null; } })
        .whereType<BabyEvent>()
        .where((p) => p.side != null && p.side != 'both')
        .toList();

    if (breastFeeds.isEmpty && recentPumps.isEmpty) {
      return {'recommendedSide': null, 'recommendationReason': null, 'lastSide': null};
    }

    // Find last breast-fed side
    final lastBreastFeed = breastFeeds.isNotEmpty ? breastFeeds.first : null;
    final lastSide = lastBreastFeed?.side;

    if (lastSide == null) {
      // No breast feed with side found — check if a pump suggests a side
      if (recentPumps.isNotEmpty) {
        final pumpedSide = recentPumps.first.side!;
        final otherSide = pumpedSide == 'left' ? 'right' : 'left';
        return {
          'recommendedSide': otherSide,
          'recommendationReason': 'Recently pumped $pumpedSide — other side is fuller',
          'lastSide': null,
        };
      }
      return {'recommendedSide': null, 'recommendationReason': null, 'lastSide': null};
    }

    final otherSide = lastSide == 'left' ? 'right' : 'left';
    final lastFeedEnd = lastBreastFeed!.endTime ?? lastBreastFeed.startTime;
    final timeSince = now.difference(lastFeedEnd);
    final duration = lastBreastFeed.durationMinutes;

    // Rule 1: Long gap (> 2 hours) → alternate regardless
    // Breasts have had time to refill evenly
    if (timeSince.inMinutes > 120) {
      // But check if one side was pumped in between
      final pumpsSinceLastFeed = recentPumps
          .where((p) => p.startTime.isAfter(lastFeedEnd) && p.side != 'both')
          .toList();
      if (pumpsSinceLastFeed.isNotEmpty) {
        final pumpedSide = pumpsSinceLastFeed.first.side!;
        final fullerSide = pumpedSide == 'left' ? 'right' : 'left';
        return {
          'recommendedSide': fullerSide,
          'recommendationReason': '$pumpedSide was pumped since last feed — $fullerSide is fuller',
          'lastSide': lastSide,
        };
      }
      return {
        'recommendedSide': otherSide,
        'recommendationReason': '${timeSince.inHours}h+ gap — alternate to $otherSide',
        'lastSide': lastSide,
      };
    }

    // Rule 2: Very short feed (< 5 min) → definitely same side
    if (duration != null && duration < 5) {
      return {
        'recommendedSide': lastSide,
        'recommendationReason': 'Last feed very short (${duration}m) — offer $lastSide again for hindmilk',
        'lastSide': lastSide,
      };
    }

    // Rule 3: Short feed (< 10 min) → same side
    if (duration != null && duration < 10) {
      return {
        'recommendedSide': lastSide,
        'recommendationReason': 'Last feed short (${duration}m) — offer $lastSide again',
        'lastSide': lastSide,
      };
    }

    // Rule 4: Check if one side was pumped since last feed
    final pumpsSince = recentPumps
        .where((p) => p.startTime.isAfter(lastFeedEnd) && p.side != 'both')
        .toList();
    if (pumpsSince.isNotEmpty) {
      final pumpedSide = pumpsSince.first.side!;
      final fullerSide = pumpedSide == 'left' ? 'right' : 'left';
      return {
        'recommendedSide': fullerSide,
        'recommendationReason': '$pumpedSide was pumped — $fullerSide is fuller',
        'lastSide': lastSide,
      };
    }

    // Rule 5: Normal feed (≥ 10 min) → alternate
    return {
      'recommendedSide': otherSide,
      'recommendationReason': 'Alternating — last was $lastSide${duration != null ? " (${duration}m)" : ""}',
      'lastSide': lastSide,
    };
  }

  // ===== FEED INSIGHTS =====

  Future<Map<String, dynamic>> getFeedInsights() async {
    final feeds = await getRecentFeeds(200);
    final now = DateTime.now();

    Duration? timeSinceLast;
    if (feeds.isNotEmpty) {
      final lastEnd = feeds.first.endTime ?? feeds.first.startTime;
      timeSinceLast = now.difference(lastEnd);
    }

    final sideRec = await getSideRecommendation();

    // Combined ml+duration: 90ml ≈ 20min (one big feed)
    double feedMinEquiv(BabyEvent f) {
      // Pump-source feeds: always convert ml → equiv minutes; ignore duration (always 0)
      if (f.source == 'pump') {
        int ml = f.mlFed ?? 0;
        if (ml == 0 && f.linkedPumps != null) {
          try {
            final list = List<Map<String, dynamic>>.from(jsonDecode(f.linkedPumps!));
            ml = list.fold<int>(0, (s, x) => s + (x['ml'] as num).toInt());
          } catch (_) {}
        }
        return ml > 0 ? ml * 20.0 / 90.0 : 0;
      }
      if (f.durationMinutes != null) return f.durationMinutes!.toDouble();
      return 0;
    }

    // Last 24h
    final last24h = now.subtract(const Duration(hours: 24));
    final feeds24h = feeds.where((f) => f.startTime.isAfter(last24h)).toList();
    final equiv24h = feeds24h.fold<double>(0, (s, f) => s + feedMinEquiv(f));
    final dur24h = feeds24h.fold<int>(0, (s, f) => s + (f.durationMinutes ?? 0));
    int ml24h = 0;
    for (final f in feeds24h) {
      int ml = f.mlFed ?? 0;
      if (ml == 0 && f.linkedPumps != null) {
        try {
          final list = List<Map<String, dynamic>>.from(jsonDecode(f.linkedPumps!));
          ml = list.fold<int>(0, (s, x) => s + (x['ml'] as num).toInt());
        } catch (_) {}
      }
      ml24h += ml;
    }

    // 5-day avg
    final fiveDaysAgo = now.subtract(const Duration(days: 5));
    final feeds5d = feeds.where((f) => f.startTime.isAfter(fiveDaysAgo)).toList();
    final avg5dEquiv = feeds5d.isEmpty ? 0.0 : feeds5d.fold<double>(0, (s, f) => s + feedMinEquiv(f)) / 5.0;

    // Avg feed duration (breast only, last 5 days)
    final breastFeeds5d = feeds5d.where((f) => f.source != 'pump' && f.durationMinutes != null && f.durationMinutes! > 0).toList();
    final avgDuration = breastFeeds5d.isEmpty ? 0.0 : breastFeeds5d.fold<int>(0, (s, f) => s + f.durationMinutes!) / breastFeeds5d.length;

    // Group individual feeds into "feeding sessions":
    // consecutive feeds within 45 min of each other = one session.
    // Gap = time from end of one session to start of the next.
    // Only count gaps where the session START falls in the target window.
    List<Map<String, DateTime>> _buildSessions(List<BabyEvent> sorted) {
      if (sorted.isEmpty) return [];
      final sessions = <Map<String, DateTime>>[];
      DateTime sessionStart = sorted.first.startTime;
      DateTime sessionEnd = sorted.first.endTime ?? sorted.first.startTime;
      for (int i = 1; i < sorted.length; i++) {
        final f = sorted[i];
        final gapToNext = f.startTime.difference(sessionEnd).inMinutes;
        if (gapToNext <= 30) {
          // Same session — extend end time
          final fEnd = f.endTime ?? f.startTime;
          if (fEnd.isAfter(sessionEnd)) sessionEnd = fEnd;
        } else {
          sessions.add({'start': sessionStart, 'end': sessionEnd});
          sessionStart = f.startTime;
          sessionEnd = f.endTime ?? f.startTime;
        }
      }
      sessions.add({'start': sessionStart, 'end': sessionEnd});
      return sessions;
    }

    double _avgSessionGapInWindow(List<Map<String, DateTime>> sessions, bool Function(int hour) inWindow) {
      if (sessions.length < 2) return 0;
      final gaps = <int>[];
      for (int i = 1; i < sessions.length; i++) {
        final prevEnd = sessions[i - 1]['end']!;
        final currStart = sessions[i]['start']!;
        final sessionStartHour = sessions[i - 1]['start']!.hour;
        if (!inWindow(sessionStartHour)) continue;
        final gap = currStart.difference(prevEnd).inMinutes;
        // Only meaningful inter-session gaps (5 min to 12h)
        if (gap >= 5 && gap < 720) gaps.add(gap);
      }
      if (gaps.isEmpty) return 0;
      return gaps.fold<int>(0, (s, v) => s + v) / gaps.length;
    }

    final allSorted5d = [...feeds5d]..sort((a, b) => a.startTime.compareTo(b.startTime));
    final sessions5d = _buildSessions(allSorted5d);
    final avgGapDay = _avgSessionGapInWindow(sessions5d, (h) => h >= 10 && h < 22);
    final avgGapNight = _avgSessionGapInWindow(sessions5d, (h) => h >= 22 || h < 10);

    // Prev 5d (10–5 days ago) for trend comparison
    final tenDaysAgo = now.subtract(const Duration(days: 10));
    final feedsPrev5d = feeds
        .where((f) => f.startTime.isAfter(tenDaysAgo) && !f.startTime.isAfter(fiveDaysAgo))
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final sessionsPrev5d = _buildSessions(feedsPrev5d);
    final avgGapDayPrev = _avgSessionGapInWindow(sessionsPrev5d, (h) => h >= 10 && h < 22);
    final avgGapNightPrev = _avgSessionGapInWindow(sessionsPrev5d, (h) => h >= 22 || h < 10);

    return {
      'timeSinceLast': timeSinceLast,
      ...sideRec,
      'equiv24h': equiv24h,
      'dur24h': dur24h,
      'ml24h': ml24h,
      'avg5dEquiv': avg5dEquiv,
      'avgDuration': avgDuration,
      'avgGapDay': avgGapDay,
      'avgGapNight': avgGapNight,
      'avgGapDayPrev': avgGapDayPrev,
      'avgGapNightPrev': avgGapNightPrev,
      // keep legacy keys for compatibility
      'todayEquiv': equiv24h,
      'todayDurOnly': dur24h,
      'todayMlOnly': ml24h,
      'avg3dEquiv': avg5dEquiv,
    };
  }

  DateTime _getPeriodStart(DateTime dt) {
    final h = dt.hour;
    if (h >= 0 && h < 6) return DateTime(dt.year, dt.month, dt.day, 0);
    if (h >= 6 && h < 12) return DateTime(dt.year, dt.month, dt.day, 6);
    if (h >= 12 && h < 18) return DateTime(dt.year, dt.month, dt.day, 12);
    return DateTime(dt.year, dt.month, dt.day, 18);
  }

  String _getPeriodName(DateTime dt) {
    final h = dt.hour;
    if (h >= 0 && h < 6) return 'Night';
    if (h >= 6 && h < 12) return 'Morning';
    if (h >= 12 && h < 18) return 'Afternoon';
    return 'Evening';
  }

  // ===== QUICK STATS (optimized — max parallel, fewer queries) =====

  Future<Map<String, dynamic>> getQuickStats() async {
    final now = DateTime.now();
    final dayAgo = now.subtract(const Duration(hours: 24));
    final threeDaysAgo = now.subtract(const Duration(days: 3));

    // All queries in parallel
    final results = await Future.wait([
      getLastOfType(EventType.sleep),                  // 0
      getLastOfType(EventType.feed),                   // 1
      getLastOfType(EventType.diaper),                 // 2
      getOngoing(),                                     // 3
      getLastOfType(EventType.pump),                   // 4
      _getWithCache(_ref.where('type', isEqualTo: 'diaper')  // 5
          .where('startTime', isGreaterThanOrEqualTo: Timestamp.fromDate(threeDaysAgo))
          .orderBy('startTime', descending: true)),
      _getWithCache(_ref.where('type', isEqualTo: 'pump')    // 6
          .where('startTime', isGreaterThanOrEqualTo: Timestamp.fromDate(dayAgo))
          .orderBy('startTime', descending: true)),
      getSideRecommendation(),                          // 7
    ]);

    final lastSleep = results[0] as BabyEvent?;
    final lastFeed = results[1] as BabyEvent?;
    final lastDiaper = results[2] as BabyEvent?;
    final ongoing = results[3] as BabyEvent?;
    final lastPump = results[4] as BabyEvent?;
    final diaper3dSnap = results[5] as QuerySnapshot;
    final pump24hSnap = results[6] as QuerySnapshot;
    final sideRec = results[7] as Map<String, String?>;

    // Diapers: 3d superset, filter for 24h
    final diapers3d = diaper3dSnap.docs
        .map((d) { try { return BabyEvent.fromFirestore(d); } catch (_) { return null; } })
        .whereType<BabyEvent>().toList();
    final diapers24h = diapers3d.where((e) => e.startTime.isAfter(dayAgo)).toList();
    final pees24h = diapers24h.where((e) => e.pee).length;
    final poops24h = diapers24h.where((e) => e.poop).length;
    final pees3d = diapers3d.where((e) => e.pee).length;
    final poops3d = diapers3d.where((e) => e.poop).length;

    // Pump 24h
    final pumps24h = pump24hSnap.docs
        .map((d) { try { return BabyEvent.fromFirestore(d); } catch (_) { return null; } })
        .whereType<BabyEvent>().toList();

    return {
      'lastSleep': lastSleep,
      'lastFeed': lastFeed,
      'lastDiaper': lastDiaper,
      'ongoing': ongoing,
      'pees24h': pees24h,
      'poops24h': poops24h,
      'peesAvg3d': pees3d / 3.0,
      'poopsAvg3d': poops3d / 3.0,
      'lastSide': sideRec['lastSide'],
      'recommendedSide': sideRec['recommendedSide'],
      'recommendationReason': sideRec['recommendationReason'],
      'lastPump': lastPump,
      'pumpCount24h': pumps24h.length,
      'pumpMl24h': pumps24h.fold<int>(0, (s, e) => s + (e.ml ?? 0)),
    };
  }

  // ===== REAL-TIME STATS (derived locally from stream — no extra queries) =====

  /// Compute everything HomeScreen needs from an already-loaded event list.
  /// Called on every stream emission — pure Dart, instant.
  Map<String, dynamic> computeStatsFromEvents(List<BabyEvent> events) {
    final now = DateTime.now();
    final cutoff12h = now.subtract(const Duration(hours: 12));
    final dayAgo = now.subtract(const Duration(hours: 24));
    final threeDaysAgo = now.subtract(const Duration(days: 3));

    // ---- last of each type + last 3 feeds ----
    BabyEvent? lastSleep, lastFeed, lastDiaper, lastPump;
    final recentFeeds = <BabyEvent>[];
    for (final e in events) {
      if (lastSleep == null && e.type == EventType.sleep) lastSleep = e;
      if (e.type == EventType.feed && recentFeeds.length < 3) recentFeeds.add(e);
      if (lastFeed == null && e.type == EventType.feed) lastFeed = e;
      if (lastDiaper == null && e.type == EventType.diaper) lastDiaper = e;
      if (lastPump == null && e.type == EventType.pump) lastPump = e;
      if (lastSleep != null && recentFeeds.length >= 3 && lastDiaper != null && lastPump != null) break;
    }

    // ---- ongoing (sleep or breast feed, < 12h old) ----
    BabyEvent? ongoing;
    for (final e in events) {
      if (e.type != EventType.sleep && e.type != EventType.feed) continue;
      if (e.source == 'pump') continue;
      if (!e.isOngoing) continue;
      if (e.startTime.isBefore(cutoff12h)) continue;
      ongoing = e;
      break;
    }

    // ---- diapers ----
    final diapers3d = events.where((e) => e.type == EventType.diaper && e.startTime.isAfter(threeDaysAgo)).toList();
    final diapers24h = diapers3d.where((e) => e.startTime.isAfter(dayAgo)).toList();
    final pees24h = diapers24h.where((e) => e.pee).length;
    final poops24h = diapers24h.where((e) => e.poop).length;
    final pees3d = diapers3d.where((e) => e.pee).length;
    final poops3d = diapers3d.where((e) => e.poop).length;

    // ---- pump 24h ----
    final pumps24h = events.where((e) => e.type == EventType.pump && e.startTime.isAfter(dayAgo)).toList();

    // ---- side recommendation (local, same rules as before) ----
    final breastFeeds = events
        .where((e) => e.type == EventType.feed && e.source != 'pump' && e.side != null)
        .take(20)
        .toList();
    final recentPumps = events
        .where((e) => e.type == EventType.pump && e.side != null && e.side != 'both')
        .take(5)
        .toList();

    String? recommendedSide, recommendationReason, lastSide;

    if (breastFeeds.isEmpty && recentPumps.isNotEmpty) {
      final pumpedSide = recentPumps.first.side!;
      final otherSide = pumpedSide == 'left' ? 'right' : 'left';
      recommendedSide = otherSide;
      recommendationReason = 'Recently pumped $pumpedSide — other side is fuller';
    } else if (breastFeeds.isNotEmpty) {
      final lastBreast = breastFeeds.first;
      lastSide = lastBreast.side;
      final otherSide = lastSide == 'left' ? 'right' : 'left';
      final lastFeedEnd = lastBreast.endTime ?? lastBreast.startTime;
      final timeSince = now.difference(lastFeedEnd);
      final duration = lastBreast.durationMinutes;

      if (timeSince.inMinutes > 120) {
        final pumpsSince = recentPumps
            .where((p) => p.startTime.isAfter(lastFeedEnd) && p.side != 'both')
            .toList();
        if (pumpsSince.isNotEmpty) {
          final pumpedSide = pumpsSince.first.side!;
          final fullerSide = pumpedSide == 'left' ? 'right' : 'left';
          recommendedSide = fullerSide;
          recommendationReason = '$pumpedSide was pumped since last feed — $fullerSide is fuller';
        } else {
          recommendedSide = otherSide;
          recommendationReason = '${timeSince.inHours}h+ gap — alternate to $otherSide';
        }
      } else if (duration != null && duration < 5) {
        recommendedSide = lastSide;
        recommendationReason = 'Last feed very short (${duration}m) — offer $lastSide again for hindmilk';
      } else if (duration != null && duration < 10) {
        recommendedSide = lastSide;
        recommendationReason = 'Last feed short (${duration}m) — offer $lastSide again';
      } else {
        final pumpsSince = recentPumps
            .where((p) => p.startTime.isAfter(lastFeedEnd) && p.side != 'both')
            .toList();
        if (pumpsSince.isNotEmpty) {
          final pumpedSide = pumpsSince.first.side!;
          final fullerSide = pumpedSide == 'left' ? 'right' : 'left';
          recommendedSide = fullerSide;
          recommendationReason = '$pumpedSide was pumped — $fullerSide is fuller';
        } else {
          recommendedSide = otherSide;
          recommendationReason = 'Alternating — last was $lastSide${duration != null ? " (${duration}m)" : ""}';
        }
      }
    }

    // ---- pump stock (local) ----
    final feeds = events.where((e) => e.type == EventType.feed && e.source == 'pump').toList();
    final usedMl = <String, int>{};
    for (final f in feeds) {
      if (f.linkedPumps != null) {
        try {
          final list = List<Map<String, dynamic>>.from(jsonDecode(f.linkedPumps!));
          for (final entry in list) {
            final pid = entry['id'] as String;
            final pml = (entry['ml'] as num).toInt();
            usedMl[pid] = (usedMl[pid] ?? 0) + pml;
          }
        } catch (_) {}
      } else if (f.linkedPumpId != null) {
        usedMl[f.linkedPumpId!] = (usedMl[f.linkedPumpId!] ?? 0) + (f.mlFed ?? 0);
      }
    }

    // ---- pump stock: individual units per storage, each with expiry ----
    final stockUnits = <Map<String, dynamic>>[];
    final expirationWarnings = <Map<String, dynamic>>[];
    for (final p in events.where((e) => e.type == EventType.pump)) {
      if (p.spoiled || p.ml == null) continue;
      final remaining = p.ml! - (usedMl[p.id] ?? 0);
      if (remaining <= 0) continue;
      if (p.expiresAt != null && p.expiresAt!.isBefore(now)) continue;
      final storage = p.storage ?? 'room';
      stockUnits.add({'event': p, 'remaining': remaining, 'storage': storage});
      if (p.expiresAt != null) {
        final diff = p.expiresAt!.difference(now);
        if (diff.inHours <= 24) {
          final urgency = diff.inHours <= 1 ? 'critical' : diff.inHours <= 4 ? 'warning' : 'info';
          expirationWarnings.add({'event': p, 'remaining': remaining, 'urgency': urgency, 'timeLeft': diff});
        }
      }
    }

    return {
      'lastSleep': lastSleep,
      'lastFeed': lastFeed,
      'lastDiaper': lastDiaper,
      'lastPump': lastPump,
      'ongoing': ongoing,
      'recentFeeds': recentFeeds,
      'pees24h': pees24h,
      'poops24h': poops24h,
      'peesAvg3d': pees3d / 3.0,
      'poopsAvg3d': poops3d / 3.0,
      'lastSide': lastSide,
      'recommendedSide': recommendedSide,
      'recommendationReason': recommendationReason,
      'pumpCount24h': pumps24h.length,
      'pumpMl24h': pumps24h.fold<int>(0, (s, e) => s + (e.ml ?? 0)),
      'stockUnits': stockUnits,
      'expirationWarnings': expirationWarnings,
    };
  }

  // ===== PUMP STATS =====

  Future<Map<String, dynamic>> getPumpStats() async {
    final now = DateTime.now();
    final threeDaysAgo = now.subtract(const Duration(days: 3));
    final fiveDaysAgo = now.subtract(const Duration(days: 5));

    final results = await Future.wait([
      _getWithCache(_ref.where('type', isEqualTo: 'pump').orderBy('startTime', descending: true)),
      _getWithCache(_ref.where('type', isEqualTo: 'feed').orderBy('startTime', descending: true)),
    ]);

    final allPumps = results[0].docs
        .map((d) { try { return BabyEvent.fromFirestore(d); } catch (_) { return null; } })
        .whereType<BabyEvent>().toList();
    final allFeeds = results[1].docs
        .map((d) { try { return BabyEvent.fromFirestore(d); } catch (_) { return null; } })
        .whereType<BabyEvent>()
        .where((e) => e.source == 'pump').toList();

    // Build usedMl map across all pump feeds
    final usedMl = <String, int>{};
    for (final f in allFeeds) {
      if (f.linkedPumps != null) {
        try {
          final list = List<Map<String, dynamic>>.from(jsonDecode(f.linkedPumps!));
          for (final entry in list) {
            final pid = entry['id'] as String;
            final pml = (entry['ml'] as num).toInt();
            usedMl[pid] = (usedMl[pid] ?? 0) + pml;
          }
        } catch (_) {}
      } else if (f.linkedPumpId != null) {
        usedMl[f.linkedPumpId!] = (usedMl[f.linkedPumpId!] ?? 0) + (f.mlFed ?? 0);
      }
    }

    // 5-day avg pumped and used per day
    final pumps5d = allPumps.where((p) => p.startTime.isAfter(fiveDaysAgo)).toList();
    final totalPumped5d = pumps5d.fold<int>(0, (s, p) => s + (p.ml ?? 0));
    final avgPumpedPerDay = totalPumped5d / 5.0;

    final feeds5d = allFeeds.where((f) => f.startTime.isAfter(fiveDaysAgo)).toList();
    int totalUsed5d = 0;
    for (final f in feeds5d) {
      int ml = f.mlFed ?? 0;
      if (ml == 0 && f.linkedPumps != null) {
        try {
          final list = List<Map<String, dynamic>>.from(jsonDecode(f.linkedPumps!));
          ml = list.fold<int>(0, (s, x) => s + (x['ml'] as num).toInt());
        } catch (_) {}
      }
      totalUsed5d += ml;
    }
    final avgUsedPerDay = totalUsed5d / 5.0;

    // "Recently Pumped" — list of pump events from last 3 days, with usage info
    final pumpById = <String, BabyEvent>{};
    for (final p in allPumps) { pumpById[p.id] = p; }

    // Build total usedMl across ALL feeds (not just 3-day) per pump id
    final totalUsedByPump = <String, int>{};
    for (final f in allFeeds) {
      if (f.linkedPumps != null) {
        try {
          final list = List<Map<String, dynamic>>.from(jsonDecode(f.linkedPumps!));
          for (final entry in list) {
            final pid = entry['id'] as String;
            final pml = (entry['ml'] as num).toInt();
            totalUsedByPump[pid] = (totalUsedByPump[pid] ?? 0) + pml;
          }
        } catch (_) {}
      } else if (f.linkedPumpId != null) {
        totalUsedByPump[f.linkedPumpId!] = (totalUsedByPump[f.linkedPumpId!] ?? 0) + (f.mlFed ?? 0);
      }
    }

    // Recent pumps (last 3 days), sorted newest first
    final recentPumps3d = allPumps.where((p) => p.startTime.isAfter(threeDaysAgo)).toList();
    recentPumps3d.sort((a, b) => b.startTime.compareTo(a.startTime));

    final recentUsage = recentPumps3d.map((p) {
      final totalUsed = totalUsedByPump[p.id] ?? 0;
      final remaining = (p.ml ?? 0) - totalUsed;
      return {
        'pumpEventId': p.id,
        'pumpId': p.pumpId,
        'pumpedAt': p.startTime,
        'pumpedMl': p.ml ?? 0,
        'totalUsed': totalUsed,
        'remaining': remaining < 0 ? 0 : remaining,
        'fullyUsed': remaining <= 0,
        'expiresAt': p.expiresAt,
        'storage': p.storage,
      };
    }).toList();

    return {
      'avgPumpedPerDay': avgPumpedPerDay,
      'avgUsedPerDay': avgUsedPerDay,
      'recentUsage': recentUsage,
    };
  }

  // ===== PUMP ID =====

  /// Returns next 3-digit pump ID starting at 100, incrementing by 1.
  /// Scans all existing pump pumpId fields to find the highest numeric one.
  Future<String> getNextPumpId() async {
    final snap = await _getWithCache(
        _ref.where('type', isEqualTo: 'pump').orderBy('startTime', descending: true));
    int max = 99;
    for (final doc in snap.docs) {
      try {
        final data = doc.data() as Map<String, dynamic>;
        final pid = data['pumpId'] as String?;
        if (pid == null) continue;
        // Extract leading numeric part e.g. "103" or "103 · 80ml · fridge"
        final match = RegExp(r'^(\d+)').firstMatch(pid);
        if (match != null) {
          final n = int.tryParse(match.group(1)!);
          if (n != null && n > max) max = n;
        }
      } catch (_) {}
    }
    return '${max + 1}';
  }

  // ===== MIGRATION =====

  Future<int> migrateOldEvents() async {
    final cutoff = DateTime(2026, 3, 22);
    final oldSnap = await _ref.orderBy('timestamp', descending: false).get();
    int migrated = 0;
    final oldEvents = <Map<String, dynamic>>[];
    for (final doc in oldSnap.docs) {
      final data = doc.data() as Map<String, dynamic>;
      if (data.containsKey('startTime')) continue;
      if (!data.containsKey('timestamp')) continue;
      final ts = (data['timestamp'] as Timestamp).toDate();
      if (ts.isBefore(cutoff)) { await doc.reference.delete(); continue; }
      oldEvents.add({...data, '_id': doc.id, '_ts': ts});
    }
    oldEvents.sort((a, b) => (a['_ts'] as DateTime).compareTo(b['_ts'] as DateTime));
    final processed = <String>{};
    for (int i = 0; i < oldEvents.length; i++) {
      final e = oldEvents[i];
      if (processed.contains(e['_id'])) continue;
      final type = e['type'] as String;
      final ts = e['_ts'] as DateTime;
      if (type == 'sleep_start') {
        DateTime? endTime; int? dur;
        for (int j = i + 1; j < oldEvents.length; j++) {
          if (oldEvents[j]['type'] == 'sleep_end') { endTime = oldEvents[j]['_ts'] as DateTime; dur = endTime.difference(ts).inMinutes; processed.add(oldEvents[j]['_id']); break; }
          if (oldEvents[j]['type'] == 'sleep_start') break;
        }
        await _ref.add({'type': 'sleep', 'startTime': Timestamp.fromDate(ts), if (endTime != null) 'endTime': Timestamp.fromDate(endTime), if (dur != null) 'duration': dur, 'pee': false, 'poop': false, 'createdBy': e['createdBy'] ?? 'migrated', 'createdAt': Timestamp.fromDate(DateTime.now())});
        processed.add(e['_id']); migrated++;
      } else if (type == 'feed_start') {
        DateTime? endTime; int? dur;
        for (int j = i + 1; j < oldEvents.length; j++) {
          if (oldEvents[j]['type'] == 'feed_end') { endTime = oldEvents[j]['_ts'] as DateTime; dur = endTime.difference(ts).inMinutes; processed.add(oldEvents[j]['_id']); break; }
          if (oldEvents[j]['type'] == 'feed_start') break;
        }
        await _ref.add({'type': 'feed', 'startTime': Timestamp.fromDate(ts), if (endTime != null) 'endTime': Timestamp.fromDate(endTime), if (dur != null) 'duration': dur, if (e['side'] != null) 'side': e['side'], 'pee': false, 'poop': false, 'createdBy': e['createdBy'] ?? 'migrated', 'createdAt': Timestamp.fromDate(DateTime.now())});
        processed.add(e['_id']); migrated++;
      } else if (type == 'pee') {
        await _ref.add({'type': 'diaper', 'startTime': Timestamp.fromDate(ts), 'pee': true, 'poop': false, 'createdBy': e['createdBy'] ?? 'migrated', 'createdAt': Timestamp.fromDate(DateTime.now())});
        processed.add(e['_id']); migrated++;
      } else if (type == 'poop') {
        await _ref.add({'type': 'diaper', 'startTime': Timestamp.fromDate(ts), 'pee': false, 'poop': true, 'createdBy': e['createdBy'] ?? 'migrated', 'createdAt': Timestamp.fromDate(DateTime.now())});
        processed.add(e['_id']); migrated++;
      } else if (type == 'sleep_end' || type == 'feed_end') { processed.add(e['_id']); }
    }
    for (final e in oldEvents) { await _ref.doc(e['_id'] as String).delete(); }
    return migrated;
  }
}
