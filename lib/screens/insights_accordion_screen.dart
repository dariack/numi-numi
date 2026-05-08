import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';

// ── Constants ────────────────────────────────────────────────────
const kFeedColor2   = Colors.orange;
const kDiaperColor2 = Colors.teal;
const kPumpColor2   = Color(0xFFF472B6);
const _kGreen  = Color(0xFF22c55e);
const _kRed    = Color(0xFFef4444);
const _kAmber  = Color(0xFFf59e0b);
const _kIndigo = Color(0xFF6366f1);
const _kOrange = Color(0xFFf97316);

// ── Top-level data helpers ────────────────────────────────────────

({int totalMin, int count, int dayMin, int nightMin, double avgSession})
    _feedStatsForDay(List<BabyEvent> feeds, DateTime day) {
  final wStart = DateTime(day.year, day.month, day.day, 6);
  final wEnd   = DateTime(day.year, day.month, day.day + 1, 6);
  final dayEnd = DateTime(day.year, day.month, day.day, 22);
  final inWin  = feeds.where((e) =>
      !e.startTime.isBefore(wStart) &&
      e.startTime.isBefore(wEnd)).toList();
  var totalMin = 0, dayMin = 0, nightMin = 0;
  for (final f in inWin) {
    final dur = f.source == 'pump' ? (f.mlFed ?? 0) ~/ 3 : f.duration?.inMinutes ?? 0;
    totalMin += dur;
    if (f.startTime.isBefore(dayEnd)) { dayMin += dur; } else { nightMin += dur; }
  }
  return (
    totalMin: totalMin, count: inWin.length,
    dayMin: dayMin, nightMin: nightMin,
    avgSession: inWin.isEmpty ? 0.0 : totalMin / inWin.length,
  );
}

int _wetDiaperCount(List<BabyEvent> diapers, DateTime day) {
  final wStart = DateTime(day.year, day.month, day.day, 6);
  final wEnd   = DateTime(day.year, day.month, day.day + 1, 6);
  return diapers.where((e) =>
      e.pee && !e.startTime.isBefore(wStart) && e.startTime.isBefore(wEnd)).length;
}

// ── Screen ────────────────────────────────────────────────────────

class InsightsAccordionScreen extends StatefulWidget {
  final FirestoreService service;
  const InsightsAccordionScreen({super.key, required this.service});
  @override
  State<InsightsAccordionScreen> createState() => _InsightsAccordionScreenState();
}

class _InsightsAccordionScreenState extends State<InsightsAccordionScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  bool _loading = true;
  List<BabyEvent> _allEvents = [];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final events = await widget.service.getRecentEvents(days: 28);
    if (!mounted) return;
    setState(() {
      _allEvents = events;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_loading) return const Center(child: CircularProgressIndicator());

    return Column(children: [
      ListenableBuilder(
        listenable: _tabCtrl,
        builder: (context, _) {
          final color = _tabCtrl.index == 0 ? kFeedColor2 : kDiaperColor2;
          return TabBar(
            controller: _tabCtrl,
            indicatorColor: color,
            labelColor: color,
            unselectedLabelColor: Colors.grey.shade500,
            labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            onTap: (_) => HapticFeedback.lightImpact(),
            tabs: const [Tab(text: '🍼 Feed'), Tab(text: '🧷 Diaper')],
          );
        },
      ),
      Expanded(
        child: TabBarView(
          controller: _tabCtrl,
          children: [
            RefreshIndicator(
              onRefresh: _load,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: _FeedPanel(allEvents: _allEvents, isDark: isDark),
              ),
            ),
            RefreshIndicator(
              onRefresh: _load,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: _DiaperPanel(allEvents: _allEvents, isDark: isDark),
              ),
            ),
          ],
        ),
      ),
    ]);
  }
}

// ── Shared helpers ────────────────────────────────────────────────

String _fmtMins(num m) {
  if (m <= 0) return '0m';
  final mins = m.round();
  if (mins >= 60) return '${mins ~/ 60}h ${mins % 60}m';
  return '${mins}m';
}

