import 'dart:async';
import 'package:flutter/material.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';
import '../services/widget_service.dart';
import 'log_event_sheet.dart';

const kSleepColor = Color(0xFFa78bfa); // light purple
const kFeedColor = Colors.orange;
const kDiaperColor = Colors.teal;

class HomeScreen extends StatefulWidget {
  final FirestoreService service;
  const HomeScreen({super.key, required this.service});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic> _stats = {};
  bool _loading = true;
  Timer? _timer;
  late final WidgetService _widgetService;

  @override
  void initState() {
    super.initState();
    _widgetService = WidgetService(firestore: widget.service);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) { if (mounted) { setState(() {}); _load(); } });
  }

  Future<void> _load() async {
    try {
      final s = await widget.service.getQuickStats();
      if (mounted) setState(() { _stats = s; _loading = false; });
      _widgetService.update();
    } catch (e) { if (mounted) setState(() => _loading = false); }
  }

  void _openLog(EventType type) async {
    final ongoing = _stats['ongoing'] as BabyEvent?;
    final result = await showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => LogEventSheet(
        type: type, service: widget.service,
        ongoing: (ongoing != null && ongoing.type == type) ? ongoing : null,
      ),
    );

    if (result != null) {
      _load();
      if (!mounted) return;
      // Show undo snackbar
      String msg;
      if (result is BabyEvent) {
        final t = '${result.startTime.hour.toString().padLeft(2, "0")}:${result.startTime.minute.toString().padLeft(2, "0")}';
        msg = '${result.displayName} at $t';
        if (result.durationMinutes != null) msg += ' \u00b7 ${result.durationText}';
        if (result.side != null) msg += ' \u00b7 ${result.side}';
        if (result.isOngoing) msg += ' (ongoing)';
      } else {
        msg = ongoing != null && ongoing.type == type ? '${type.name} ended' : '${type.name} logged';
      }
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      final controller = messenger.showSnackBar(SnackBar(
        content: Text('✓ $msg'),
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
        action: result is BabyEvent ? SnackBarAction(label: 'UNDO', onPressed: () async {
          await widget.service.deleteEvent(result.id);
          _load();
        }) : null,
      ));
      Future.delayed(const Duration(seconds: 6), () { controller.close(); });
    }
  }

  String _fmt(Duration? d) {
    if (d == null) return '--';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    return '${d.inMinutes}m';
  }

  String _ago(DateTime? t) {
    if (t == null) return '--';
    return _fmt(DateTime.now().difference(t));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusBg = isDark ? const Color(0xFF151820) : Colors.grey.shade50;
    final cardBg = isDark ? const Color(0xFF1E2130) : Colors.white;

    final lastSleep = _stats['lastSleep'] as BabyEvent?;
    final lastFeed = _stats['lastFeed'] as BabyEvent?;
    final lastDiaper = _stats['lastDiaper'] as BabyEvent?;
    final ongoing = _stats['ongoing'] as BabyEvent?;
    final pees24h = _stats['pees24h'] ?? 0;
    final poops24h = _stats['poops24h'] ?? 0;
    final peesAvg = (_stats['peesAvg3d'] as double?)?.toStringAsFixed(1) ?? '--';
    final poopsAvg = (_stats['poopsAvg3d'] as double?)?.toStringAsFixed(1) ?? '--';
    final lastSide = _stats['lastSide'] as String?;

    // Compute sleep/feed 24h and avg counts
    // (these come from quick stats — we'll add them to the service next)
    final sleeps24h = _stats['sleeps24h'] ?? 0;
    final feeds24h = _stats['feeds24h'] ?? 0;
    final sleepsAvg = (_stats['sleepsAvg3d'] as double?)?.toStringAsFixed(1) ?? '--';
    final feedsAvg = (_stats['feedsAvg3d'] as double?)?.toStringAsFixed(1) ?? '--';
    final sleepAvgDur = _stats['sleepAvgDur3d'] as double?;
    final feedAvgDur = _stats['feedAvgDur3d'] as double?;

    return Scaffold(
      body: _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.zero, children: [
            SafeArea(child: Container(color: statusBg, padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Quick Stats', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade500, letterSpacing: 0.5)),
                const SizedBox(height: 10),

                if (ongoing != null) ...[
                  _OngoingBanner(event: ongoing, onTap: () => _openLog(ongoing.type)),
                  const SizedBox(height: 10),
                ],

                // Sleep stat
                _StatCard(cardBg: cardBg, emoji: '😴', title: 'Sleep',
                  line1: lastSleep != null
                    ? 'Last: ${_ago(lastSleep.endTime ?? lastSleep.startTime)} ago'
                    : 'No data',
                  line2: '24h: $sleeps24h naps',
                  line3: 'Avg/day: $sleepsAvg (3-day avg)',
                  line4: sleepAvgDur != null ? 'Avg duration: ${_fmt(Duration(minutes: sleepAvgDur.round()))} (3-day)' : null),
                const SizedBox(height: 8),

                // Feed stat
                _StatCard(cardBg: cardBg, emoji: '🍼', title: 'Feed',
                  line1: lastFeed != null
                    ? 'Last: ${_ago(lastFeed.endTime ?? lastFeed.startTime)} ago${lastSide != null ? " ($lastSide)" : ""}'
                    : 'No data',
                  line1b: lastFeed?.duration != null ? 'Duration: ${_fmt(lastFeed!.duration)}' : null,
                  line2: '24h: $feeds24h feeds',
                  line3: 'Avg/day: $feedsAvg (3-day avg)',
                  line4: feedAvgDur != null ? 'Avg duration: ${_fmt(Duration(minutes: feedAvgDur.round()))} (3-day)' : null),
                const SizedBox(height: 8),

                // Diaper stat
                _StatCard(cardBg: cardBg, emoji: '🧷', title: 'Diaper',
                  line1: lastDiaper != null
                    ? 'Last: ${_ago(lastDiaper.startTime)} ago (${lastDiaper.pee && lastDiaper.poop ? "pee+poop" : lastDiaper.poop ? "poop" : "pee"})'
                    : 'No data',
                  line1b: null,
                  line2: '24h: 💧$pees24h  💩$poops24h',
                  line3: 'Avg/day: 💧$peesAvg  💩$poopsAvg (3-day avg)'),
              ]))),

            // Log buttons
            Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 24), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text("What's happening?", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade500, letterSpacing: 0.5)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _LogBtn(emoji: ongoing?.type == EventType.sleep ? '⏰' : '😴',
                    label: ongoing?.type == EventType.sleep ? 'End Sleep' : 'Sleep',
                    color: kSleepColor, active: ongoing?.type == EventType.sleep,
                    onTap: () => _openLog(EventType.sleep))),
                  const SizedBox(width: 10),
                  Expanded(child: _LogBtn(emoji: ongoing?.type == EventType.feed ? '⏰' : '🍼',
                    label: ongoing?.type == EventType.feed ? 'End Feed' : 'Feed',
                    color: kFeedColor, active: ongoing?.type == EventType.feed,
                    onTap: () => _openLog(EventType.feed))),
                  const SizedBox(width: 10),
                  Expanded(child: _LogBtn(emoji: '🧷', label: 'Diaper', color: kDiaperColor,
                    onTap: () => _openLog(EventType.diaper))),
                ]),
              ],
            )),
          ])),
    );
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }
}

