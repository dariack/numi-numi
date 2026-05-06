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
      e.source != 'pump' &&
      !e.startTime.isBefore(wStart) &&
      e.startTime.isBefore(wEnd)).toList();
  var totalMin = 0, dayMin = 0, nightMin = 0;
  for (final f in inWin) {
    final dur = f.duration?.inMinutes ?? 0;
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
  Map<String, dynamic>? _feedData;
  Map<String, dynamic>? _diaperData;
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
    final results = await Future.wait([
      widget.service.getFeedInsights(),
      _loadDiaperData(),
      widget.service.getRecentEvents(days: 28),
    ]);
    if (!mounted) return;
    setState(() {
      _feedData   = results[0] as Map<String, dynamic>;
      _diaperData = results[1] as Map<String, dynamic>;
      _allEvents  = results[2] as List<BabyEvent>;
      _loading = false;
    });
  }

  Future<Map<String, dynamic>> _loadDiaperData() async {
    final events = await widget.service.eventsByTypeStream(EventType.diaper, limit: 200).first;
    final now = DateTime.now();
    final last24h = now.subtract(const Duration(hours: 24));
    final five = now.subtract(const Duration(days: 5));
    final d24h = events.where((e) => e.startTime.isAfter(last24h)).toList();
    final d5d  = events.where((e) => e.startTime.isAfter(five)).toList();
    final daily = List<int>.filled(7, 0);
    for (int di = 0; di < 7; di++) {
      final s = DateTime(now.year, now.month, now.day - di);
      final e = DateTime(now.year, now.month, now.day - di + 1);
      daily[6 - di] = events.where((ev) => !ev.startTime.isBefore(s) && ev.startTime.isBefore(e)).length;
    }
    return {
      'count24h': d24h.length,
      'pee24h': d24h.where((e) => e.pee).length,
      'poop24h': d24h.where((e) => e.poop).length,
      'avg5d': d5d.isEmpty ? 0.0 : d5d.length / 5.0,
      'avgPee5d': d5d.isEmpty ? 0.0 : d5d.where((e) => e.pee).length / 5.0,
      'avgPoop5d': d5d.isEmpty ? 0.0 : d5d.where((e) => e.poop).length / 5.0,
      'daily7': daily,
    };
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
                child: _FeedPanel(data: _feedData!, allEvents: _allEvents, isDark: isDark),
              ),
            ),
            RefreshIndicator(
              onRefresh: _load,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: _DiaperPanel(data: _diaperData!, isDark: isDark),
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
  if (mins >= 60) return (mins ~/ 60).toString() + 'h ' + (mins % 60).toString() + 'm';
  return mins.toString() + 'm';
}

String _fmtDate(DateTime d) {
  return d.day.toString().padLeft(2, "0") + '/' +
      d.month.toString().padLeft(2, "0") + ' ' +
      d.hour.toString().padLeft(2, "0") + ':' +
      d.minute.toString().padLeft(2, "0");
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
  final Map<String, dynamic> data;
  final List<BabyEvent> allEvents;
  final bool isDark;
  const _FeedPanel({required this.data, required this.allEvents, required this.isDark});
  @override
  State<_FeedPanel> createState() => _FeedPanelState();
}

class _FeedPanelState extends State<_FeedPanel> {
  bool _periodWk = true;

