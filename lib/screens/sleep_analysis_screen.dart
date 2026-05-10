import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';

// ── Colours ──────────────────────────────────────────────────────────
const _kIndigo = Color(0xFF6366f1);
const _kOrange = Color(0xFFf97316);
const _kGreen  = Color(0xFF22c55e);
const _kAmber  = Color(0xFFf59e0b);
const _kPurple = Color(0xFFa855f7);
const _kMuted  = Color(0xFF71717a);

// ── Data helpers ─────────────────────────────────────────────────────

int? _ageWeeks(DateTime? birthDate) {
  if (birthDate == null) return null;
  return DateTime.now().difference(birthDate).inDays ~/ 7;
}

String? _ageBracket(int? weeks) {
  if (weeks == null) return null;
  if (weeks < 6)  return '0-6w';
  if (weeks < 12) return '6-12w';
  if (weeks < 20) return '3-4m';
  if (weeks < 28) return '4-6m';
  return '6m+';
}

int _sleepGapMin(int? weeks) {
  if (weeks == null || weeks < 6) return 45;
  if (weeks < 12) return 60;
  return 90;
}

// Full inference window: 18:00–08:00 (catches early bedtimes)
({DateTime start, DateTime end}) _nightWindow(DateTime baseDate) {
  final s = DateTime(baseDate.year, baseDate.month, baseDate.day, 18);
  final e = DateTime(baseDate.year, baseDate.month, baseDate.day + 1, 8);
  return (start: s, end: e);
}

// Strict night window: 22:00–08:00 (for total sleep / waking counts only)
({DateTime start, DateTime end}) _strictNightWindow(DateTime baseDate) {
  final s = DateTime(baseDate.year, baseDate.month, baseDate.day, 22);
  final e = DateTime(baseDate.year, baseDate.month, baseDate.day + 1, 8);
  return (start: s, end: e);
}

List<({DateTime start, DateTime end, int minutes})> _inferNightSleep(
    List<BabyEvent> events, DateTime winStart, DateTime winEnd, int gapMin) {
  final nightEvs = events
      .where((e) => !e.startTime.isBefore(winStart) && !e.startTime.isAfter(winEnd))
      .toList()
    ..sort((a, b) => a.startTime.compareTo(b.startTime));

  final points = <DateTime>[
    winStart,
    ...nightEvs.map((e) => e.endTime ?? e.startTime),
    winEnd,
  ];

  final gaps = <({DateTime start, DateTime end, int minutes})>[];
  for (int i = 1; i < points.length; i++) {
    final mins = points[i].difference(points[i - 1]).inMinutes;
    if (mins >= gapMin && mins < 600) {
      gaps.add((start: points[i - 1], end: points[i], minutes: mins));
    }
  }
  return gaps;
}

String _fmtDate(DateTime d) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final day = d.day.toString().padLeft(2, "0");
  final month = d.month.toString().padLeft(2, "0");
  return days[d.weekday - 1] + ' ' + day + '/' + month;
}

String _fmtHm(int mins) {
  if (mins < 60) return '${mins}m';
  final h = mins ~/ 60;
  final m = mins % 60;
  return m > 0 ? '${h}h ${m}m' : '${h}h';
}

String _fmtTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}';

List<String> _ageTips(String bracket, int? weeks) {
  const tips = {
    '0-6w': [
      '😴 No sleep training at this age — just observe and respond.',
      '🌯 Swaddling reduces the startle reflex and helps longer stretches.',
      '🌙 Keep night interactions quiet and dim to build day/night awareness.',
      '🍼 Feed on demand — frequent feeding is normal and needed.',
      '✅ A 2–3h night stretch is great at this age.',
    ],
    '6-12w': [
      '🍼 Cluster feeding (2+ feeds in 2h) in the evening → longer first stretch.',
      '🌙 Aim for a consistent bedtime window of 8–10pm.',
      '✅ A 3–5h first stretch is excellent at this age.',
      '😴 Put baby down drowsy but still awake to build self-soothing.',
      '☀️ Prioritise daytime feeds to shift more calories to the day.',
    ],
    '3-4m': [
      '⚠️ The 3–4 month sleep regression is real — expect disruption.',
      '✅ Target first stretch: 5–6h. Total night sleep: 9–11h.',
      '📅 A consistent bedtime routine (bath, feed, dark room) starts to matter.',
      '😴 Drowsy-but-awake is key — avoid fully rocking to sleep.',
      '🍼 Cluster feeding in the evening still helps.',
    ],
    '4-6m': [
      '✅ 6–8h first stretches are achievable. Target total: 10–12h.',
      '📅 Consistent bedtime 7–8pm is now important.',
      '😴 Gentle sleep training (fading, pick-up/put-down) is appropriate.',
      '🌙 Night feeds may start spacing out naturally.',
      '💪 Daytime nap consolidation begins — 3 naps/day typical.',
    ],
    '6m+': [
      '✅ Most babies can sleep 8–10h. Formal sleep training is appropriate.',
      '📅 Aim for bedtime 7–8pm with a consistent routine.',
      '🍼 Night weaning can be considered if weight gain is on track.',
      '💪 2 naps/day is typical — morning and afternoon.',
      '😴 Self-soothing is the goal — minimise intervention for wakings.',
    ],
  };
  return tips[bracket] ?? tips['6-12w']!;
}

int _benchmarkMin(String? bracket) {
  switch (bracket) {
    case '0-6w':  return 180;
    case '6-12w': return 240;
    case '3-4m':  return 330;
    case '4-6m':  return 420;
    default:      return 480;
  }
}

// ── Screen ────────────────────────────────────────────────────────────

class SleepAnalysisScreen extends StatefulWidget {
  final FirestoreService service;
  const SleepAnalysisScreen({super.key, required this.service});
  @override
  State<SleepAnalysisScreen> createState() => _SleepAnalysisScreenState();
}

