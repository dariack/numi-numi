import 'package:flutter/material.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';

const kFeedColor2  = Colors.orange;
const kDiaperColor2 = Colors.teal;
const kPumpColor2   = Color(0xFFF472B6);
const _kGreen  = Color(0xFF22c55e);
const _kRed    = Color(0xFFef4444);
const _kAmber  = Color(0xFFf59e0b);

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
    ]);
    if (!mounted) return;
    setState(() {
      _feedData   = results[0] as Map<String, dynamic>;
      _diaperData = results[1] as Map<String, dynamic>;
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
                child: _FeedPanel(data: _feedData!, isDark: isDark),
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

// ── Shared helpers ───────────────────────────────────────────────

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
      fontSize: 11, fontWeight: FontWeight.w700,
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

// Trend badge: shows delta in minutes vs previous period (positive = gap got longer)
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

// ── Feed panel ───────────────────────────────────────────────────

class _FeedPanel extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isDark;
  const _FeedPanel({required this.data, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final equiv24h       = data['equiv24h']        as double;
    final avg5d          = data['avg5dEquiv']       as double;
    final dur24h         = data['dur24h']           as int;
    final ml24h          = data['ml24h']            as int;
    final avgDuration    = data['avgDuration']      as double;
    final avgGapDay      = data['avgGapDay']        as double;
    final avgGapNight    = data['avgGapNight']      as double;
    final avgGapDayPrev  = data['avgGapDayPrev']    as double? ?? 0;
    final avgGapNightPrev= data['avgGapNightPrev']  as double? ?? 0;

    // Estimate feed count
    final estCount24h = avgDuration > 0 ? (dur24h / avgDuration).round()
        : equiv24h > 0 ? (equiv24h / 30).round() : 0;
    final estAvgCount = avgDuration > 0
        ? avg5d / avgDuration
        : avg5d > 0 ? avg5d / 30.0 : 0.0;
    final avgBreastTotal = avgDuration > 0 ? avgDuration * estAvgCount : 0.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _subHeader('LAST 24H vs 5-DAY AVG'),
        _row('Total intake', _fmtMins(equiv24h), equiv24h, avg5d,
            avgLabel: 'avg ' + _fmtMins(avg5d)),
        if (estCount24h > 0)
          _row('Sessions', estCount24h.toString(), estCount24h.toDouble(), estAvgCount,
              avgLabel: 'avg ' + estAvgCount.toStringAsFixed(1)),
        if (dur24h > 0)
          _row('Breast time', _fmtMins(dur24h), dur24h.toDouble(), avgBreastTotal,
              avgLabel: avgBreastTotal > 0 ? 'avg ' + _fmtMins(avgBreastTotal) : null),
        if (ml24h > 0)
          _row('Pumped fed', ml24h.toString() + 'ml', 0, 0),
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
      ]),
    );
  }
}

// ── Diaper panel ─────────────────────────────────────────────────

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

// ── Pump panel ───────────────────────────────────────────────────

class _PumpPanel extends StatefulWidget {
  final Map<String, dynamic> data;
  final FirestoreService service;
  final bool isDark;
  const _PumpPanel({required this.data, required this.service, required this.isDark});
  @override
  State<_PumpPanel> createState() => _PumpPanelState();
}