String _fmtMinsLong(num m) {
  if (m <= 0) return '0 min';
  final mins = m.round();
  if (mins >= 60) {
    final rem = mins % 60;
    return rem == 0 ? '${mins ~/ 60}h' : '${mins ~/ 60}h ${rem}m';
  }
  return '$mins min';
}

double _computeGapMins(List<BabyEvent> feeds, DateTime from, bool daySlot, {DateTime? to}) {
  final sorted = feeds.where((e) {
    if (e.source == 'pump') return false;
    if (!e.startTime.isAfter(from)) return false;
    if (to != null && !e.startTime.isBefore(to)) return false;
    return true;
  }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
  final inSlot = sorted.where((e) {
    final h = e.startTime.hour;
    return daySlot ? (h >= 10 && h < 22) : (h >= 22 || h < 10);
  }).toList();
  if (inSlot.length < 2) return 0.0;
  var total = 0.0; var count = 0;
  for (int i = 1; i < inSlot.length; i++) {
    final gap = inSlot[i].startTime.difference(inSlot[i - 1].startTime).inMinutes;
    if (gap > 0 && gap < 360) { total += gap; count++; }
  }
  return count == 0 ? 0.0 : total / count;
}

Widget _subHeader(String text) => Padding(
  padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
  child: Text(text, style: TextStyle(
      fontSize: 10, fontWeight: FontWeight.w700,
      color: Colors.grey.shade500, letterSpacing: 0.5)),
);

Widget _badge(double cur, double avg) {
  if (avg <= 0) return const SizedBox.shrink();
  final pct = (cur - avg) / avg;
  String text; Color color;
  if (pct > 0.15)       { text = '↑ ' + (pct * 100).round().toString() + '%'; color = _kGreen; }
  else if (pct < -0.15) { text = '↓ ' + (pct.abs() * 100).round().toString() + '%'; color = _kRed; }
  else                  { text = '≈ avg'; color = Colors.grey; }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6), color: color.withOpacity(0.12)),
    child: Text(text, style: TextStyle(
        fontSize: 11, fontWeight: FontWeight.w700, color: color)),
  );
}

Widget _row(String label, String value, double cur, double avg,
    {String? avgLabel, Widget? extra}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(children: [
      SizedBox(width: 128, child: Text(label,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade400))),
      Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      const SizedBox(width: 8),
      _badge(cur, avg),
      if (avgLabel != null) ...[
        const SizedBox(width: 6),
        Text(avgLabel, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ],
      if (extra != null) ...[
        const SizedBox(width: 6),
        extra,
      ],
    ]),
  );
}

Widget _gapTrendBadge(double cur, double prev) {
  if (prev <= 0 || cur <= 0) return const SizedBox.shrink();
  final delta = cur - prev;
  if (delta.abs() < 5) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: Colors.grey.withOpacity(0.12)),
      child: const Text('≈ prev', style: TextStyle(
          fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey)),
    );
  }
  final isUp = delta > 0;
  final absMins = delta.abs().round();
  final text = (isUp ? '+' : '−') + _fmtMins(absMins);
  final color = isUp ? _kGreen : _kRed;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6), color: color.withOpacity(0.12)),
    child: Text(text, style: TextStyle(
        fontSize: 11, fontWeight: FontWeight.w700, color: color)),
  );
}

Widget _barChart(List<int> values, Color color) {
  final maxVal = values.isEmpty ? 1 : values.reduce((a, b) => a > b ? a : b).clamp(1, 999);
  final now = DateTime.now();
  return SizedBox(height: 70, child: Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: List.generate(values.length, (i) {
      final h = (values[i] / maxVal * 44).clamp(2.0, 44.0);
      final isToday = i == values.length - 1;
      final d = DateTime(now.year, now.month, now.day - (values.length - 1 - i));
      return Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
        if (values[i] > 0)
          Text(values[i].toString(), style: TextStyle(fontSize: 8, color: Colors.grey.shade500)),
        const SizedBox(height: 2),
        Container(margin: const EdgeInsets.symmetric(horizontal: 2), height: h,
            decoration: BoxDecoration(
                color: isToday ? color : color.withOpacity(0.4),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(2)))),
        const SizedBox(height: 2),
        Text(isToday ? 'Today' : d.day.toString() + '/' + d.month.toString(),
            style: TextStyle(fontSize: 7, color: Colors.grey.shade600),
            textAlign: TextAlign.center),
      ]));
    }),
  ));
}