class _SleepAnalysisScreenState extends State<SleepAnalysisScreen> {
  bool _loading = true;
  DateTime? _birthDate;
  List<BabyEvent> _allEvents = [];
  int _selectedNightOffset = 1;
  late final PageController _nightPageController = PageController();
  // Per-graph period toggle (true = 7-day, false = 4-week)
  bool _nightStretchWk = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nightPageController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      widget.service.getBirthDate(),
      widget.service.getRecentEvents(days: 28),
    ]);
    if (mounted) {
      setState(() {
        _birthDate = results[0] as DateTime?;
        _allEvents = results[1] as List<BabyEvent>;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final weeks = _ageWeeks(_birthDate);
    final bracket = _ageBracket(weeks);
    final gapMin = _sleepGapMin(weeks);
    final now = DateTime.now();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E2130) : Colors.white;

    // All actionable events (feed, diaper, pump) for sleep inference
    final actionEvents = _allEvents.where((e) =>
        e.type == EventType.feed ||
        e.type == EventType.diaper ||
        e.type == EventType.pump).toList();
    final feedEvents = _allEvents.where((e) => e.type == EventType.feed).toList();

    // 7d avg daytime / night intake (breast + pump) + trend arrow + per-day chart data
    var total7dDay = 0, total7dNight = 0;
    var recent3Night = 0, prior4Night = 0;
    final days7DayNight = <({String label, int dayMin, int nightMin})>[];
    for (int di = 6; di >= 0; di--) {
      final day = DateTime(now.year, now.month, now.day - di);
      final wStart = DateTime(day.year, day.month, day.day, 6);
      final wEnd   = DateTime(day.year, day.month, day.day + 1, 6);
      final dayEnd = DateTime(day.year, day.month, day.day, 22);
      var dMin = 0, nMin = 0;
      for (final f in feedEvents) {
        if (f.startTime.isBefore(wStart) || !f.startTime.isBefore(wEnd)) continue;
        final dur = f.source == 'pump' ? (f.mlFed ?? 0) ~/ 3 : f.duration?.inMinutes ?? 0;
        if (f.startTime.isBefore(dayEnd)) { dMin += dur; } else { nMin += dur; }
      }
      total7dDay += dMin; total7dNight += nMin;
      if (di >= 4) { prior4Night += nMin; } else if (di < 3) { recent3Night += nMin; }
      final lbl = di == 0 ? 'Today'
          : '${day.day.toString().padLeft(2,"0")}/${day.month.toString().padLeft(2,"0")}';
      days7DayNight.add((label: lbl, dayMin: dMin, nightMin: nMin));
    }
    final avg7dDayFeedMin   = total7dDay   ~/ 7;
    final avg7dNightFeedMin = total7dNight ~/ 7;
    final trendArrow = prior4Night == 0 ? '→'
        : (recent3Night / 3 < prior4Night / 4 * 0.9 ? '↓'
        : recent3Night / 3 > prior4Night / 4 * 1.1 ? '↑'
        : '→');

    // 4w day/night intake (breast + pump) — weekly averages for toggle + chart
    var total4wDay = 0, total4wNight = 0;
    final weeks4DayNight = <({String label, int dayMin, int nightMin})>[];
    for (int wi = 4; wi >= 1; wi--) {
      var wkDay = 0, wkNight = 0, daysWithData = 0;
      for (int d = 7 * wi; d > 7 * (wi - 1); d--) {
        final day = DateTime(now.year, now.month, now.day - d);
        final wStart = DateTime(day.year, day.month, day.day, 6);
        final wEnd   = DateTime(day.year, day.month, day.day + 1, 6);
        final dayEnd = DateTime(day.year, day.month, day.day, 22);
        var dMin = 0, nMin = 0;
        for (final f in feedEvents) {
          if (f.startTime.isBefore(wStart) || !f.startTime.isBefore(wEnd)) continue;
          final dur = f.source == 'pump' ? (f.mlFed ?? 0) ~/ 3 : f.duration?.inMinutes ?? 0;
          if (f.startTime.isBefore(dayEnd)) { dMin += dur; } else { nMin += dur; }
        }
        if (dMin + nMin > 0) { wkDay += dMin; wkNight += nMin; daysWithData++; }
        total4wDay += dMin; total4wNight += nMin;
      }
      weeks4DayNight.add((
        label: '${wi}w',
        dayMin: daysWithData > 0 ? wkDay ~/ daysWithData : 0,
        nightMin: daysWithData > 0 ? wkNight ~/ daysWithData : 0,
      ));
    }
    final avg4wDayFeedMin   = total4wDay   ~/ 28;
    final avg4wNightFeedMin = total4wNight ~/ 28;
    final showDayMin   = _nightStretchWk ? avg7dDayFeedMin   : avg4wDayFeedMin;
    final showNightMin = _nightStretchWk ? avg7dNightFeedMin : avg4wNightFeedMin;
    final feedPeriodLabel = _nightStretchWk ? '7d avg' : '4w avg';

    // Determine last night
    // Adjust for early morning — if before 8am, yesterday hasn't ended yet
    final baseOffset = now.hour < 8 ? _selectedNightOffset + 1 : _selectedNightOffset;
    var lastNightBase = DateTime(now.year, now.month, now.day - baseOffset);
    final lastNight = _nightWindow(lastNightBase);
    // Use full window (18:00–08:00) for gap inference so early bedtimes are captured
    final lastNightGaps = _inferNightSleep(actionEvents, lastNight.start, lastNight.end, gapMin);
    final lastNightEvents = actionEvents
        .where((e) => !e.startTime.isBefore(lastNight.start) && !e.startTime.isAfter(lastNight.end))
        .toList()..sort((a, b) => a.startTime.compareTo(b.startTime));

    // 7-day trend
    final nightData = <({String label, int longest})>[];
    for (int di = 7; di >= 1; di--) {
      final base = DateTime(now.year, now.month, now.day - di);
      final win = _nightWindow(base);
      // Longest stretch: full window (catches early bedtimes)
      final gaps = _inferNightSleep(actionEvents, win.start, win.end, gapMin);
      final longest = gaps.isEmpty ? 0 : gaps.map((g) => g.minutes).reduce((a, b) => a > b ? a : b);
      nightData.add((
        label: '${base.day.toString().padLeft(2, "0")}/${base.month.toString().padLeft(2, "0")}',
        longest: longest,
      ));
    }
    final validLongest = nightData.where((d) => d.longest > 0).toList();
    final avgLongest = validLongest.isEmpty ? 0 :
        validLongest.fold(0, (s, d) => s + d.longest) ~/ validLongest.length;

    // Check if 4 weeks of data exists (any event older than 14 days)
    final has4wData = _allEvents.any((e) => now.difference(e.startTime).inDays >= 14);

    // 4-week: nightly longest stretch (weekly averages)
    final nightData4w = <({String label, int longest})>[];
    if (!_nightStretchWk && has4wData) {
      for (int wi = 4; wi >= 1; wi--) {
        final weekVals = <int>[];
        for (int d = 7 * wi; d > 7 * (wi - 1); d--) {
          final base = DateTime(now.year, now.month, now.day - d);
          final win = _nightWindow(base);
          final gaps = _inferNightSleep(actionEvents, win.start, win.end, gapMin);
          if (gaps.isNotEmpty) weekVals.add(gaps.map((g) => g.minutes).reduce((a, b) => a > b ? a : b));
        }
        nightData4w.add((label: '${wi}w', longest: weekVals.isEmpty ? 0 : weekVals.fold(0, (s, v) => s + v) ~/ weekVals.length));
      }
    }

    // Evening feeding correlation — 14 days, dense = 2+ feeds between 6pm–10pm
    final eveningData = <({DateTime lastFeedTime, bool isDenseEvening, int firstStretch})>[];
    for (int di = 14; di >= 1; di--) {
      final base = DateTime(now.year, now.month, now.day - di);
      final win = _nightWindow(base);
      final eveningStart = DateTime(base.year, base.month, base.day, 18);
      final eveningEnd10 = DateTime(base.year, base.month, base.day, 22);
      final eveningFeeds = feedEvents
          .where((e) => !e.startTime.isBefore(eveningStart) &&
              e.startTime.isBefore(eveningEnd10))
          .toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
      if (eveningFeeds.isEmpty) continue;
      final lastFeed = eveningFeeds.last;
      final isDenseEvening = eveningFeeds.length >= 2;
      final searchFrom = lastFeed.endTime ?? lastFeed.startTime;
      final gaps = _inferNightSleep(actionEvents, searchFrom, win.end, gapMin);
      final firstStretch = gaps.isEmpty ? 0 : gaps.first.minutes;
      eveningData.add((lastFeedTime: lastFeed.startTime, isDenseEvening: isDenseEvening, firstStretch: firstStretch));
    }
    final denseNights  = eveningData.where((d) => d.isDenseEvening).toList();
    final sparseNights = eveningData.where((d) => !d.isDenseEvening).toList();
    final avgDense  = denseNights.isEmpty  ? 0 :
        denseNights.fold(0, (s, d) => s + d.firstStretch)  ~/ denseNights.length;
    final avgSparse = sparseNights.isEmpty ? 0 :
        sparseNights.fold(0, (s, d) => s + d.firstStretch) ~/ sparseNights.length;
    final avgLastFeedMs = eveningData.isEmpty ? 0 :
        eveningData.fold<int>(0, (s, d) => s + d.lastFeedTime.millisecondsSinceEpoch) ~/ eveningData.length;
    final avgLastFeed = avgLastFeedMs > 0 ? DateTime.fromMillisecondsSinceEpoch(avgLastFeedMs) : null;

    // Blurb for evening feeding section
    final String eveningBlurb;
    if (denseNights.length < 4 || sparseNights.length < 4) {
      eveningBlurb = 'Not enough data yet. Tracking nights with 2+ feeds between 6–10pm vs sparser evenings (${denseNights.length} dense, ${sparseNights.length} sparse so far).';
    } else if ((avgDense - avgSparse).abs() < 30) {
      eveningBlurb = 'No clear pattern yet — dense evenings: ${_fmtHm(avgDense)} first stretch vs ${_fmtHm(avgSparse)} on sparse nights.';
    } else if (avgDense > avgSparse) {
      eveningBlurb = '✅ 2+ feeds between 6–10pm adds ~${_fmtHm(avgDense - avgSparse)} to the first stretch (${_fmtHm(avgDense)} vs ${_fmtHm(avgSparse)}).';
    } else {
      eveningBlurb = 'More feeds 6–10pm didn\'t extend the first stretch on recent data (${_fmtHm(avgDense)} dense vs ${_fmtHm(avgSparse)} sparse).';
    }

    // Daytime feed density (08:00–20:00)
    final dayFeedData = <({String label, int count, int avgGap})>[];
    for (int di = 6; di >= 0; di--) {
      final base = DateTime(now.year, now.month, now.day - di);
      final dfStart = DateTime(base.year, base.month, base.day, 8);
      final dfEnd = DateTime(base.year, base.month, base.day, 20);
      final dayFeeds = feedEvents
          .where((e) => !e.startTime.isBefore(dfStart) && e.startTime.isBefore(dfEnd))
          .toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
      if (dayFeeds.isEmpty) {
        dayFeedData.add((label: '${base.day.toString().padLeft(2,"0")}/${base.month.toString().padLeft(2,"0")}', count: 0, avgGap: 0));
        continue;
      }
      final gaps2 = <int>[];
      for (int i = 1; i < dayFeeds.length; i++) {
        final g = dayFeeds[i].startTime.difference(dayFeeds[i - 1].startTime).inMinutes;
        if (g > 0 && g < 480) gaps2.add(g);
      }
      final avgGap2 = gaps2.isEmpty ? 0 : gaps2.fold(0, (s, v) => s + v) ~/ gaps2.length;
      dayFeedData.add((
        label: '${base.day.toString().padLeft(2,"0")}/${base.month.toString().padLeft(2,"0")}',
        count: dayFeeds.length, avgGap: avgGap2));
    }
    final validDayFeeds = dayFeedData.where((d) => d.count > 0).toList();
    final avgFeedCount = validDayFeeds.isEmpty ? 0.0 :
        validDayFeeds.fold(0, (s, d) => s + d.count) / validDayFeeds.length;

    // Night feed sessions
    final nightFeedTrend = <({String label, int count})>[];
    for (int di = 6; di >= 0; di--) {
      final base = DateTime(now.year, now.month, now.day - di - 1);
      final win = _nightWindow(base);
      final nfFeeds = feedEvents
          .where((e) => !e.startTime.isBefore(win.start) && !e.startTime.isAfter(win.end))
          .toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
      int sessions = 0;
      if (nfFeeds.isNotEmpty) {
        sessions = 1;
        for (int i = 1; i < nfFeeds.length; i++) {
          final prev = nfFeeds[i - 1].endTime ?? nfFeeds[i - 1].startTime;
          if (nfFeeds[i].startTime.difference(prev).inMinutes > 30) sessions++;
        }
      }
      nightFeedTrend.add((
        label: '${win.start.day.toString().padLeft(2,"0")}/${win.start.month.toString().padLeft(2,"0")}',
        count: sessions));
    }
    final recentNF = nightFeedTrend.skip(4).where((d) => d.count > 0).toList();
    final olderNF  = nightFeedTrend.take(4).where((d) => d.count > 0).toList();
    final recentAvgNF = recentNF.isEmpty ? 0.0 : recentNF.fold(0, (s, d) => s + d.count) / recentNF.length;
    final olderAvgNF  = olderNF.isEmpty  ? 0.0 : olderNF.fold(0,  (s, d) => s + d.count) / olderNF.length;
    final nfTrend = recentAvgNF < olderAvgNF - 0.2 ? 'down' :
                    recentAvgNF > olderAvgNF + 0.2 ? 'up' : 'flat';

    // Build recommendations
    final recs = <({String icon, Color color, String text})>[];
    final bm = _benchmarkMin(bracket);

    if (avgFeedCount > 0 && avgFeedCount < 4) {
      recs.add((icon: '🍼', color: _kOrange,
          text: '${avgFeedCount.toStringAsFixed(1)} avg daytime feeds — try to reach 4+ between 8am–8pm. More calories during the day means less hunger at night (Giordano).'));
    } else if (avgFeedCount >= 4) {
      recs.add((icon: '✅', color: _kGreen,
          text: '${avgFeedCount.toStringAsFixed(1)} avg daytime feeds — above the 4-feed target. Good foundation for longer night stretches.'));
    }
    if (nfTrend == 'down') {
      recs.add((icon: '🌙', color: _kGreen,
          text: 'Night feeds reducing — down to ~${recentAvgNF.toStringAsFixed(1)} sessions/night. Each reduction shows progress.'));
    } else if (nfTrend == 'up') {
      recs.add((icon: '⚠️', color: _kAmber,
          text: 'Night feeds increased recently. Check for a growth spurt, or consider whether daytime feeds can be increased.'));
    }
    if (denseNights.isNotEmpty && sparseNights.isNotEmpty && avgDense > avgSparse) {
      final diff = avgDense - avgSparse;
      recs.add((icon: '🍇', color: _kPurple,
          text: '2+ feeds between 6–10pm adds ~${_fmtHm(diff)} to the first stretch. Keep the evening feeds dense.'));
    } else if (denseNights.isEmpty && (weeks ?? 0) >= 6) {
      recs.add((icon: '🍇', color: _kPurple,
          text: 'Try 2+ feeds between 6–10pm to extend the first night stretch.'));
    }
    if (avgLongest > 0) {
      if (avgLongest < (bm * 0.7).round()) {
        recs.add((icon: '📊', color: _kIndigo,
            text: 'Longest stretch (avg ${_fmtHm(avgLongest)}) is below the ${_fmtHm(bm)} benchmark. Focus on daytime calories and a consistent bedtime.'));
      } else if (avgLongest >= bm) {
        recs.add((icon: '🏆', color: _kGreen,
            text: 'Longest stretch (${_fmtHm(avgLongest)}) meets or exceeds the ${_fmtHm(bm)} age benchmark!'));
      }
    }

    // ── Narrative log — interleaved timeline (fixes missed events) ────
    final List<Widget> narrativeWidgets = [];
    if (lastNightEvents.isNotEmpty || lastNightGaps.isNotEmpty) {
      // Group events into sessions (events within 30min of each other)
      final sortedEvs = [...lastNightEvents]..sort((a, b) => a.startTime.compareTo(b.startTime));
      final sessions = <List<BabyEvent>>[];
      for (final e in sortedEvs) {
        if (sessions.isEmpty || e.startTime.difference(sessions.last.last.startTime).inMinutes > 30) {
          sessions.add([e]);
        } else {
          sessions.last.add(e);
        }
      }
      // Build unified timeline entries (sleep gaps + wake sessions)
      final timeline = <({DateTime time, bool isSleep, String text})>[];
      for (final gap in lastNightGaps) {
        timeline.add((time: gap.start, isSleep: true, text: 'slept for ${_fmtHm(gap.minutes)}'));
      }
      for (final session in sessions) {
        final feeds = session.where((e) => e.type == EventType.feed).toList();
        final diapers = session.where((e) => e.type == EventType.diaper).toList();
        int breastMin = 0; int pumpMl = 0;
        for (final f in feeds) {
          if (f.source == 'pump') {
            int ml = f.mlFed ?? 0;
            if (ml == 0 && f.linkedPumps != null) {
              try { final list = List<Map<String, dynamic>>.from(jsonDecode(f.linkedPumps!)); ml = list.fold<int>(0, (s, x) => s + (x['ml'] as num).toInt()); } catch (_) {}
            }
            pumpMl += ml;
          } else {
            breastMin += f.durationMinutes ?? 0;
          }
        }
        final parts = <String>[];
        if (feeds.isNotEmpty) {
          final fParts = [if (breastMin > 0) _fmtHm(breastMin), if (pumpMl > 0) '${pumpMl}ml'];
          parts.add('🍼 ${fParts.isNotEmpty ? fParts.join('+') : '${feeds.length}×'}');
        }
        if (diapers.isNotEmpty) parts.add('🧷 ${diapers.length} diaper${diapers.length > 1 ? "s" : ""}');
        if (parts.isNotEmpty) {
          timeline.add((time: session.first.startTime, isSleep: false, text: parts.join('  ·  ')));
        }
      }
      // Sort chronologically; at same time, wake events before sleep entries
      timeline.sort((a, b) {
        final cmp = a.time.compareTo(b.time);
        if (cmp != 0) return cmp;
        if (!a.isSleep && b.isSleep) return -1;
        if (a.isSleep && !b.isSleep) return 1;
        return 0;
      });
      bool _nightDivAdded = false;
      for (final entry in timeline) {
        final h = entry.time.hour;
        final isEvening = h >= 18 && h < 22;
        if (!isEvening && !_nightDivAdded) {
          _nightDivAdded = true;
          if (narrativeWidgets.isNotEmpty) narrativeWidgets.add(const _PeriodDivider(label: '🌙 Night'));
        }
        narrativeWidgets.add(_NarrativeRow(time: _fmtTime(entry.time), text: entry.text, isSleep: entry.isSleep, isEvening: isEvening));
      }
    }

    // ── Reusable tab content builders ─────────────────────────────────
    Widget nightTab() => Column(children: [
      // Page indicator dots
      Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (i) => Container(
            width: _selectedNightOffset == i + 1 ? 16 : 6,
            height: 6,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              color: _selectedNightOffset == i + 1 ? _kIndigo : Colors.grey.shade700,
            ),
          )),
        ),
      ),
      Expanded(
        child: PageView.builder(
          controller: _nightPageController,
          itemCount: 3,
          onPageChanged: (i) { HapticFeedback.lightImpact(); setState(() => _selectedNightOffset = i + 1); },
          itemBuilder: (context, pageIndex) {
            final offset = pageIndex + 1;
            final baseOff = now.hour < 8 ? offset + 1 : offset;
            final pgBase = DateTime(now.year, now.month, now.day - baseOff);
            final pgNight = _nightWindow(pgBase);
            final pgStrict = _strictNightWindow(pgBase);
            final pgGaps = _inferNightSleep(actionEvents, pgNight.start, pgNight.end, gapMin);
            final pgStrictGaps = _inferNightSleep(actionEvents, pgStrict.start, pgStrict.end, gapMin);
            final pgEvents = actionEvents
                .where((e) => !e.startTime.isBefore(pgNight.start) && !e.startTime.isAfter(pgNight.end))
                .toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
            final pgLongest = pgGaps.isEmpty ? 0 : pgGaps.map((g) => g.minutes).reduce((a, b) => a > b ? a : b);
            final pgWakings = (pgStrictGaps.length - 1).clamp(0, 99);
            final pgEveStart = DateTime(pgBase.year, pgBase.month, pgBase.day, 18);
            final pgEveEnd = DateTime(pgBase.year, pgBase.month, pgBase.day, 22);
            final pgEveFeeds = feedEvents.where((e) => !e.startTime.isBefore(pgEveStart) && e.startTime.isBefore(pgEveEnd)).toList();
            int pgEveBreastMin = 0; int pgEveMl = 0;
            for (final f in pgEveFeeds) {
              if (f.source == 'pump') {
                int ml = f.mlFed ?? 0;
                if (ml == 0 && f.linkedPumps != null) {
                  try { final list = List<Map<String, dynamic>>.from(jsonDecode(f.linkedPumps!)); ml = list.fold<int>(0, (s, x) => s + (x['ml'] as num).toInt()); } catch (_) {}
                }
                pgEveMl += ml;
              } else {
                pgEveBreastMin += f.durationMinutes ?? 0;
              }
            }
            final pgEveParts = [if (pgEveBreastMin > 0) _fmtHm(pgEveBreastMin), if (pgEveMl > 0) '${pgEveMl}ml'];
            final pgEveValue = pgEveFeeds.isEmpty ? '--' : pgEveParts.isNotEmpty ? pgEveParts.join('+') : '${pgEveFeeds.length}×';
            final pgLabel = offset == 1 ? 'Last night' : '$offset nights ago';

            // Per-page night log
            final List<Widget> pgNarrativeWidgets = [];
            if (pgEvents.isNotEmpty || pgGaps.isNotEmpty) {
              final sortedEvs = [...pgEvents]..sort((a, b) => a.startTime.compareTo(b.startTime));
              final pgSessions = <List<BabyEvent>>[];
              for (final e in sortedEvs) {
                if (pgSessions.isEmpty || e.startTime.difference(pgSessions.last.last.startTime).inMinutes > 30) {
                  pgSessions.add([e]);
                } else {
                  pgSessions.last.add(e);
                }
              }
              final pgTimeline = <({DateTime time, bool isSleep, String text})>[];
              for (final gap in pgGaps) {
                pgTimeline.add((time: gap.start, isSleep: true, text: 'slept for ${_fmtHm(gap.minutes)}'));
              }
              for (final session in pgSessions) {
                final feeds = session.where((e) => e.type == EventType.feed).toList();
                final diapers = session.where((e) => e.type == EventType.diaper).toList();
                int breastMin = 0; int pumpMl = 0;
                for (final f in feeds) {
                  if (f.source == 'pump') {
                    int ml = f.mlFed ?? 0;
                    if (ml == 0 && f.linkedPumps != null) {
                      try { final list = List<Map<String, dynamic>>.from(jsonDecode(f.linkedPumps!)); ml = list.fold<int>(0, (s, x) => s + (x['ml'] as num).toInt()); } catch (_) {}
                    }
                    pumpMl += ml;
                  } else {
                    breastMin += f.durationMinutes ?? 0;
                  }
                }
                final parts = <String>[];
                if (feeds.isNotEmpty) {
                  final fParts = [if (breastMin > 0) _fmtHm(breastMin), if (pumpMl > 0) '${pumpMl}ml'];
                  parts.add('🍼 ${fParts.isNotEmpty ? fParts.join('+') : '${feeds.length}×'}');
                }
                if (diapers.isNotEmpty) parts.add('🧷 ${diapers.length} diaper${diapers.length > 1 ? "s" : ""}');
                if (parts.isNotEmpty) {
                  pgTimeline.add((time: session.first.startTime, isSleep: false, text: parts.join('  ·  ')));
                }
              }
              pgTimeline.sort((a, b) {
                final cmp = a.time.compareTo(b.time);
                if (cmp != 0) return cmp;
                if (!a.isSleep && b.isSleep) return -1;
                if (a.isSleep && !b.isSleep) return 1;
                return 0;
              });
              bool nightDividerAdded = false;
              for (final entry in pgTimeline) {
                final h = entry.time.hour;
                final isEvening = h >= 18 && h < 22;
                if (!isEvening && !nightDividerAdded) {
                  nightDividerAdded = true;
                  if (pgNarrativeWidgets.isNotEmpty) {
                    pgNarrativeWidgets.add(const _PeriodDivider(label: '🌙 Night'));
                  }
                }
                pgNarrativeWidgets.add(_NarrativeRow(
                    time: _fmtTime(entry.time), text: entry.text,
                    isSleep: entry.isSleep, isEvening: isEvening));
              }
            }

            return RefreshIndicator(
              onRefresh: _load,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('$pgLabel · ${_fmtDate(pgBase)}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  if (pgEvents.isEmpty && pgGaps.isEmpty)
                    Text('No data for this night.', style: TextStyle(fontSize: 13, color: Colors.grey.shade500))
                  else ...[
                    IntrinsicHeight(
                      child: Row(children: [
                        Expanded(child: _StatCard(cardBg: cardBg, emoji: '💤', value: pgLongest > 0 ? _fmtHm(pgLongest) : '--', label: 'Longest stretch', color: _kIndigo)),
                        const SizedBox(width: 8),
                        Expanded(child: _StatCard(cardBg: cardBg, emoji: '🌆', value: pgEveValue, label: 'Eve feeds', sub: '18–22h', color: _kOrange)),
                        const SizedBox(width: 8),
                        Expanded(child: _StatCard(cardBg: cardBg, emoji: '👶', value: '$pgWakings', label: 'Wakings', color: _kIndigo)),
                      ]),
                    ),
                    const SizedBox(height: 10),
                    _NightTimeline(
                      cardBg: cardBg,
                      nightStart: pgNight.start,
                      nightEnd: pgNight.end,
                      strictStart: pgStrict.start,
                      events: pgEvents,
                      gaps: pgGaps.map((g) => (start: g.start, end: g.end, minutes: g.minutes)).toList(),
                    ),
                    const SizedBox(height: 6),
                    _Blurb('Gaps >${gapMin}min inferred as sleep · swipe to compare nights'),
                    if (pgNarrativeWidgets.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _SectionLabel('📋 Night Log'),
                      _Card(cardBg: cardBg, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: pgNarrativeWidgets)),
                    ],
                  ],
                ]),
              ),
            );
          },
        ),
      ),
    ]);

    final dnChartData = _nightStretchWk ? days7DayNight : weeks4DayNight;

    Widget trendsTab() => RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(child: Text('📊 Longest Stretch',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                    color: Colors.grey.shade500, letterSpacing: 0.5))),
            if (has4wData) SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('7 days')),
                ButtonSegment(value: false, label: Text('4 weeks')),
              ],
              selected: {_nightStretchWk},
              onSelectionChanged: (s) => setState(() => _nightStretchWk = s.first),
              showSelectedIcon: false,
              style: ButtonStyle(
                padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 12, vertical: 0)),
                minimumSize: WidgetStateProperty.all(const Size(0, 28)),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
              ),
            ),
          ]),
        ),
        _Card(cardBg: cardBg, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _MiniBarChart(
            data: _nightStretchWk
                ? nightData.map((d) => (label: d.label, v1: d.longest)).toList()
                : nightData4w.map((d) => (label: d.label, v1: d.longest)).toList(),
            color1: _kIndigo,
            benchmark: _nightStretchWk ? bm : 0,
          ),
          const SizedBox(height: 10),
          Center(child: Column(children: [
            Text(avgLongest > 0 ? _fmtHm(avgLongest) : '--',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kIndigo)),
            Text('Avg longest stretch (7d)', style: TextStyle(fontSize: 11, color: Colors.grey.shade500), textAlign: TextAlign.center),
          ])),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(children: [
              Expanded(child: _StatCard(
                cardBg: cardBg, emoji: '☀️',
                value: showDayMin > 0 ? _fmtHm(showDayMin) : '--',
                label: 'Daytime intake', sub: feedPeriodLabel, color: _kOrange,
              )),
              const SizedBox(width: 8),
              Expanded(child: _StatCard(
                cardBg: cardBg, emoji: '🌙',
                value: showNightMin > 0 ? _fmtHm(showNightMin) : '--',
                label: 'Night intake', sub: '$feedPeriodLabel · $trendArrow', color: _kIndigo,
              )),
            ]),
          ),
          const SizedBox(height: 8),
          _Blurb(_nightStretchWk
              ? (bracket != null
                  ? 'Dashed lines: ${_fmtHm(bm)} age target · grey = ${_fmtHm(avgLongest)} period avg.'
                  : 'Grey dashed = ${_fmtHm(avgLongest)} period avg. Add birth date in Settings for age target.')
              : 'Weekly avg of nightly longest stretch. Grey dashed = overall avg.'),
        ])),

        // Day vs Night Intake chart (controlled by same toggle above)
        if (dnChartData.any((d) => d.dayMin > 0 || d.nightMin > 0)) ...[
          _SectionLabel('🌅 Day vs Night Intake'),
          _Card(cardBg: cardBg, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _DualLineChart(data: dnChartData),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _kIndigo.withOpacity(0.06),
              ),
              child: Text(
                '💡 As baby grows, daytime intake should rise and night feeding gradually decrease.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade400, height: 1.4),
              ),
            ),
          ])),
        ],

        _SectionLabel('🍼 Evening Feeding  ·  dense = 2+ feeds 6–10pm'),
        if (eveningData.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text('Not enough data yet.', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          )
        else
          _Card(cardBg: cardBg, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Column(children: [
                Text(avgLastFeed != null ? _fmtTime(avgLastFeed) : '--',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kOrange)),
                Text('Avg last eve feed', style: TextStyle(fontSize: 11, color: Colors.grey.shade500), textAlign: TextAlign.center),
              ])),
              Expanded(child: Column(children: [
                Text('${denseNights.length}/${eveningData.length}',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kOrange)),
                Text('Dense evenings', style: TextStyle(fontSize: 11, color: Colors.grey.shade500), textAlign: TextAlign.center),
                Text('(2+ feeds, 6–10pm)', style: TextStyle(fontSize: 9, color: Colors.grey.shade600), textAlign: TextAlign.center),
              ])),
            ]),
            if (denseNights.isNotEmpty && sparseNights.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Text('First stretch after:', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              const SizedBox(height: 4),
              Row(children: [
                Text(_fmtHm(avgDense), style: const TextStyle(fontWeight: FontWeight.bold, color: _kGreen)),
                const SizedBox(width: 4),
                Text('dense evening', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                const SizedBox(width: 16),
                Text(_fmtHm(avgSparse), style: const TextStyle(fontWeight: FontWeight.bold, color: _kAmber)),
                const SizedBox(width: 4),
                Text('sparse', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              ]),
            ],
            const SizedBox(height: 8),
            _Blurb(eveningBlurb),
          ])),

        const SizedBox(height: 16),
      ]),
    );

    Widget tipsTab() => RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        _SectionLabel('🎯 Your Data'),
        _Card(cardBg: cardBg, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (recs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('Not enough data yet. Keep tracking!',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            )
          else
            ...recs.map((r) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.icon, style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 10),
                Expanded(child: Text(r.text, style: TextStyle(fontSize: 13, color: r.color, height: 1.4))),
              ]),
            )),
        ])),
        if (bracket != null) ...[
          _SectionLabel('💡 For $weeks Weeks'),
          _Card(cardBg: cardBg, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ..._ageTips(bracket, weeks).map((tip) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Text(tip, style: TextStyle(fontSize: 13, color: Colors.grey.shade400, height: 1.4)),
            )),
          ])),
        ],
        const SizedBox(height: 24),
      ]),
    );

    return DefaultTabController(
      length: 3,
      child: Column(children: [
        // Compact header (age + birth date banner)
        if (weeks != null || _birthDate == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (weeks != null)
                Text('Baby is $weeks weeks old',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
              if (_birthDate == null)
                _Banner(
                  color: _kPurple,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('📅 Set baby birth date',
                        style: TextStyle(fontWeight: FontWeight.bold, color: _kPurple, fontSize: 14)),
                    const SizedBox(height: 4),
                    const Text('Add birth date in Settings for age-appropriate tips.',
                        style: TextStyle(fontSize: 12, color: _kMuted)),
                  ]),
                ),
            ]),
          ),
        TabBar(
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          tabs: const [
            Tab(text: 'Night'),
            Tab(text: 'Trends'),
            Tab(text: 'Tips'),
          ],
        ),
        Expanded(child: TabBarView(children: [
          nightTab(),
          trendsTab(),
          tipsTab(),
        ])),
      ]),
    );
  }
}