class _PumpPanelState extends State<_PumpPanel> {
  List<Map<String, dynamic>> _stock = [];
  bool _stockLoading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final s = await widget.service.getAvailableStock();
    if (mounted) setState(() { _stock = s; _stockLoading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final avgPumped  = widget.data['avgPumpedPerDay'] as double;
    final avgUsed    = widget.data['avgUsedPerDay']   as double;
    final recentUsage = widget.data['recentUsage'] as List;
    final twoDaysAgo = DateTime.now().subtract(const Duration(days: 2));
    const storageEmoji = {'room': '🏠', 'fridge': '❄️', 'freezer': '🧊'};
    const storageOrder = ['room', 'fridge', 'freezer'];

    // Cumulative ml by storage
    final storageMap = <String, int>{};
    final bottleCount = <String, int>{};
    for (final u in _stock) {
      final p = u['event'] as BabyEvent;
      final storage = p.storage ?? 'room';
      storageMap[storage] = (storageMap[storage] ?? 0) + (u['remaining'] as int);
      bottleCount[storage] = (bottleCount[storage] ?? 0) + 1;
    }

    // Stock items sorted newest first
    final sorted = [..._stock]..sort((a, b) =>
        (b['event'] as BabyEvent).startTime.compareTo((a['event'] as BabyEvent).startTime));

    // Fully used in last 2 days
    final fullyUsed = recentUsage.where((u) =>
        (u['fullyUsed'] as bool) &&
        (u['pumpedAt'] as DateTime).isAfter(twoDaysAgo)).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // Avgs at top
        _subHeader('5-DAY AVERAGES'),
        Row(children: [
          _Pill(label: 'Pumped/day',
              value: avgPumped >= 0 ? avgPumped.round().toString() + 'ml' : '0ml',
              color: kPumpColor2),
          const SizedBox(width: 10),
          _Pill(label: 'Used/day',
              value: avgUsed >= 0 ? avgUsed.round().toString() + 'ml' : '0ml',
              color: Colors.orange),
        ]),

        // Cumulative stock
        _subHeader('STOCK'),
        if (_stockLoading)
          const SizedBox(height: 24, child: CircularProgressIndicator(strokeWidth: 2))
        else if (storageMap.isEmpty)
          Text('No stock', style: TextStyle(fontSize: 13, color: Colors.grey.shade500))
        else ...[
          ...storageOrder.where((s) => storageMap.containsKey(s)).map((s) {
            final bc = bottleCount[s] ?? 0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                Text(storageEmoji[s] ?? '', style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 6),
                Text(storageMap[s].toString() + 'ml',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(width: 6),
                Text('(' + bc.toString() + ' bottle' + (bc == 1 ? '' : 's') + ')',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              ]),
            );
          }),
          const SizedBox(height: 6),
          // Individual bottles
          ...sorted.map((u) {
            final p = u['event'] as BabyEvent;
            final rem = u['remaining'] as int;
            final used = u['used'] as int;
            final isPartial = used > 0;
            final id = p.pumpId ?? '—';
            final emoji = storageEmoji[p.storage ?? 'room'] ?? '🏠';
            return Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(children: [
                Text(emoji + ' #' + id,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                const SizedBox(width: 6),
                Text(rem.toString() + 'ml',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                if (isPartial) ...[
                  const SizedBox(width: 4),
                  Text('(' + used.toString() + 'ml used)',
                      style: const TextStyle(fontSize: 11, color: _kAmber)),
                ],
                const Spacer(),
                if (p.expiresAt != null)
                  Text('exp ' + _fmtDate(p.expiresAt!),
                      style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              ]),
            );
          }),
        ],

        // Recently fully used
        if (fullyUsed.isNotEmpty) ...[
          _subHeader('RECENTLY FULLY USED'),
          ...fullyUsed.map((u) {
            final pumpedAt = u['pumpedAt'] as DateTime;
            final pumpedMl = u['pumpedMl'] as int;
            final id = u['pumpId']?.toString() ?? '—';
            final storage = u['storage'] as String? ?? 'room';
            return Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(children: [
                Text((storageEmoji[storage] ?? '') + ' #' + id,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                const SizedBox(width: 6),
                Text(pumpedMl.toString() + 'ml used',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
                const Spacer(),
                Text(_fmtDate(pumpedAt),
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              ]),
            );
          }),
        ],
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label, value;
  final Color color;
  const _Pill({required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: color.withOpacity(0.1),
        border: Border.all(color: color.withOpacity(0.3))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: TextStyle(
          fontSize: 18, fontWeight: FontWeight.bold, color: color)),
      Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
    ]),
  );
}
