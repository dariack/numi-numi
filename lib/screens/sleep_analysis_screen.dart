import 'package:flutter/material.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';

// ── Colours ──────────────────────────────────────────────────────────
const _kIndigo = Color(0xFF6366f1);
const _kTeal   = Color(0xFF2dd4bf);
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
  final day = d.day.toString().padLeft(2, '0');
  final month = d.month.toString().padLeft(2, '0');
  return days[d.weekday - 1] + ' ' + day + '/' + month;
}

String _fmtHm(int mins) {
  if (mins < 60) return '${mins}m';
  final h = mins ~/ 60;
  final m = mins % 60;
  return m > 0 ? '${h}h ${m}m' : '${h}h';
}

String _fmtTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

List<String> _ageTips(String bracket, int? weeks) {
  final w = weeks?.toString() ?? '?';
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
  int _selectedNightOffset = 1; // 1 = last night, 2 = 2 nights ago, etc.
  late final PageController _nightPageController = PageController();

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
      widget.service.getRecentEvents(days: 10),
    ]);
    if (mounted) setState(() {
      _birthDate = results[0] as DateTime?;
      _allEvents = results[1] as List<BabyEvent>;
      _loading = false;
    });
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

    // Determine last night
    // Adjust for early morning — if before 8am, yesterday hasn't ended yet
    final baseOffset = now.hour < 8 ? _selectedNightOffset + 1 : _selectedNightOffset;
    var lastNightBase = DateTime(now.year, now.month, now.day - baseOffset);
    final lastNight = _nightWindow(lastNightBase);
    final lastNightStrict = _strictNightWindow(lastNightBase);
    // Use full window (18:00–08:00) for gap inference so early bedtimes are captured
    final lastNightGaps = _inferNightSleep(actionEvents, lastNight.start, lastNight.end, gapMin);
    final lastNightEvents = actionEvents
        .where((e) => !e.startTime.isBefore(lastNight.start) && !e.startTime.isAfter(lastNight.end))
        .toList()..sort((a, b) => a.startTime.compareTo(b.startTime));

    final longestStretch = lastNightGaps.isEmpty ? 0 :
        lastNightGaps.map((g) => g.minutes).reduce((a, b) => a > b ? a : b);
    // Total sleep and wakings only count gaps within the strict 22:00–08:00 window
    final strictGaps = _inferNightSleep(actionEvents, lastNightStrict.start, lastNightStrict.end, gapMin);
    final totalSleep = strictGaps.fold(0, (s, g) => s + g.minutes);
    final wakings = (strictGaps.length - 1).clamp(0, 99);

    // 7-day trend
    final nightData = <({String label, int longest, int total})>[];
    for (int di = 7; di >= 1; di--) {
      final base = DateTime(now.year, now.month, now.day - di);
      final win = _nightWindow(base);
      final strictWin = _strictNightWindow(base);
      // Longest stretch: full window (catches early bedtimes)
      final gaps = _inferNightSleep(actionEvents, win.start, win.end, gapMin);
      final longest = gaps.isEmpty ? 0 : gaps.map((g) => g.minutes).reduce((a, b) => a > b ? a : b);
      // Total sleep: strict 22:00-08:00 window
      final strictGaps7 = _inferNightSleep(actionEvents, strictWin.start, strictWin.end, gapMin);
      final total = strictGaps7.fold(0, (s, g) => s + g.minutes);
      nightData.add((
        label: '${base.day.toString().padLeft(2, '0')}/${base.month.toString().padLeft(2, '0')}',
        longest: longest,
        total: total,
      ));
    }
    final validLongest = nightData.where((d) => d.longest > 0).toList();
    final avgLongest = validLongest.isEmpty ? 0 :
        validLongest.fold(0, (s, d) => s + d.longest) ~/ validLongest.length;
    final validTotal = nightData.where((d) => d.total > 0).toList();
    final avgTotal = validTotal.isEmpty ? 0 :
        validTotal.fold(0, (s, d) => s + d.total) ~/ validTotal.length;

    // Evening / cluster feeding
    final eveningData = <({DateTime lastFeedTime, bool isCluster, int firstStretch})>[];
    for (int di = 7; di >= 1; di--) {
      final base = DateTime(now.year, now.month, now.day - di);
      final win = _nightWindow(base);
      final eveningStart = DateTime(base.year, base.month, base.day, 18);
      final eveningFeeds = feedEvents
          .where((e) => !e.startTime.isBefore(eveningStart) &&
              e.startTime.isBefore(win.start.add(const Duration(hours: 2))))
          .toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
      if (eveningFeeds.isEmpty) continue;
      final lastFeed = eveningFeeds.last;
      final clusterWindow = lastFeed.startTime.subtract(const Duration(hours: 2));
      final isCluster = eveningFeeds.where((e) => !e.startTime.isBefore(clusterWindow)).length >= 2;
      // First stretch = gap after last evening feed, starting from feed end (may be before 22:00)
      final searchFrom = lastFeed.endTime ?? lastFeed.startTime;
      final gaps = _inferNightSleep(actionEvents, searchFrom, win.end, gapMin);
      final firstStretch = gaps.isEmpty ? 0 : gaps.first.minutes;
      eveningData.add((lastFeedTime: lastFeed.startTime, isCluster: isCluster, firstStretch: firstStretch));
    }
    final clusterNights = eveningData.where((d) => d.isCluster).toList();
    final nonClusterNights = eveningData.where((d) => !d.isCluster).toList();
    final avgCluster = clusterNights.isEmpty ? 0 :
        clusterNights.fold(0, (s, d) => s + d.firstStretch) ~/ clusterNights.length;
    final avgNoCluster = nonClusterNights.isEmpty ? 0 :
        nonClusterNights.fold(0, (s, d) => s + d.firstStretch) ~/ nonClusterNights.length;
    final avgLastFeedMs = eveningData.isEmpty ? 0 :
        eveningData.fold<int>(0, (s, d) => s + d.lastFeedTime.millisecondsSinceEpoch) ~/ eveningData.length;
    final avgLastFeed = avgLastFeedMs > 0 ? DateTime.fromMillisecondsSinceEpoch(avgLastFeedMs) : null;

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
    final validGaps = dayFeedData.where((d) => d.avgGap > 0).toList();
    final avgGapVal = validGaps.isEmpty ? 0 :
        validGaps.fold(0, (s, d) => s + d.avgGap) ~/ validGaps.length;

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
    if (clusterNights.isNotEmpty && nonClusterNights.isNotEmpty && avgCluster > avgNoCluster) {
      final diff = avgCluster - avgNoCluster;
      recs.add((icon: '🍇', color: _kPurple,
          text: 'Cluster feeding is working — adds ~${_fmtHm(diff)} to the first stretch. Keep the evening feeds dense.'));
    } else if (clusterNights.isEmpty && (weeks ?? 0) >= 6) {
      recs.add((icon: '🍇', color: _kPurple,
          text: 'No cluster feeding detected. Try 2+ feeds between 6–10pm to extend the first stretch.'));
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

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Age chip
          if (weeks != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Baby is $weeks weeks old',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            ),

          // No birth date banner
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

          // ── 1. Night Detail (swipeable PageView, 3 nights) ────────
          _SectionLabel('🌙 Night Detail'),
          SizedBox(height: 8, child: Row(
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
          )),
          const SizedBox(height: 8),
          SizedBox(
            height: 360,
            child: PageView.builder(
              controller: _nightPageController,
              itemCount: 3,
              onPageChanged: (i) => setState(() => _selectedNightOffset = i + 1),
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
                final pgTotal = pgStrictGaps.fold(0, (s, g) => s + g.minutes);
                final pgWakings = (pgStrictGaps.length - 1).clamp(0, 99);
                final pgLabel = offset == 1 ? 'Last night' : '$offset nights ago';

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('$pgLabel · ${_fmtDate(pgBase)}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    if (pgEvents.isEmpty && pgGaps.isEmpty)
                      Text('No data for this night.',
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade500))
                    else ...[
                      Row(children: [
                        Expanded(child: _StatCard(cardBg: cardBg, emoji: '💤', value: pgLongest > 0 ? _fmtHm(pgLongest) : '--', label: 'Longest stretch', color: _kIndigo)),
                        const SizedBox(width: 8),
                        Expanded(child: _StatCard(cardBg: cardBg, emoji: '🌙', value: pgTotal > 0 ? _fmtHm(pgTotal) : '--', label: 'Total sleep', sub: '22:00–08:00', color: _kTeal)),
                        const SizedBox(width: 8),
                        Expanded(child: _StatCard(cardBg: cardBg, emoji: '👶', value: '$pgWakings', label: 'Wakings', color: _kIndigo)),
                      ]),
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
                      _Blurb('Gaps >' + gapMin.toString() + 'min inferred as sleep · swipe to compare nights'),
                    ],
                  ]),
                );
              },
            ),
          ),
          const SizedBox(height: 16),

          // ── 2. 7-Day Trend ──────────────────────────────────────
          _SectionLabel('📊 7-Day Trend'),
          _Card(cardBg: cardBg, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _MiniBarChart(
              data: nightData.map((d) => (label: d.label, v1: d.longest, v2: d.total)).toList(),
              color1: _kIndigo,
              color2: _kTeal.withOpacity(0.5),
              benchmark: bm,
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Column(children: [
                Text(avgLongest > 0 ? _fmtHm(avgLongest) : '--',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kIndigo)),
                Text('Avg longest stretch', style: TextStyle(fontSize: 11, color: Colors.grey.shade500), textAlign: TextAlign.center),
              ])),
              Expanded(child: Column(children: [
                Text(avgTotal > 0 ? _fmtHm(avgTotal) : '--',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kTeal)),
                Text('Avg total sleep', style: TextStyle(fontSize: 11, color: Colors.grey.shade500), textAlign: TextAlign.center),
              ])),
            ]),
            const SizedBox(height: 8),
            _Blurb(bracket != null
                ? 'Age benchmark: ${_fmtHm(bm)} longest stretch for $weeks-week baby (dashed line). Individual variation is normal.'
                : 'Add birth date in Settings to see age benchmark.'),
          ])),
          const SizedBox(height: 16),

          // ── 3. Evening Feeding Pattern ──────────────────────────
          _SectionLabel('🍼 Evening Feeding Pattern'),
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
                  Text('Avg last evening feed', style: TextStyle(fontSize: 11, color: Colors.grey.shade500), textAlign: TextAlign.center),
                ])),
                Expanded(child: Column(children: [
                  Text('${clusterNights.length}/${eveningData.length}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kOrange)),
                  Text('Nights with cluster feeding', style: TextStyle(fontSize: 11, color: Colors.grey.shade500), textAlign: TextAlign.center),
                ])),
              ]),
              if (clusterNights.isNotEmpty && nonClusterNights.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 8),
                Text('First stretch after:', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                const SizedBox(height: 4),
                Row(children: [
                  Text(_fmtHm(avgCluster), style: const TextStyle(fontWeight: FontWeight.bold, color: _kGreen)),
                  const SizedBox(width: 4),
                  Text('with cluster', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  const SizedBox(width: 16),
                  Text(_fmtHm(avgNoCluster), style: const TextStyle(fontWeight: FontWeight.bold, color: _kAmber)),
                  const SizedBox(width: 4),
                  Text('without', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                ]),
              ],
              const SizedBox(height: 8),
              _Blurb(clusterNights.isNotEmpty && nonClusterNights.isNotEmpty && avgCluster > avgNoCluster
                  ? '✅ Cluster feeding is working — adds ~${_fmtHm(avgCluster - avgNoCluster)} to the first stretch. Keep the evening feeds dense.'
                  : clusterNights.isEmpty && (weeks ?? 0) >= 6
                      ? 'No cluster feeding detected. Try 2+ feeds between 6–10pm to extend the first stretch.'
                      : 'Cluster feeding detected on ${clusterNights.length}/${eveningData.length} nights.'),
            ])),
          const SizedBox(height: 16),

          // ── 4. Daytime Feed Density ─────────────────────────────
          _SectionLabel('☀️ Daytime Feed Density'),
          _Card(cardBg: cardBg, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Column(children: [
                Text(avgFeedCount > 0 ? avgFeedCount.toStringAsFixed(1) : '--',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kOrange)),
                Text('Avg feeds/day\n8am–8pm', style: TextStyle(fontSize: 11, color: Colors.grey.shade500), textAlign: TextAlign.center),
              ])),
              Expanded(child: Column(children: [
                Text(avgGapVal > 0 ? _fmtHm(avgGapVal) : '--',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kOrange)),
                Text('Avg gap between feeds', style: TextStyle(fontSize: 11, color: Colors.grey.shade500), textAlign: TextAlign.center),
              ])),
            ]),
            const SizedBox(height: 12),
            _DayFeedChart(data: dayFeedData.map((d) => (label: d.label, count: d.count)).toList()),
            const SizedBox(height: 8),
            _Blurb(avgFeedCount >= 4
                ? '✅ ${avgFeedCount.toStringAsFixed(1)} avg feeds — above Giordano target of 4+ evenly spaced feeds. Front-loading calories 8am–8pm is the key lever for longer night stretches.'
                : avgFeedCount > 0
                    ? '⚠️ ${avgFeedCount.toStringAsFixed(1)} avg feeds — below the 4-feed target. More frequent daytime feeds reduce night hunger.'
                    : 'Not enough daytime feed data yet.'),
          ])),
          const SizedBox(height: 16),

          // ── 5. Night Feed Trend ─────────────────────────────────
          _SectionLabel('📉 Night Feed Trend'),
          _Card(cardBg: cardBg, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _NightFeedChart(data: nightFeedTrend.map((d) => (label: d.label, count: d.count)).toList()),
            const SizedBox(height: 8),
            Row(children: [
              Text(nfTrend == 'down' ? '📉' : nfTrend == 'up' ? '📈' : '➡️', style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Expanded(child: Text(
                nfTrend == 'down' ? 'Trending down — great progress!' :
                nfTrend == 'up' ? 'More night feeds recently' : 'Holding steady',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: nfTrend == 'down' ? _kGreen : nfTrend == 'up' ? const Color(0xFFef4444) : _kAmber,
                ),
              )),
            ]),
            const SizedBox(height: 4),
            _Blurb(nfTrend == 'down'
                ? 'Down from ${olderAvgNF.toStringAsFixed(1)} to ${recentAvgNF.toStringAsFixed(1)} sessions/night. Giordano method: gradually reducing night feeds is the path to sleeping through.'
                : nfTrend == 'up'
                    ? 'Up from ${olderAvgNF.toStringAsFixed(1)} to ${recentAvgNF.toStringAsFixed(1)} sessions/night. Growth spurts and regressions are normal.'
                    : 'Holding at ~${recentAvgNF.toStringAsFixed(1)} sessions/night. Each session = one complete feeding (both sides = one session).'),
          ])),
          const SizedBox(height: 16),

          // ── 6. Insights & Tips ──────────────────────────────────
          _SectionLabel('🎯 Insights & Tips'),
          _Card(cardBg: cardBg, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _SubLabel('BASED ON YOUR DATA'),
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
                  Expanded(child: Text(r.text,
                      style: TextStyle(fontSize: 13, color: r.color, height: 1.4))),
                ]),
              )),
            if (bracket != null) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 10),
              _SubLabel('GENERAL TIPS FOR $weeks WEEKS'),
              ..._ageTips(bracket, weeks).map((tip) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Text(tip, style: TextStyle(fontSize: 13, color: Colors.grey.shade400, height: 1.4)),
              )),
            ],
          ])),
          const SizedBox(height: 24),
        ],
      ),
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