  @override
  Widget build(BuildContext context) {
    final avgGapDay       = widget.data['avgGapDay']       as double;
    final avgGapNight     = widget.data['avgGapNight']     as double;
    final avgGapDayPrev   = widget.data['avgGapDayPrev']   as double? ?? 0;
    final avgGapNightPrev = widget.data['avgGapNightPrev'] as double? ?? 0;

    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final breastFeeds = widget.allEvents.where((e) => e.type == EventType.feed).toList();
    final diapers     = widget.allEvents.where((e) => e.type == EventType.diaper).toList();

    // Today's stats
    final todayStats = _feedStatsForDay(breastFeeds, today);

    // 7-day per-day data (oldest first)
    final days7 = List.generate(7, (i) {
      final day = DateTime(today.year, today.month, today.day - (6 - i));
      final s   = _feedStatsForDay(breastFeeds, day);
      final lbl = i == 6 ? 'Today'
          : day.day.toString().padLeft(2, '0') + '/' + day.month.toString().padLeft(2, '0');
      return (label: lbl, totalMin: s.totalMin, dayMin: s.dayMin, nightMin: s.nightMin, avgSess: s.avgSession);
    });

    // 4-week data availability
    final has4wData = widget.allEvents.any(
        (e) => e.startTime.isBefore(now.subtract(const Duration(days: 14))));

    // 4-week aggregates (weekly avg across days with data)
    final weeks4 = <({String label, int totalMin, int dayMin, int nightMin, double avgSess})>[];
    for (int wi = 3; wi >= 0; wi--) {
      final wkStart = today.subtract(Duration(days: (wi + 1) * 7));
      var sumT = 0, sumD = 0, sumN = 0, dwd = 0;
      var sumAvg = 0.0;
      for (int di = 0; di < 7; di++) {
        final s = _feedStatsForDay(breastFeeds, wkStart.add(Duration(days: di)));
        if (s.count > 0) {
          sumT += s.totalMin; sumD += s.dayMin; sumN += s.nightMin;
          sumAvg += s.avgSession; dwd++;
        }
      }
      weeks4.add((
        label: wi == 0 ? 'This w' : '${wi + 1}w ago',
        totalMin: dwd > 0 ? sumT ~/ dwd : 0,
        dayMin:   dwd > 0 ? sumD ~/ dwd : 0,
        nightMin: dwd > 0 ? sumN ~/ dwd : 0,
        avgSess:  dwd > 0 ? sumAvg / dwd : 0.0,
      ));
    }

    // Wet diapers today
    final wetCount = _wetDiaperCount(diapers, today);

    // Chart datasets based on period toggle
    final active = _periodWk ? days7 : weeks4;
    final durData     = active.map((d) => (label: d.label, minutes: d.totalMin)).toList();
    final dnData      = active.map((d) => (label: d.label, dayMin: d.dayMin, nightMin: d.nightMin)).toList();
    final avgSessData = active.map((d) => (label: d.label, val: d.avgSess)).toList();

    // Stat card display values
    final totalTodayStr = todayStats.totalMin > 0 ? _fmtMins(todayStats.totalMin) : '--';
    final avgSessStr    = todayStats.avgSession > 0 ? _fmtMins(todayStats.avgSession) : '--';
    final dayPct = todayStats.totalMin > 0
        ? (todayStats.dayMin * 100 / todayStats.totalMin).round().toString() + '% day'
        : '--';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── 2×2 stat grid ─────────────────────────────────────────
        _subHeader('TODAY'),
        Row(children: [
          Expanded(child: _StatBox(value: totalTodayStr, label: 'Total today', color: _kOrange, secondary: false)),
          const SizedBox(width: 8),
          Expanded(child: _StatBox(value: avgSessStr, label: 'Avg session', color: _kOrange, secondary: false)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _StatBox(value: dayPct, label: 'Day / Night', color: _kIndigo, secondary: false)),
          const SizedBox(width: 8),
          Expanded(child: _StatBox(
            value: todayStats.count > 0 ? todayStats.count.toString() : '--',
            label: 'Feeds today',
            color: Colors.grey,
            secondary: true,
          )),
        ]),

        // ── Charts with single toggle ──────────────────────────────
        Row(children: [
          Expanded(child: _subHeader('DURATION TRENDS')),
          if (has4wData) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SegmentedButton<bool>(
              selected: {_periodWk},
              segments: const [
                ButtonSegment(value: true, label: Text('7d')),
                ButtonSegment(value: false, label: Text('4w')),
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

        // Chart 1: total breast time per day
        Text('Total breast time', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        const SizedBox(height: 6),
        _DurationBarChart(data: durData),
        const SizedBox(height: 16),

        // Chart 2: day vs night
        Text('Day vs night', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        const SizedBox(height: 6),
        _DualLineChart(data: dnData),
        const SizedBox(height: 16),

        // Chart 3: avg session length
        Text('Avg session length', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        const SizedBox(height: 6),
        _AvgSessionChart(data: avgSessData),

        // ── Feed gap section ──────────────────────────────────────
        if (avgGapDay > 0 || avgGapNight > 0) ...[
          _subHeader('AVG FEED GAP (5D AVG)'),
          if (avgGapDay > 0)
            _row('Day (10am-10pm)', _fmtMins(avgGapDay), 0, 0,
                avgLabel: avgGapDayPrev > 0 ? 'prev ' + _fmtMins(avgGapDayPrev) : null,
                extra: _gapTrendBadge(avgGapDay, avgGapDayPrev)),
          if (avgGapNight > 0)
            _row('Night (10pm-10am)', _fmtMins(avgGapNight), 0, 0,
                avgLabel: avgGapNightPrev > 0 ? 'prev ' + _fmtMins(avgGapNightPrev) : null,
                extra: _gapTrendBadge(avgGapNight, avgGapNightPrev)),
        ],

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
  const _StatBox(
      {required this.value, required this.label, required this.color, required this.secondary});

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
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
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
  const _DurationBarChart({required this.data});

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
    final avgV = data.fold(0.0, (s, d) => s + d.minutes) / data.length;

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
                        style: TextStyle(fontSize: 7, color: Colors.grey.shade500)),
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
          Positioned.fill(
            child: CustomPaint(
              painter: _DashedLinePainter(
                yFromBottom: avgV > 0 ? (avgV / maxV * _maxBarH + 2) : -1,
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
    ]);
  }
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

    if (vals2 != null) { drawLine(vals2!, color2 ?? Colors.grey); }
    drawLine(vals1, color1);
  }

  @override
  bool shouldRepaint(_LinePainter old) => true;
}

class _DualLineChart extends StatelessWidget {
  final List<({String label, int dayMin, int nightMin})> data;
  const _DualLineChart({required this.data});

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const SizedBox.shrink();
    return Column(children: [
      SizedBox(
        height: 90,
        child: CustomPaint(
          painter: _LinePainter(
            vals1: data.map((d) => d.dayMin.toDouble()).toList(),
            color1: _kOrange,
            vals2: data.map((d) => d.nightMin.toDouble()).toList(),
            color2: _kIndigo,
          ),
          child: const SizedBox.expand(),
        ),
      ),
      const SizedBox(height: 2),
      Row(
        children: data.map((d) => Expanded(
          child: Text(d.label,
              style: TextStyle(fontSize: 7, color: Colors.grey.shade600),
              textAlign: TextAlign.center),
        )).toList(),
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

class _AvgSessionChart extends StatelessWidget {
  final List<({String label, double val})> data;
  const _AvgSessionChart({required this.data});

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const SizedBox.shrink();
    return Column(children: [
      SizedBox(
        height: 80,
        child: CustomPaint(
          painter: _LinePainter(
            vals1: data.map((d) => d.val).toList(),
            color1: _kOrange,
          ),
          child: const SizedBox.expand(),
        ),
      ),
      const SizedBox(height: 2),
      Row(
        children: data.map((d) => Expanded(
          child: Text(d.label,
              style: TextStyle(fontSize: 7, color: Colors.grey.shade600),
              textAlign: TextAlign.center),
        )).toList(),
      ),
    ]);
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(
        width: 8, height: 8,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
    const SizedBox(width: 4),
    Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
  ]);
}

// ── Diaper panel ──────────────────────────────────────────────────

class _DiaperPanel extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isDark;
  const _DiaperPanel({required this.data, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final count24h  = data['count24h']  as int;
    final pee24h    = data['pee24h']    as int;
    final poop24h   = data['poop24h']   as int;
    final avg5d     = data['avg5d']     as double;
    final avgPee5d  = data['avgPee5d']  as double;
    final avgPoop5d = data['avgPoop5d'] as double;
    final daily7    = data['daily7']    as List<int>;

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