// ── Feed panel ────────────────────────────────────────────────────

class _FeedPanel extends StatefulWidget {
  final List<BabyEvent> allEvents;
  final bool isDark;
  const _FeedPanel({required this.allEvents, required this.isDark});
  @override
  State<_FeedPanel> createState() => _FeedPanelState();
}

class _FeedPanelState extends State<_FeedPanel> {
  bool _periodWk = true;

  @override
  Widget build(BuildContext context) {
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final breastFeeds = widget.allEvents.where((e) => e.type == EventType.feed).toList();
    final diapers     = widget.allEvents.where((e) => e.type == EventType.diaper).toList();

    // ── Last 24h stats ───────────────────────────────────────────
    final last24h = now.subtract(const Duration(hours: 24));
    final in24h = breastFeeds.where((e) => e.startTime.isAfter(last24h)).toList();
    var totalMin24h = 0;
    for (final f in in24h) {
      totalMin24h += f.source == 'pump'
          ? (f.mlFed ?? 0) ~/ 3
          : f.duration?.inMinutes ?? 0;
    }
    final count24h = in24h.length;
    final avgSess24h = count24h == 0 ? 0.0 : totalMin24h / count24h;

    // ── 7-day per-day data (oldest first, index 6 = today) ───────
    final days7 = List.generate(7, (i) {
      final day = DateTime(today.year, today.month, today.day - (6 - i));
      final s   = _feedStatsForDay(breastFeeds, day);
      final lbl = i == 6 ? 'Today'
          : '${day.day.toString().padLeft(2, '0')}/${day.month.toString().padLeft(2, '0')}';
      return (label: lbl, totalMin: s.totalMin, dayMin: s.dayMin,
              nightMin: s.nightMin, avgSess: s.avgSession, count: s.count);
    });

    // 7d avg from prior 6 days (for comparison badges)
    final hist6  = days7.take(6).where((d) => d.totalMin > 0).toList();
    final histC  = days7.take(6).where((d) => d.count > 0).toList();
    final histS  = days7.take(6).where((d) => d.avgSess > 0).toList();
    final avg7dTotal   = hist6.isEmpty ? 0.0 : hist6.fold(0.0, (s, d) => s + d.totalMin) / hist6.length;
    final avg7dCount   = histC.isEmpty ? 0.0 : histC.fold(0.0, (s, d) => s + d.count)    / histC.length;
    final avg7dAvgSess = histS.isEmpty ? 0.0 : histS.fold(0.0, (s, d) => s + d.avgSess)  / histS.length;

    // ── 4-week aggregates ────────────────────────────────────────
    final has4wData = widget.allEvents.any(
        (e) => e.startTime.isBefore(now.subtract(const Duration(days: 14))));
    final weeks4 = <({String label, int totalMin, int dayMin, int nightMin, double avgSess, int count})>[];
    for (int wi = 3; wi >= 0; wi--) {
      final wkStart = today.subtract(Duration(days: (wi + 1) * 7));
      var sumT = 0, sumD = 0, sumN = 0, dwd = 0, sumC = 0;
      var sumAvg = 0.0;
      for (int di = 0; di < 7; di++) {
        final s = _feedStatsForDay(breastFeeds, wkStart.add(Duration(days: di)));
        if (s.count > 0) {
          sumT += s.totalMin; sumD += s.dayMin; sumN += s.nightMin;
          sumAvg += s.avgSession; dwd++; sumC += s.count;
        }
      }
      weeks4.add((
        label: wi == 0 ? 'This w' : '${wi + 1}w ago',
        totalMin: dwd > 0 ? sumT ~/ dwd : 0,
        dayMin:   dwd > 0 ? sumD ~/ dwd : 0,
        nightMin: dwd > 0 ? sumN ~/ dwd : 0,
        avgSess:  dwd > 0 ? sumAvg / dwd : 0.0,
        count:    dwd > 0 ? sumC ~/ dwd : 0,
      ));
    }

    // ── Avg gap from allEvents (for toggle) ──────────────────────
    final from7d  = now.subtract(const Duration(days: 7));
    final from14d = now.subtract(const Duration(days: 14));
    final from28d = now.subtract(const Duration(days: 28));
    final gapDay7d       = _computeGapMins(breastFeeds, from7d,  true);
    final gapNight7d     = _computeGapMins(breastFeeds, from7d,  false);
    final gapDay7dPrev   = _computeGapMins(breastFeeds, from14d, true,  to: from7d);
    final gapNight7dPrev = _computeGapMins(breastFeeds, from14d, false, to: from7d);
    // 4w: compare recent 2w (last 14d) vs prior 2w (14–28d ago)
    final gapDay28d      = _computeGapMins(breastFeeds, from28d, true);
    final gapNight28d    = _computeGapMins(breastFeeds, from28d, false);
    final gapDay28dPrev  = _computeGapMins(breastFeeds, from28d, true,  to: from14d);
    final gapNight28dPrev = _computeGapMins(breastFeeds, from28d, false, to: from14d);
    final gapDay    = _periodWk ? gapDay7d    : gapDay28d;
    final gapNight  = _periodWk ? gapNight7d  : gapNight28d;
    final gapDayPrev   = _periodWk ? gapDay7dPrev   : gapDay28dPrev;
    final gapNightPrev = _periodWk ? gapNight7dPrev : gapNight28dPrev;

    // ── Wet diapers today ────────────────────────────────────────
    final wetCount = _wetDiaperCount(diapers, today);

    // ── Chart datasets ───────────────────────────────────────────
    final active  = _periodWk ? days7 : weeks4;
    final durData = active.map((d) => (label: d.label, minutes: d.totalMin)).toList();
    final periodLabel = _periodWk ? '7d' : '4w';

    // ── Display strings ──────────────────────────────────────────
    final totalStr   = totalMin24h > 0 ? _fmtMinsLong(totalMin24h) : '--';
    final avgSessStr = avgSess24h  > 0 ? _fmtMinsLong(avgSess24h)  : '--';
    final countStr   = count24h > 0 ? count24h.toString() : '--';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Last 24h stat grid ────────────────────────────────────
        Row(children: [
          Expanded(child: _subHeader('LAST 24 HOURS')),
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text('↑↓ vs 6-day avg',
                style: TextStyle(fontSize: 9, color: Colors.grey.shade500,
                    fontStyle: FontStyle.italic)),
          ),
        ]),
        IntrinsicHeight(
          child: Row(children: [
            Expanded(child: _StatBox(
              value: totalStr, label: 'Total intake',
              color: _kOrange, secondary: false,
              badge: _badge(totalMin24h.toDouble(), avg7dTotal),
            )),
            const SizedBox(width: 6),
            Expanded(child: _StatBox(
              value: avgSessStr, label: 'Avg session',
              color: _kOrange, secondary: false,
              badge: _badge(avgSess24h, avg7dAvgSess),
            )),
            const SizedBox(width: 6),
            Expanded(child: _StatBox(
              value: countStr, label: 'Feeds',
              color: _kOrange, secondary: false,
              badge: _badge(count24h.toDouble(), avg7dCount),
            )),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 3, left: 2),
          child: Text('Breast + pumped milk · 90 ml = 30 min',
              style: TextStyle(fontSize: 9, color: Colors.grey.shade500, fontStyle: FontStyle.italic)),
        ),

        // ── Trends header + toggle ─────────────────────────────────
        Row(children: [
          Expanded(child: _subHeader('DURATION TRENDS')),
          if (has4wData) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SegmentedButton<bool>(
              selected: {_periodWk},
              segments: const [
                ButtonSegment(value: true, label: Text('7 days')),
                ButtonSegment(value: false, label: Text('4 weeks')),
              ],
              onSelectionChanged: (s) => setState(() => _periodWk = s.first),
              showSelectedIcon: false,
              style: ButtonStyle(
                padding: WidgetStateProperty.all(
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 0)),
                minimumSize: WidgetStateProperty.all(const Size(0, 28)),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
              ),
            ),
          ),
        ]),

        // ── Avg feed gap (first in trends, follows toggle) ────────
        if (gapDay > 0 || gapNight > 0) ...[
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: _kIndigo.withOpacity(0.07),
              border: Border.all(color: _kIndigo.withOpacity(0.2)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                _periodWk
                    ? 'Avg gap between feeds · 7d  (prev = prior 7d)'
                    : 'Avg gap between feeds · 4w  (prev = weeks 1–2)',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: Colors.grey.shade500, letterSpacing: 0.5)),
              const SizedBox(height: 8),
              if (gapDay > 0)
                _row('Day (10am–10pm)', _fmtMins(gapDay), 0, 0,
                    avgLabel: gapDayPrev > 0 ? 'prev ${_fmtMins(gapDayPrev)}' : null,
                    extra: gapDayPrev > 0 ? _gapTrendBadge(gapDay, gapDayPrev) : null),
              if (gapNight > 0)
                _row('Night (10pm–10am)', _fmtMins(gapNight), 0, 0,
                    avgLabel: gapNightPrev > 0 ? 'prev ${_fmtMins(gapNightPrev)}' : null,
                    extra: gapNightPrev > 0 ? _gapTrendBadge(gapNight, gapNightPrev) : null),
            ]),
          ),
        ],

        // ── Chart: total intake ───────────────────────────────────
        Text('Total intake', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        const SizedBox(height: 6),
        _DurationBarChart(data: durData, periodLabel: periodLabel),
        const SizedBox(height: 16),

        // ── Wet diaper indicator ──────────────────────────────────
        if (wetCount > 0) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: wetCount >= 6
                  ? _kGreen.withOpacity(0.1)
                  : wetCount >= 4
                      ? _kAmber.withOpacity(0.1)
                      : Colors.grey.withOpacity(0.08),
            ),
            child: Row(children: [
              const Text('💧', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Expanded(child: Text(
                'Wet diapers today: $wetCount'
                    + (wetCount >= 6 ? '  ✓ Good intake signal' : ''),
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w500,
                    color: wetCount >= 6 ? _kGreen
                        : wetCount >= 4 ? _kAmber
                        : Colors.grey.shade500),
              )),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 3, left: 4),
            child: Text('Used by lactation consultants as intake proxy',
                style: TextStyle(
                    fontSize: 10, color: Colors.grey.shade500,
                    fontStyle: FontStyle.italic)),
          ),
        ],
      ]),
    );
  }
}