class _OngoingBanner extends StatelessWidget {
  final BabyEvent event; final VoidCallback onTap;
  const _OngoingBanner({required this.event, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final dur = DateTime.now().difference(event.startTime);
    final color = event.type == EventType.sleep ? kSleepColor : kFeedColor;
    final fmtDur = dur.inHours > 0 ? '${dur.inHours}h ${dur.inMinutes.remainder(60)}m' : '${dur.inMinutes}m';
    final sideText = event.side != null ? ' (${event.side})' : '';
    return GestureDetector(onTap: onTap, child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14),
        color: color.withOpacity(0.12), border: Border.all(color: color, width: 2)),
      child: Row(children: [
        Text(event.type == EventType.sleep ? '😴' : '🍼', style: const TextStyle(fontSize: 28)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${event.type == EventType.sleep ? "Sleeping" : "Feeding$sideText"} now',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color)),
          Text('$fmtDur · tap to end', style: TextStyle(color: color.withOpacity(0.7), fontSize: 13)),
        ])),
        Icon(Icons.stop_circle_outlined, color: color, size: 32),
      ]),
    ));
  }
}

class _StatCard extends StatelessWidget {
  final Color cardBg; final String emoji; final String title;
  final String line1; final String? line1b; final String line2; final String line3; final String? line4;
  const _StatCard({required this.cardBg, required this.emoji, required this.title,
    required this.line1, this.line1b, required this.line2, required this.line3, this.line4});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: cardBg,
        border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(emoji, style: const TextStyle(fontSize: 28)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 4),
          Text(line1, style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
          if (line1b != null) Text(line1b!, style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
          const SizedBox(height: 2),
          Text(line2, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          Text(line3, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          if (line4 != null) Text(line4!, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        ])),
      ]),
    );
  }
}

class _LogBtn extends StatelessWidget {
  final String emoji; final String label; final Color color; final bool active; final VoidCallback onTap;
  const _LogBtn({required this.emoji, required this.label, required this.color, this.active = false, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(onTap: onTap, child: Container(
      height: 100,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16),
        color: active ? color.withOpacity(0.15) : color.withOpacity(0.06),
        border: Border.all(color: active ? color : color.withOpacity(0.4), width: 2),
        boxShadow: active ? [BoxShadow(color: color.withOpacity(0.2), blurRadius: 8)] : null),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(emoji, style: const TextStyle(fontSize: 30)), const SizedBox(height: 4),
        Text(label, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: color)),
      ]),
    ));
  }
}
