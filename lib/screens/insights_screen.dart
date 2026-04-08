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

    final todayDurOnly = ins['todayDurOnly'] as int;
    final todayMlOnly = ins['todayMlOnly'] as int;
    final todayEquiv = ins['todayEquiv'] as double;
    final avg3dEquiv = ins['avg3dEquiv'] as double;

    final todayParts = <String>[];
    if (todayDurOnly > 0) todayParts.add('${_fmtMin(todayDurOnly)} breast');
    if (todayMlOnly > 0) todayParts.add('${todayMlOnly}ml pumped');
    final todayStr = todayParts.isNotEmpty ? todayParts.join(' + ') : 'No feeds yet';

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

          // Today so far — combined
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: cardBg,
              border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('📊', style: TextStyle(fontSize: 24)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Today so far', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 4),
                Text(todayStr, style: TextStyle(fontSize: 13, color: kFeedColor, fontWeight: FontWeight.w600)),
                if (avg3dEquiv > 0) ...[
                  const SizedBox(height: 4),
                  Text('3-day avg: ~${_fmtMin(avg3dEquiv.round())} equiv/day',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  const SizedBox(height: 4),
                  _buildCompLabel(todayEquiv, avg3dEquiv, 'feeding'),
                ],
              ])),
            ]),
          ),

          const SizedBox(height: 16),
          Text('Recent Feeds', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
              color: Colors.grey.shade500, letterSpacing: 0.5)),
          const SizedBox(height: 8),
          _EventHistory(service: widget.service, type: EventType.feed),
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
    return ListView(padding: const EdgeInsets.all(16), children: [
        Text('Recent Sleep', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
            color: Colors.grey.shade500, letterSpacing: 0.5)),
        const SizedBox(height: 8),
        _EventHistory(service: service, type: EventType.sleep),
      ]);
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
    final today6 = DateTime(now.year, now.month, now.day, 6);
    final threeDaysAgo = now.subtract(const Duration(days: 3));

    final todayCount = snap.where((e) => e.startTime.isAfter(today6)).length;
    final d3d = snap.where((e) => e.startTime.isAfter(threeDaysAgo)).toList();
    final avg3d = d3d.isEmpty ? 0.0 : d3d.length / 3.0;

    String periodName(DateTime dt) {
      final h = dt.hour;
      if (h >= 0 && h < 6) return 'Night';
      if (h >= 6 && h < 12) return 'Morning';
      if (h >= 12 && h < 18) return 'Afternoon';
      return 'Evening';
    }

    final periodAvgs = <String, double>{};
    for (final p in ['Night', 'Morning', 'Afternoon', 'Evening']) {
      final count = d3d.where((e) => periodName(e.startTime) == p).length;
      periodAvgs[p] = count / 3.0;
    }

    if (mounted) setState(() {
      _todayCount = todayCount;
      _avg3d = avg3d;
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
                const Text('Today so far', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 4),
                Text('$_todayCount diapers', style: TextStyle(fontSize: 13, color: kDiaperColor, fontWeight: FontWeight.w600)),
                if (_avg3d > 0) ...[
                  const SizedBox(height: 4),
                  Text('3-day avg: ${_avg3d.toStringAsFixed(1)}/day', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
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
              const Text('3-Day Avg by Period', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
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

          const SizedBox(height: 16),
          Text('Recent Diapers', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
              color: Colors.grey.shade500, letterSpacing: 0.5)),
          const SizedBox(height: 8),
          _EventHistory(service: widget.service, type: EventType.diaper),
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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final stock = await widget.service.getStockByStorage();
    if (mounted) setState(() { _stock = stock; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E2130) : Colors.white;

    return RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('Stock Overview', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
              color: Colors.grey.shade500, letterSpacing: 0.5)),
          const SizedBox(height: 8),
          _stockSection(cardBg, '🏠 Room Temp', 'Lasts 4h', _stock['room'] ?? []),
          const SizedBox(height: 8),
          _stockSection(cardBg, '❄️ Fridge', 'Lasts 4 days', _stock['fridge'] ?? []),
          const SizedBox(height: 8),
          _stockSection(cardBg, '🧊 Freezer', 'Lasts 6 months', _stock['freezer'] ?? []),
          const SizedBox(height: 16),
          Text('Pump History', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
              color: Colors.grey.shade500, letterSpacing: 0.5)),
          const SizedBox(height: 8),
          _EventHistory(service: widget.service, type: EventType.pump),
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
        else ...[
          Text('Total: ${totalMl}ml (${items.length} portions)',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ...items.map((i) {
            final p = i['event'] as BabyEvent;
            final rem = i['remaining'] as int;
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                Expanded(child: Text(p.readablePumpId,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade400))),
                Text('${rem}ml', style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
              ]),
            );
          }),
        ],
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