// ── Feed panel chart sub-widgets ───────────────────────────────────

class _StatBox extends StatelessWidget {
  final String value, label;
  final Color color;
  final bool secondary;
  final Widget? badge;
  const _StatBox(
      {required this.value, required this.label, required this.color, required this.secondary, this.badge});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg     = isDark ? const Color(0xFF1E2130) : Colors.white;
    final border = isDark ? Colors.grey.shade800 : Colors.grey.shade200;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: bg,
        border: Border.all(color: secondary ? border : color.withOpacity(0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            style: TextStyle(
                fontSize: secondary ? 18 : 22,
                fontWeight: FontWeight.bold,
                color: secondary ? Colors.grey.shade500 : color)),
        const SizedBox(height: 3),
        Row(children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade500))),
          if (badge != null) badge!,
        ]),
      ]),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  final double yFromBottom;
  final Color color;
  const _DashedLinePainter({required this.yFromBottom, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height - yFromBottom;
    if (y < 0 || y > size.height) return;
    final paint = Paint()..color = color..strokeWidth = 1;
    const dash = 5.0, gap = 4.0;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(
          Offset(x, y), Offset((x + dash).clamp(0.0, size.width), y), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_DashedLinePainter old) =>
      old.yFromBottom != yFromBottom || old.color != color;
}

class _DurationBarChart extends StatelessWidget {
  final List<({String label, int minutes})> data;
  final String periodLabel;
  const _DurationBarChart({required this.data, required this.periodLabel});

  static const _barAreaH = 80.0;
  static const _maxBarH  = 52.0;

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const SizedBox.shrink();
    final maxV = data
        .map((d) => d.minutes)
        .reduce((a, b) => a > b ? a : b)
        .clamp(1, 99999)
        .toDouble();
    final nonZero = data.where((d) => d.minutes > 0);
    final avgV = nonZero.isEmpty
        ? 0.0
        : nonZero.fold(0.0, (s, d) => s + d.minutes) / nonZero.length;

    return Column(children: [
      SizedBox(
        height: _barAreaH,
        child: Stack(children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: data.asMap().entries.map((entry) {
              final isLast = entry.key == data.length - 1;
              final d = entry.value;
              final barH = d.minutes > 0
                  ? (d.minutes / maxV * _maxBarH).clamp(2.0, _maxBarH)
                  : 0.0;
              return Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (d.minutes > 0)
                    Text(_fmtMins(d.minutes),
                        style: TextStyle(fontSize: 9, color: isLast ? _kOrange : Colors.grey.shade400,
                            fontWeight: isLast ? FontWeight.w600 : FontWeight.normal)),
                  const SizedBox(height: 2),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    height: barH,
                    decoration: BoxDecoration(
                      color: isLast ? _kOrange : _kOrange.withOpacity(0.4),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                    ),
                  ),
                  const SizedBox(height: 2),
                ]),
              );
            }).toList(),
          ),
          if (avgV > 0)
            Positioned.fill(
              child: CustomPaint(
                painter: _DashedLinePainter(
                  yFromBottom: avgV / maxV * _maxBarH + 2,
                  color: _kOrange.withOpacity(0.55),
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 2),
      Row(
        children: data.map((d) => Expanded(
          child: Text(d.label,
              style: TextStyle(fontSize: 7, color: Colors.grey.shade600),
              textAlign: TextAlign.center),
        )).toList(),
      ),
      if (avgV > 0) ...[
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          CustomPaint(
            size: const Size(18, 10),
            painter: _DashedLinePainter(yFromBottom: 5, color: _kOrange.withOpacity(0.55)),
          ),
          const SizedBox(width: 5),
          Text('$periodLabel avg (${_fmtMins(avgV)})',
              style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
        ]),
      ],
    ]);
  }
}