// ── UI Components ─────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
        color: Colors.grey.shade500, letterSpacing: 0.5)),
  );
}


class _Card extends StatelessWidget {
  final Widget child;
  final Color cardBg;
  const _Card({required this.child, required this.cardBg});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: cardBg,
        border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200),
      ),
      child: child,
    );
  }
}

class _Banner extends StatelessWidget {
  final Color color;
  final Widget child;
  const _Banner({required this.color, required this.child});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      color: color.withOpacity(0.1),
      border: Border.all(color: color, width: 2),
    ),
    child: child,
  );
}

class _StatCard extends StatelessWidget {
  final Color cardBg;
  final String emoji, value, label;
  final String? sub;
  final Color color;
  const _StatCard({required this.cardBg, required this.emoji, required this.value,
      required this.label, this.sub, required this.color});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12), color: cardBg,
        border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(emoji, style: const TextStyle(fontSize: 18)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade500), textAlign: TextAlign.center),
        if (sub != null)
          Text(sub!, style: TextStyle(fontSize: 9, color: Colors.grey.shade600), textAlign: TextAlign.center),
      ]),
    );
  }
}

class _Blurb extends StatelessWidget {
  final String text;
  const _Blurb(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: TextStyle(fontSize: 12, color: Colors.grey.shade500, height: 1.4));
}

