import 'package:flutter/material.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';

const kSleepColor = Color(0xFFa78bfa);
const kFeedColor = Colors.orange;
const kDiaperColor = Colors.teal;
const kPumpColor = Color(0xFFF472B6);

/// Standalone screen for a single action type — used as a bottom nav tab
class ActionTabScreen extends StatelessWidget {
  final FirestoreService service;
  final EventType type;
  const ActionTabScreen({super.key, required this.service, required this.type});

  @override
  Widget build(BuildContext context) {
    switch (type) {
      case EventType.feed:
        return _FeedTab(service: service);
      case EventType.sleep:
        return _SleepTab(service: service);
      case EventType.diaper:
        return _DiaperTab(service: service);
      case EventType.pump:
        return _PumpTab(service: service);
    }
  }
}

// ===== FEED TAB =====
class _FeedTab extends StatefulWidget {
  final FirestoreService service;
  const _FeedTab({required this.service});
  @override
  State<_FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends State<_FeedTab> {
  Map<String, dynamic>? _insights;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final insights = await widget.service.getFeedInsights();
    if (mounted) setState(() { _insights = insights; _loading = false; });
  }

  String _fmt(Duration? d) {
    if (d == null) return '--';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    return '${d.inMinutes}m';
  }

  String _fmtMin(num? m) {
    if (m == null || m <= 0) return '--';
    final mins = m.round();
    if (mins >= 60) return '${mins ~/ 60}h ${mins % 60}m';
    return '${mins}m';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final ins = _insights!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E2130) : Colors.white;

    final dur24h = ins['dur24h'] as int;
    final ml24h = ins['ml24h'] as int;
    final equiv24h = ins['equiv24h'] as double;
    final avg5dEquiv = ins['avg5dEquiv'] as double;
    final avgDuration = ins['avgDuration'] as double;
    final avgGapDay = ins['avgGapDay'] as double;
    final avgGapNight = ins['avgGapNight'] as double;

    final parts24h = <String>[];
    if (dur24h > 0) parts24h.add('${_fmtMin(dur24h)} breast');
    if (ml24h > 0) parts24h.add('${ml24h}ml pumped');
    final str24h = parts24h.isNotEmpty ? parts24h.join(' + ') : 'No feeds yet';

    return RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          // Time since last feed
          _InsightCard(cardBg: cardBg, emoji: '⏱', title: 'Time Since Last Feed',
            value: _fmt(ins['timeSinceLast'] as Duration?), color: kFeedColor),
          const SizedBox(height: 10),

          // Side recommendation
          if (ins['recommendedSide'] != null) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: kFeedColor.withOpacity(0.1),
                border: Border.all(color: kFeedColor, width: 2),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Text('🤱', style: TextStyle(fontSize: 24)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(
                    'Next side: ${(ins['recommendedSide'] as String).toUpperCase()}',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: kFeedColor),
                  )),
                ]),
                const SizedBox(height: 6),
                Text(ins['recommendationReason'] as String,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
              ]),
            ),
            const SizedBox(height: 10),
          ],

          // Last 24h
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: cardBg,
              border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('📊', style: TextStyle(fontSize: 24)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Last 24h', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 4),
                Text(str24h, style: TextStyle(fontSize: 13, color: kFeedColor, fontWeight: FontWeight.w600)),
                if (avg5dEquiv > 0) ...[
                  const SizedBox(height: 4),
                  Text('5-day avg: ~${_fmtMin(avg5dEquiv.round())}/day',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  const SizedBox(height: 4),
                  _buildCompLabel(equiv24h, avg5dEquiv, 'feeding'),
                ],
              ])),
            ]),
          ),
          const SizedBox(height: 10),

          // Avg duration — full width
          _InsightCard(cardBg: cardBg, emoji: '⏱', title: 'Avg Duration',
            value: avgDuration > 0 ? _fmtMin(avgDuration) : '--', color: kFeedColor,
            subtitle: '5-day avg · breast'),
          const SizedBox(height: 10),
          // Avg gaps — side by side
          Row(children: [
            Expanded(child: _InsightCard(cardBg: cardBg, emoji: '☀️', title: 'Avg Gap Day',
              value: avgGapDay > 0 ? _fmtMin(avgGapDay) : '--', color: kFeedColor,
              subtitle: '10am–10pm · 5d avg')),
            const SizedBox(width: 10),
            Expanded(child: _InsightCard(cardBg: cardBg, emoji: '🌙', title: 'Avg Gap Night',
              value: avgGapNight > 0 ? _fmtMin(avgGapNight) : '--', color: kFeedColor,
              subtitle: '10pm–10am · 5d avg')),
          ]),

        ]),
    );
  }

  Widget _buildCompLabel(double current, double avg, String noun) {
    if (avg <= 0) return const SizedBox.shrink();
    final pctDiff = (current - avg) / avg;
    String text;
    Color color;
    if (pctDiff > 0.20) {
      text = '📈 ${(pctDiff * 100).round()}% more $noun than usual';
      color = Colors.orange;
    } else if (pctDiff < -0.20) {
      text = '📉 ${(pctDiff.abs() * 100).round()}% less $noun than usual';
      color = Colors.blue;
    } else {
      text = '✅ About the same as usual';
      color = Colors.green;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: color.withOpacity(0.12)),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

// ===== SLEEP TAB =====
class _SleepTab extends StatelessWidget {
  final FirestoreService service;
  const _SleepTab({required this.service});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('See History tab for full sleep log', style: TextStyle(color: Colors.grey)));
  }
}