// ── Diaper panel ──────────────────────────────────────────────────

class _DiaperPanel extends StatelessWidget {
  final List<BabyEvent> allEvents;
  final bool isDark;
  const _DiaperPanel({required this.allEvents, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final diapers = allEvents.where((e) => e.type == EventType.diaper).toList();
    final last24h = now.subtract(const Duration(hours: 24));
    final five = now.subtract(const Duration(days: 5));
    final d24h = diapers.where((e) => e.startTime.isAfter(last24h)).toList();
    final d5d  = diapers.where((e) => e.startTime.isAfter(five)).toList();
    final count24h  = d24h.length;
    final pee24h    = d24h.where((e) => e.pee).length;
    final poop24h   = d24h.where((e) => e.poop).length;
    final avg5d     = d5d.isEmpty ? 0.0 : d5d.length / 5.0;
    final avgPee5d  = d5d.isEmpty ? 0.0 : d5d.where((e) => e.pee).length / 5.0;
    final avgPoop5d = d5d.isEmpty ? 0.0 : d5d.where((e) => e.poop).length / 5.0;
    final daily7List = List<int>.filled(7, 0);
    for (int di = 0; di < 7; di++) {
      final s = DateTime(now.year, now.month, now.day - di);
      final e = DateTime(now.year, now.month, now.day - di + 1);
      daily7List[6 - di] = diapers.where((ev) => !ev.startTime.isBefore(s) && ev.startTime.isBefore(e)).length;
    }
    final daily7 = daily7List;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _subHeader('LAST 24H vs 5-DAY AVG'),
        _row('Total changes', count24h.toString(), count24h.toDouble(), avg5d,
            avgLabel: 'avg ' + avg5d.toStringAsFixed(1)),
        _row('Pee', pee24h.toString(), pee24h.toDouble(), avgPee5d,
            avgLabel: 'avg ' + avgPee5d.toStringAsFixed(1)),
        _row('Poop', poop24h.toString(), poop24h.toDouble(), avgPoop5d,
            avgLabel: 'avg ' + avgPoop5d.toStringAsFixed(1)),
        _subHeader('7-DAY TREND'),
        _barChart(daily7, kDiaperColor2),
      ]),
    );
  }
}