// Night timeline: 20:00–08:00 fixed window
class _NightTimeline extends StatelessWidget {
  final Color cardBg;
  final DateTime nightStart, nightEnd;
  final DateTime? strictStart; // 22:00 — shown as distinct shade
  final List<BabyEvent> events;
  final List<({DateTime start, DateTime end, int minutes})> gaps;
  const _NightTimeline({required this.cardBg, required this.nightStart,
      required this.nightEnd, this.strictStart, required this.events, required this.gaps});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Timeline starts at 18:00 to capture early bedtimes
    final tlStart = DateTime(nightStart.year, nightStart.month, nightStart.day, 18).millisecondsSinceEpoch.toDouble();
    final tlEnd = nightEnd.millisecondsSinceEpoch.toDouble();
    final tlRange = tlEnd - tlStart;

    // Compute event positions for label dedup
    final eventsInWindow = events.where((e) {
      final ms = e.startTime.millisecondsSinceEpoch.toDouble();
      return ms >= tlStart && ms <= tlEnd;
    }).toList();

    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: cardBg,
          border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200)),
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('NIGHT TIMELINE (18:00–08:00)',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                color: Colors.grey.shade500, letterSpacing: 0.5)),
        const SizedBox(height: 8),
        LayoutBuilder(builder: (context, constraints) {
          final w = constraints.maxWidth;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Bar track
            SizedBox(height: 40, width: w, child: Stack(children: [
              // Background
              Container(decoration: BoxDecoration(
                  color: _kIndigo.withOpacity(0.04), borderRadius: BorderRadius.circular(6))),
              // Evening shade (18:00–22:00) — lighter
              Positioned(
                left: 0,
                width: w * ((nightStart.millisecondsSinceEpoch - tlStart) / tlRange),
                top: 0, bottom: 0,
                child: Container(decoration: BoxDecoration(
                    color: _kIndigo.withOpacity(0.05), borderRadius: BorderRadius.circular(4))),
              ),
              // Night shade (22:00–08:00) — darker
              if (strictStart != null)
                Positioned(
                  left: w * ((strictStart!.millisecondsSinceEpoch - tlStart) / tlRange),
                  width: w * ((nightEnd.millisecondsSinceEpoch - strictStart!.millisecondsSinceEpoch) / tlRange),
                  top: 0, bottom: 0,
                  child: Container(decoration: BoxDecoration(
                      color: _kIndigo.withOpacity(0.12), borderRadius: BorderRadius.circular(4))),
                ),
              // Sleep blocks
              ...gaps.map((g) {
                final left = w * ((g.start.millisecondsSinceEpoch - tlStart) / tlRange);
                final gapW = w * (g.minutes * 60000 / tlRange);
                return Positioned(
                  left: left.clamp(0, w - 2),
                  width: gapW.clamp(2, w - left.clamp(0, w)),
                  top: 4, bottom: 4,
                  child: Tooltip(
                    message: '${_fmtHm(g.minutes)} sleep',
                    child: Container(decoration: BoxDecoration(
                        color: _kIndigo.withOpacity(0.6), borderRadius: BorderRadius.circular(4))),
                  ),
                );
              }),
              // Event emojis
              ...eventsInWindow.map((e) {
                final left = w * ((e.startTime.millisecondsSinceEpoch - tlStart) / tlRange);
                final emoji = e.type == EventType.feed ? '🍼' :
                              e.type == EventType.diaper ? '🧷' : '🥛';
                return Positioned(
                  left: (left - 10).clamp(0, w - 20),
                  top: 0, bottom: 0,
                  child: Center(child: Text(emoji, style: const TextStyle(fontSize: 16))),
                );
              }),
            ])),
            const SizedBox(height: 4),
            // Time labels — event-aligned + fixed hours, deduplicated
            SizedBox(height: 16, width: w, child: Stack(children: [
              ..._buildLabels(tlStart, tlEnd, tlRange, w, eventsInWindow),
            ])),
          ]);
        }),
      ]),
    );
  }

  List<Widget> _buildLabels(double tlStart, double tlEnd, double tlRange, double w, List<BabyEvent> evs) {
    final labelItems = <({double ms, bool isEvent})>[];
    // Fixed hour marks: 20,22,0,2,4,6,8
    for (final h in [18, 20, 22, 0, 2, 4, 6, 8]) {
      final d = DateTime.fromMillisecondsSinceEpoch(tlStart.toInt())
          .copyWith(hour: h, minute: 0, second: 0, millisecond: 0);
      final ms = (h < 20 ? d.add(const Duration(days: 1)) : d).millisecondsSinceEpoch.toDouble();
      if (ms >= tlStart && ms <= tlEnd) labelItems.add((ms: ms, isEvent: false));
    }
    // Event times
    for (final e in evs) {
      labelItems.add((ms: e.startTime.millisecondsSinceEpoch.toDouble(), isEvent: true));
    }
    labelItems.sort((a, b) => a.ms.compareTo(b.ms));

    // Deduplicate within 25min
    final filtered = <({double ms, bool isEvent})>[];
    for (final l in labelItems) {
      if (filtered.isEmpty || l.ms - filtered.last.ms >= 25 * 60000) filtered.add(l);
    }

    return filtered.map((l) {
      final left = w * ((l.ms - tlStart) / tlRange);
      final d = DateTime.fromMillisecondsSinceEpoch(l.ms.toInt());
      final label = '${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}';
      return Positioned(
        left: (left - 16).clamp(0, w - 32),
        top: 0, bottom: 0,
        child: Text(label, style: TextStyle(
          fontSize: 9,
          color: l.isEvent ? Colors.grey.shade300 : Colors.grey.shade600,
          fontWeight: l.isEvent ? FontWeight.bold : FontWeight.normal,
        )),
      );
    }).toList();
  }
}