// ===== DIAPER TAB =====
class _DiaperTab extends StatefulWidget {
  final FirestoreService service;
  const _DiaperTab({required this.service});
  @override
  State<_DiaperTab> createState() => _DiaperTabState();
}

class _DiaperTabState extends State<_DiaperTab> {
  bool _loading = true;
  int _todayCount = 0;
  double _avg3d = 0;
  Map<String, double> _periodAvgs = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final snap = await widget.service.eventsByTypeStream(EventType.diaper, limit: 200).first;
    final now = DateTime.now();
    final last24h = now.subtract(const Duration(hours: 24));
    final fiveDaysAgo = now.subtract(const Duration(days: 5));

    final count24h = snap.where((e) => e.startTime.isAfter(last24h)).length;
    final d5d = snap.where((e) => e.startTime.isAfter(fiveDaysAgo)).toList();
    final avg5d = d5d.isEmpty ? 0.0 : d5d.length / 5.0;

    String periodName(DateTime dt) {
      final h = dt.hour;
      if (h >= 22 || h < 10) return 'Night';
      if (h >= 6 && h < 12) return 'Morning';
      if (h >= 12 && h < 18) return 'Afternoon';
      return 'Evening';
    }

    final periodAvgs = <String, double>{};
    for (final p in ['Night', 'Morning', 'Afternoon', 'Evening']) {
      final count = d5d.where((e) => periodName(e.startTime) == p).length;
      periodAvgs[p] = count / 5.0;
    }

    if (mounted) setState(() {
      _todayCount = count24h;
      _avg3d = avg5d;
      _periodAvgs = periodAvgs;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E2130) : Colors.white;

    // Comparison label
    Widget compChip = const SizedBox.shrink();
    if (_avg3d > 0) {
      final pct = (_todayCount - _avg3d) / _avg3d;
      String text; Color color;
      if (pct > 0.20) { text = '📈 ${(pct * 100).round()}% more than usual'; color = Colors.orange; }
      else if (pct < -0.20) { text = '📉 ${(pct.abs() * 100).round()}% less than usual'; color = Colors.blue; }
      else { text = '✅ About the same as usual'; color = Colors.green; }
      compChip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: color.withOpacity(0.12)),
        child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
      );
    }

    final periodEmoji = {'Night': '🌙', 'Morning': '🌅', 'Afternoon': '☀️', 'Evening': '🌇'};

    return RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          // Today count vs avg
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: cardBg,
              border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('📊', style: TextStyle(fontSize: 24)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Last 24h', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 4),
                Text('$_todayCount diapers', style: TextStyle(fontSize: 13, color: kDiaperColor, fontWeight: FontWeight.w600)),
                if (_avg3d > 0) ...[
                  const SizedBox(height: 4),
                  Text('5-day avg: ${_avg3d.toStringAsFixed(1)}/day', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  const SizedBox(height: 4),
                  compChip,
                ],
              ])),
            ]),
          ),
          const SizedBox(height: 10),

          // 3-day avg per period
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: cardBg,
              border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('5-Day Avg by Period', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 8),
              ..._periodAvgs.entries.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  Text(periodEmoji[e.key] ?? '', style: const TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                  Text(e.key, style: const TextStyle(fontSize: 13)),
                  const Spacer(),
                  Text('${e.value.toStringAsFixed(1)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: kDiaperColor)),
                ]),
              )),
            ]),
          ),


        ]),
    );
  }
}