class _SubLabel extends StatelessWidget {
  final String text;
  const _SubLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
        color: Colors.grey.shade500, letterSpacing: 0.08)),
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
      final label = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
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
  final List<({String label, int v1, int v2})> data;
  final Color color1, color2;
  final int benchmark;
  const _MiniBarChart({required this.data, required this.color1, required this.color2, required this.benchmark});

  @override
  Widget build(BuildContext context) {
    final maxVal = [
      ...data.map((d) => d.v1),
      ...data.map((d) => d.v2),
      benchmark,
    ].reduce((a, b) => a > b ? a : b);

    return SizedBox(height: 80, child: LayoutBuilder(builder: (context, c) {
      final barW = (c.maxWidth - data.length * 4) / data.length;
      final bmY = (1 - benchmark / maxVal) * 60;
      return Stack(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          ...data.map((d) => Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
              // v2 (total, teal, behind)
              if (d.v2 > 0) Container(
                width: barW,
                height: (d.v2 / maxVal * 60).clamp(2.0, 60.0).toDouble(),
                decoration: BoxDecoration(color: color2, borderRadius: const BorderRadius.vertical(top: Radius.circular(2))),
              ),
              // v1 (longest, indigo) — stacked on top but shown separately via overlap
            ]),
          )),
        ]),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          ...data.map((d) => Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (d.v1 > 0) Container(
                width: barW,
                height: (d.v1 / maxVal * 60).clamp(2.0, 60.0).toDouble(),
                decoration: BoxDecoration(color: color1.withOpacity(0.85), borderRadius: const BorderRadius.vertical(top: Radius.circular(2))),
              ) else SizedBox(width: barW, height: 0),
            ]),
          )),
        ]),
        // Benchmark dashed line
        Positioned(
          top: bmY,
          left: 0, right: 0,
          child: CustomPaint(painter: _DashedLinePainter(color: color1.withOpacity(0.7))),
        ),
        // Labels
        Positioned(bottom: 0, left: 0, right: 0,
          child: Row(children: data.map((d) => SizedBox(
            width: barW + 4,
            child: Text(d.label, style: TextStyle(fontSize: 7, color: Colors.grey.shade600), textAlign: TextAlign.center),
          )).toList()),
        ),
      ]);
    }));
  }
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