// Mini bar chart for 7-day trend
class _MiniBarChart extends StatelessWidget {
  final List<({String label, int v1})> data;
  final Color color1;
  final int benchmark;
  const _MiniBarChart({required this.data, required this.color1, required this.benchmark});

  @override
  Widget build(BuildContext context) {
    final nonZero = data.where((d) => d.v1 > 0).toList();
    final avgVal = nonZero.isEmpty ? 0 : nonZero.fold(0, (s, d) => s + d.v1) ~/ nonZero.length;
    final maxVal = [...data.map((d) => d.v1), benchmark, avgVal].reduce((a, b) => a > b ? a : b);
    if (maxVal == 0) return const SizedBox(height: 80);

    const barH = 52.0;
    const labelH = 16.0;
    const numH = 14.0;
    return SizedBox(height: barH + labelH + numH, child: LayoutBuilder(builder: (context, c) {
      final barW = (c.maxWidth - data.length * 4) / data.length;
      final bmY = benchmark > 0 ? (1 - benchmark / maxVal) * barH : -1.0;
      final avgY = avgVal > 0 ? (1 - avgVal / maxVal) * barH : -1.0;
      return Stack(children: [
        // Bar value numbers
        Positioned(top: 0, left: 0, right: 0, height: numH,
          child: Row(children: data.map((d) => SizedBox(
            width: barW + 4,
            child: d.v1 > 0
                ? Text(_fmtHm(d.v1),
                    style: TextStyle(fontSize: 8, color: Colors.grey.shade400),
                    textAlign: TextAlign.center)
                : const SizedBox.shrink(),
          )).toList()),
        ),
        // Bars
        Positioned(top: numH, left: 0, right: 0, bottom: labelH,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            ...data.map((d) => Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (d.v1 > 0) Container(
                  width: barW,
                  height: (d.v1 / maxVal * barH).clamp(2.0, barH),
                  decoration: BoxDecoration(
                      color: color1.withOpacity(0.85),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(2))),
                ) else SizedBox(width: barW, height: 0),
              ]),
            )),
          ]),
        ),
        // Benchmark dashed line (age target)
        if (benchmark > 0 && bmY >= 0)
          Positioned(
            top: numH + bmY.clamp(0.0, barH - 1),
            left: 0, right: 0,
            child: CustomPaint(painter: _DashedLinePainter(color: color1.withOpacity(0.5))),
          ),
        // Avg dashed line
        if (avgVal > 0 && avgY >= 0)
          Positioned(
            top: numH + avgY.clamp(0.0, barH - 1),
            left: 0, right: 0,
            child: CustomPaint(painter: _DashedLinePainter(color: Colors.grey.withOpacity(0.45))),
          ),
        // Date labels
        Positioned(bottom: 0, left: 0, right: 0, height: labelH,
          child: Row(children: data.map((d) => SizedBox(
            width: barW + 4,
            child: Text(d.label,
                style: TextStyle(fontSize: 7, color: Colors.grey.shade600),
                textAlign: TextAlign.center),
          )).toList()),
        ),
      ]);
    }));
  }
}