// ===== PUMP TAB =====
class _PumpTab extends StatefulWidget {
  final FirestoreService service;
  const _PumpTab({required this.service});
  @override
  State<_PumpTab> createState() => _PumpTabState();
}

class _PumpTabState extends State<_PumpTab> {
  Map<String, List<Map<String, dynamic>>> _stock = {};
  Map<String, dynamic> _pumpStats = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      widget.service.getStockByStorage(),
      widget.service.getPumpStats(),
    ]);
    if (mounted) setState(() {
      _stock = results[0] as Map<String, List<Map<String, dynamic>>>;
      _pumpStats = results[1] as Map<String, dynamic>;
      _loading = false;
    });
  }

  String _fmtTime(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E2130) : Colors.white;

    final avgPumped = _pumpStats['avgPumpedPerDay'] as double? ?? 0;
    final avgUsed = _pumpStats['avgUsedPerDay'] as double? ?? 0;
    final recentUsage = _pumpStats['recentUsage'] as List<Map<String, dynamic>>? ?? [];

    return RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(16), children: [

          // 5-day avg stats
          Text('5-Day Averages', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
              color: Colors.grey.shade500, letterSpacing: 0.5)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _InsightCard(cardBg: cardBg, emoji: '🥛', title: 'Avg Pumped',
              value: avgPumped > 0 ? '${avgPumped.round()}ml' : '--',
              color: kPumpColor, subtitle: 'per day · 5d avg')),
            const SizedBox(width: 10),
            Expanded(child: _InsightCard(cardBg: cardBg, emoji: '🍼', title: 'Avg Used',
              value: avgUsed > 0 ? '${avgUsed.round()}ml' : '--',
              color: kPumpColor, subtitle: 'per day · 5d avg')),
          ]),
          const SizedBox(height: 20),

          // Stock overview
          Text('Stock Overview', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
              color: Colors.grey.shade500, letterSpacing: 0.5)),
          const SizedBox(height: 8),
          _stockSection(cardBg, '🏠 Room Temp', 'Lasts 4h', _stock['room'] ?? []),
          const SizedBox(height: 8),
          _stockSection(cardBg, '❄️ Fridge', 'Lasts 4 days', _stock['fridge'] ?? []),
          const SizedBox(height: 8),
          _stockSection(cardBg, '🧊 Freezer', 'Lasts 6 months', _stock['freezer'] ?? []),
          const SizedBox(height: 20),

          // Recent pump milk usage (last 3 days)
          Text('Recently Used (last 3 days)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
              color: Colors.grey.shade500, letterSpacing: 0.5)),
          const SizedBox(height: 8),
          if (recentUsage.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('No pump milk used in the last 3 days',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            )
          else
            Container(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: cardBg,
                border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200)),
              child: Column(children: recentUsage.asMap().entries.map((entry) {
                final i = entry.key;
                final u = entry.value;
                final feedTime = u['feedTime'] as DateTime;
                final mlUsed = u['mlUsed'] as int;
                final pumpId = u['pumpId'] as String?;
                final idStr = pumpId != null ? '#$pumpId' : '—';
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    border: i < recentUsage.length - 1
                        ? Border(bottom: BorderSide(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200))
                        : null,
                  ),
                  child: Row(children: [
                    Text(_fmtTime(feedTime),
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 12),
                    Expanded(child: Text(idStr,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                    Text('${mlUsed}ml used',
                        style: TextStyle(fontSize: 13, color: kPumpColor, fontWeight: FontWeight.w600)),
                  ]),
                );
              }).toList()),
            ),
        ]),
    );
  }

  Widget _stockSection(Color cardBg, String title, String subtitle, List<Map<String, dynamic>> items) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final totalMl = items.fold<int>(0, (s, i) => s + (i['remaining'] as int));
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12), color: cardBg,
        border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(width: 8),
          Text('($subtitle)', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        ]),
        const SizedBox(height: 6),
        if (items.isEmpty)
          Text('No milk available', style: TextStyle(fontSize: 13, color: Colors.grey.shade500))
        else
          ...items.map((i) {
            final p = i['event'] as BabyEvent;
            final rem = i['remaining'] as int;
            final idStr = p.pumpId != null ? '#${p.pumpId}' : '—';
            final pumped = '${p.startTime.day.toString().padLeft(2,'0')}/${p.startTime.month.toString().padLeft(2,'0')} ${p.startTime.hour.toString().padLeft(2,'0')}:${p.startTime.minute.toString().padLeft(2,'0')}';
            final exp = p.expiresAt != null
                ? ' · expires: ${p.expiresAt!.day.toString().padLeft(2,'0')}/${p.expiresAt!.month.toString().padLeft(2,'0')} ${p.expiresAt!.hour.toString().padLeft(2,'0')}:${p.expiresAt!.minute.toString().padLeft(2,'0')}'
                : '';
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('$idStr · pumped: $pumped · ${rem}ml$exp',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
            );
          }),
      ]),
    );
  }
}