// Daytime feed bar chart
class _DayFeedChart extends StatelessWidget {
  final List<({String label, int count})> data;
  const _DayFeedChart({required this.data});
  @override
  Widget build(BuildContext context) {
    final maxVal = data.map((d) => d.count).reduce((a, b) => a > b ? a : b).clamp(1, 999);
    return SizedBox(height: 60, child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: data.map((d) {
      final px = d.count > 0 ? (d.count / maxVal * 40).clamp(3.0, 40.0) : 0.0;
      final isBright = d.count >= 4;
      return Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
        if (d.count > 0) Text('${d.count}', style: TextStyle(fontSize: 8, color: Colors.grey.shade500)),
        const SizedBox(height: 2),
        Container(margin: const EdgeInsets.symmetric(horizontal: 2), height: px,
            decoration: BoxDecoration(
                color: isBright ? _kOrange.withOpacity(0.85) : _kOrange.withOpacity(0.3),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(2)))),
        const SizedBox(height: 2),
        Text(d.label, style: TextStyle(fontSize: 7, color: Colors.grey.shade600), textAlign: TextAlign.center),
      ]));
    }).toList()));
  }
}

// Night feed bar chart
class _NightFeedChart extends StatelessWidget {
  final List<({String label, int count})> data;
  const _NightFeedChart({required this.data});
  @override
  Widget build(BuildContext context) {
    final maxVal = data.map((d) => d.count).reduce((a, b) => a > b ? a : b).clamp(1, 999);
    return SizedBox(height: 60, child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: data.map((d) {
      final px = d.count > 0 ? (d.count / maxVal * 40).clamp(3.0, 40.0) : 0.0;
      return Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
        if (d.count > 0) Text('${d.count}', style: TextStyle(fontSize: 8, color: Colors.grey.shade500)),
        const SizedBox(height: 2),
        Container(margin: const EdgeInsets.symmetric(horizontal: 2), height: px,
            decoration: BoxDecoration(
                color: _kIndigo.withOpacity(0.7),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(2)))),
        const SizedBox(height: 2),
        Text(d.label, style: TextStyle(fontSize: 7, color: Colors.grey.shade600), textAlign: TextAlign.center),
      ]));
    }).toList()));
  }
}