class _NarrativeRow extends StatelessWidget {
  final String time, text;
  final bool isSleep;
  final bool isEvening;
  const _NarrativeRow({required this.time, required this.text, required this.isSleep, this.isEvening = false});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = isEvening
        ? _kAmber.withOpacity(0.10)
        : _kIndigo.withOpacity(0.07);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 44, child: Text(time, style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w600,
          color: isSleep ? _kIndigo : Colors.grey.shade500,
        ))),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: TextStyle(
          fontSize: 13, height: 1.3,
          color: isSleep ? cs.onSurface : Colors.grey.shade500,
          fontWeight: isSleep ? FontWeight.w500 : FontWeight.normal,
        ))),
      ]),
    );
  }
}

class _PeriodDivider extends StatelessWidget {
  final String label;
  const _PeriodDivider({required this.label});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(children: [
      Expanded(child: Divider(color: _kIndigo.withOpacity(0.25), height: 1)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(label, style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w700,
            color: _kIndigo, letterSpacing: 0.4)),
      ),
      Expanded(child: Divider(color: _kIndigo.withOpacity(0.25), height: 1)),
    ]),
  );
}

class _DashedLinePainter extends CustomPainter {
  final Color color;
  const _DashedLinePainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 1.2;
    double x = 0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0), Offset((x + 6).clamp(0, size.width), 0), paint);
      x += 10;
    }
  }
  @override bool shouldRepaint(_) => false;
}