// ===== SHARED: EVENT HISTORY =====
class _EventHistory extends StatelessWidget {
  final FirestoreService service;
  final EventType type;
  const _EventHistory({required this.service, required this.type});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<BabyEvent>>(
      stream: service.eventsByTypeStream(type, limit: 50),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
        }
        final events = snapshot.data ?? [];
        if (events.isEmpty) {
          return Padding(padding: const EdgeInsets.all(20),
            child: Center(child: Text('No events', style: TextStyle(color: Colors.grey.shade500))));
        }
        return Column(
          children: events.take(30).map((e) {
            final time = '${e.startTime.hour.toString().padLeft(2, '0')}:${e.startTime.minute.toString().padLeft(2, '0')}';
            final date = '${e.startTime.day}/${e.startTime.month}';
            final props = <String>[];
            if (e.duration != null) props.add(e.durationText);
            if (e.side != null) props.add(e.side!);
            if (e.isOngoing) props.add('ongoing');
            if (e.source == 'pump') props.add('pumped milk');
            if (e.mlFed != null) props.add('${e.mlFed}ml');
            if (e.type == EventType.pump) {
              if (e.ml != null) props.add('${e.ml}ml');
              if (e.storage != null) props.add(e.storage!);
              if (e.spoiled) props.add('⚠️ spoiled');
            }
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: SizedBox(width: 52, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(time, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade400)),
                Text(date, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ])),
              title: Text(e.displayName, style: const TextStyle(fontSize: 14)),
              subtitle: props.isNotEmpty
                  ? Text(props.join(' · '), style: TextStyle(fontSize: 12, color: Colors.grey.shade500))
                  : null,
            );
          }).toList(),
        );
      },
    );
  }
}

// ===== INSIGHT CARD =====
class _InsightCard extends StatelessWidget {
  final Color cardBg;
  final String emoji;
  final String title;
  final String value;
  final String? subtitle;
  final Color color;
  const _InsightCard({required this.cardBg, required this.emoji, required this.title,
    required this.value, this.subtitle, required this.color});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12), color: cardBg,
        border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(emoji, style: const TextStyle(fontSize: 24)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600)),
          if (subtitle != null)
            Text(subtitle!, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        ])),
      ]),
    );
  }
}