class _LinePainter extends CustomPainter {
  final List<double> vals1;
  final Color color1;
  final List<double>? vals2;
  final Color? color2;
  _LinePainter({required this.vals1, required this.color1, this.vals2, this.color2});

  @override
  void paint(Canvas canvas, Size size) {
    if (vals1.isEmpty) return;
    final all = [...vals1, if (vals2 != null) ...vals2!];
    final maxV = all.reduce((a, b) => a > b ? a : b).clamp(1.0, double.infinity);
    final n = vals1.length;
    const padH = 4.0, padV = 10.0;
    final w = size.width - 2 * padH;
    final h = size.height - 2 * padV;

    Offset pt(int i, double v) => Offset(
      n <= 1 ? size.width / 2 : padH + i * w / (n - 1),
      padV + h * (1 - v / maxV),
    );

    void drawLine(List<double> vals, Color color) {
      final strokePaint = Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (int i = 0; i < vals.length; i++) {
        final p = pt(i, vals[i]);
        if (i == 0) { path.moveTo(p.dx, p.dy); } else { path.lineTo(p.dx, p.dy); }
      }
      canvas.drawPath(path, strokePaint);
      final dotPaint = Paint()..color = color..style = PaintingStyle.fill;
      for (int i = 0; i < vals.length; i++) {
        canvas.drawCircle(pt(i, vals[i]), 3, dotPaint);
      }
    }

    if (vals2 != null) drawLine(vals2!, color2 ?? Colors.grey);
    drawLine(vals1, color1);
  }

  @override
  bool shouldRepaint(_LinePainter old) => true;
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 8, height: 8,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
    const SizedBox(width: 4),
    Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
  ]);
}

class _DualLineChart extends StatelessWidget {
  final List<({String label, int dayMin, int nightMin})> data;
  const _DualLineChart({required this.data});

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const SizedBox.shrink();
    final allVals = [...data.map((d) => d.dayMin), ...data.map((d) => d.nightMin)];
    final maxV = allVals.reduce((a, b) => a > b ? a : b).clamp(1, 99999);
    final midV = maxV ~/ 2;

    return Column(children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 30,
          height: 100,
          child: Stack(children: [
            Positioned(top: 4, left: 0,
                child: Text(_fmtHm(maxV),
                    style: TextStyle(fontSize: 8, color: Colors.grey.shade500))),
            Positioned(top: 46, left: 0,
                child: Text(_fmtHm(midV),
                    style: TextStyle(fontSize: 8, color: Colors.grey.shade500))),
            Positioned(bottom: 2, left: 0,
                child: Text('0m',
                    style: TextStyle(fontSize: 8, color: Colors.grey.shade500))),
          ]),
        ),
        Expanded(child: SizedBox(
          height: 100,
          child: CustomPaint(
            painter: _LinePainter(
              vals1: data.map((d) => d.dayMin.toDouble()).toList(),
              color1: _kOrange,
              vals2: data.map((d) => d.nightMin.toDouble()).toList(),
              color2: _kIndigo,
            ),
            child: const SizedBox.expand(),
          ),
        )),
      ]),
      const SizedBox(height: 2),
      Padding(
        padding: const EdgeInsets.only(left: 30),
        child: Row(
          children: data.map((d) => Expanded(
            child: Text(d.label,
                style: TextStyle(fontSize: 7, color: Colors.grey.shade600),
                textAlign: TextAlign.center),
          )).toList(),
        ),
      ),
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _LegendDot(color: _kOrange, label: 'Day (6am–10pm)'),
        const SizedBox(width: 14),
        _LegendDot(color: _kIndigo, label: 'Night (10pm–6am)'),
      ]),
    ]);
  }
}
