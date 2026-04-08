import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';
import '../services/settings_service.dart';
import '../services/widget_service.dart';
import 'log_event_sheet.dart';

const kSleepColor = Color(0xFFa78bfa);
const kFeedColor = Colors.orange;
const kDiaperColor = Colors.teal;
const kPumpColor = Color(0xFFF472B6);

class HomeScreen extends StatefulWidget {
  final FirestoreService service;
  final TrackerSettings settings;
  const HomeScreen({super.key, required this.service, required this.settings});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic> _stats = {};
  List<Map<String, dynamic>> _expirationWarnings = [];
  Map<String, int> _stockByStorage = {'room': 0, 'fridge': 0, 'freezer': 0};
  bool _loading = true;
  Timer? _timer;
  late final WidgetService _widgetService;

  @override
  void initState() {
    super.initState();
    _widgetService = WidgetService(firestore: widget.service, settings: widget.settings);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) { setState(() {}); _load(); }
    });
  }

  Future<void> _load() async {
    try {
      // Quick stats + stock in parallel
      final futures = <Future>[widget.service.getQuickStats()];
      if (widget.settings.trackPump) {
        futures.add(widget.service.getExpirationWarnings());
        futures.add(widget.service.getStockByStorage());
      }
      final results = await Future.wait(futures);

      final s = results[0] as Map<String, dynamic>;
      List<Map<String, dynamic>> warnings = [];
      Map<String, int> stockTotals = {'room': 0, 'fridge': 0, 'freezer': 0};
      if (widget.settings.trackPump) {
        warnings = results[1] as List<Map<String, dynamic>>;
        final stockMap = results[2] as Map<String, List<Map<String, dynamic>>>;
        for (final entry in stockMap.entries) {
          stockTotals[entry.key] = entry.value.fold<int>(0, (sum, i) => sum + (i['remaining'] as int));
        }
      }
      if (mounted) {
        setState(() { _stats = s; _expirationWarnings = warnings; _stockByStorage = stockTotals; _loading = false; });
      }
      _widgetService.update();
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openLog(EventType type) async {
    final ongoing = _stats['ongoing'] as BabyEvent?;
    final result = await showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => LogEventSheet(type: type, service: widget.service,
        ongoing: (ongoing != null && ongoing.type == type) ? ongoing : null),
    );
    if (result != null) {
      _load();
      if (!mounted) return;
      String msg;
      if (result is BabyEvent) {
        final t = '${result.startTime.hour.toString().padLeft(2, "0")}:${result.startTime.minute.toString().padLeft(2, "0")}';
        msg = '${result.displayName} at $t';
        if (result.durationMinutes != null) msg += ' · ${result.durationText}';
        if (result.side != null) msg += ' · ${result.side}';
        if (result.ml != null) msg += ' · ${result.ml}ml';
        if (result.isOngoing) msg += ' (ongoing)';
      } else {
        msg = ongoing != null && ongoing.type == type ? '${type.name} ended' : '${type.name} logged';
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(
        content: Text('✓ $msg'),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        dismissDirection: DismissDirection.horizontal,
        action: result is BabyEvent ? SnackBarAction(label: 'UNDO', onPressed: () async {
          await widget.service.deleteEvent(result.id);
          _load();
        }) : null,
      ));
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

  String _buildStockLine() {
    final total = _stockByStorage.values.fold<int>(0, (s, v) => s + v);
    if (total == 0) return 'Stock: empty';
    final parts = <String>[];
    if (_stockByStorage['room']! > 0) parts.add('🏠 ${_stockByStorage['room']}ml');
    if (_stockByStorage['fridge']! > 0) parts.add('❄️ ${_stockByStorage['fridge']}ml');
    if (_stockByStorage['freezer']! > 0) parts.add('🧊 ${_stockByStorage['freezer']}ml');
    return 'Stock: ${total}ml — ${parts.join(' · ')}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusBg = isDark ? const Color(0xFF151820) : Colors.grey.shade50;
    final cardBg = isDark ? const Color(0xFF1E2130) : Colors.white;
    final cfg = widget.settings;

    final lastSleep = _stats['lastSleep'] as BabyEvent?;
    final lastFeed = _stats['lastFeed'] as BabyEvent?;
    final lastDiaper = _stats['lastDiaper'] as BabyEvent?;
    final lastPump = _stats['lastPump'] as BabyEvent?;
    final ongoing = _stats['ongoing'] as BabyEvent?;
    final pees24h = _stats['pees24h'] ?? 0;
    final poops24h = _stats['poops24h'] ?? 0;
    final lastSide = _stats['lastSide'] as String?;
    final recommendedSide = _stats['recommendedSide'] as String?;
    final recommendationReason = _stats['recommendationReason'] as String?;
    final pumpCount24h = _stats['pumpCount24h'] ?? 0;
    final pumpMl24h = _stats['pumpMl24h'] ?? 0;

    return _loading
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

                  // Expiration warnings
                  ..._expirationWarnings.map((w) {
                    final p = w['event'] as BabyEvent;
                    final urgency = w['urgency'] as String;
                    final timeLeft = w['timeLeft'] as Duration;
                    final color = urgency == 'critical' ? Colors.red : urgency == 'warning' ? Colors.orange : Colors.amber;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: color.withOpacity(0.1), border: Border.all(color: color)),
                      child: Row(children: [
                        Text(urgency == 'critical' ? '🚨' : '⚠️', style: const TextStyle(fontSize: 20)),
                        const SizedBox(width: 10),
                        Expanded(child: Text('${p.readablePumpId} expires in ${_fmt(timeLeft)}',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color))),
                      ]),
                    );
                  }),

                  // Sleep
                  if (cfg.trackSleep) ...[
                    _MiniStat(cardBg: cardBg, emoji: '😴', title: 'Sleep',
                      line1: lastSleep != null ? 'Last: ${_ago(lastSleep.endTime ?? lastSleep.startTime)} ago' : 'No data'),
                    const SizedBox(height: 8),
                  ],

                  // Feed — 2 last feeds + next side
                  if (cfg.trackFeed) ...[
                    _FeedStatCard(
                      cardBg: cardBg,
                      service: widget.service,
                      recommendedSide: recommendedSide,
                      recommendationReason: recommendationReason,
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Diaper — just time since last
                  if (cfg.trackDiaper) ...[
                    _MiniStat(cardBg: cardBg, emoji: '🧷', title: 'Diaper',
                      line1: lastDiaper != null
                          ? 'Last: ${_ago(lastDiaper.startTime)} ago (${lastDiaper.pee && lastDiaper.poop ? "pee+poop" : lastDiaper.poop ? "poop" : "pee"})'
                          : 'No data'),
                    const SizedBox(height: 8),
                  ],

                  // Pump — stock only
                  if (cfg.trackPump) ...[
                    _MiniStat(cardBg: cardBg, emoji: '🥛', title: 'Pump Stock',
                      line1: _buildStockLine()),
                    const SizedBox(height: 8),
                  ],
                ]))),

              // Log buttons
              Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 24), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text("What's happening?", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade500, letterSpacing: 0.5)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 10, runSpacing: 10, children: [
                    if (cfg.trackSleep) SizedBox(width: _btnWidth(context, cfg), child: _LogBtn(
                      emoji: ongoing?.type == EventType.sleep ? '⏰' : '😴',
                      label: ongoing?.type == EventType.sleep ? 'End Sleep' : 'Sleep',
                      color: kSleepColor, active: ongoing?.type == EventType.sleep,
                      onTap: () => _openLog(EventType.sleep))),
                    if (cfg.trackFeed) SizedBox(width: _btnWidth(context, cfg), child: _LogBtn(
                      emoji: ongoing?.type == EventType.feed ? '⏰' : '🍼',
                      label: ongoing?.type == EventType.feed ? 'End Feed' : 'Feed',
                      color: kFeedColor, active: ongoing?.type == EventType.feed,
                      onTap: () => _openLog(EventType.feed))),
                    if (cfg.trackDiaper) SizedBox(width: _btnWidth(context, cfg), child: _LogBtn(
                      emoji: '🧷', label: 'Diaper', color: kDiaperColor, onTap: () => _openLog(EventType.diaper))),
                    if (cfg.trackPump) SizedBox(width: _btnWidth(context, cfg), child: _LogBtn(
                      emoji: '🥛', label: 'Pump', color: kPumpColor, onTap: () => _openLog(EventType.pump))),
                  ]),
                ],
              )),
            ]));
  }

  double _btnWidth(BuildContext context, TrackerSettings cfg) {
    final count = [cfg.trackSleep, cfg.trackFeed, cfg.trackDiaper, cfg.trackPump].where((v) => v).length;
    final screenW = MediaQuery.of(context).size.width - 32;
    if (count <= 3) return (screenW - (count - 1) * 10) / count;
    return (screenW - 10) / 2;
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }
}

// ===== Feed stat card with 2 last feeds + next side =====
class _FeedStatCard extends StatefulWidget {
  final Color cardBg;
  final FirestoreService service;
  final String? recommendedSide;
  final String? recommendationReason;
  const _FeedStatCard({required this.cardBg, required this.service,
    this.recommendedSide, this.recommendationReason});
  @override
  State<_FeedStatCard> createState() => _FeedStatCardState();
}

class _FeedStatCardState extends State<_FeedStatCard> {
  List<BabyEvent> _recentFeeds = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final feeds = await widget.service.getRecentFeeds(2);
    if (mounted) setState(() => _recentFeeds = feeds);
  }

  String _fmt(Duration? d) {
    if (d == null) return '--';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    return '${d.inMinutes}m';
  }

  String _feedDetail(BabyEvent f) {
    final endT = f.endTime ?? f.startTime;
    final ago = _fmt(DateTime.now().difference(endT));
    final parts = <String>[ago + ' ago'];
    if (f.durationMinutes != null) parts.add(f.durationText);
    else if (f.mlFed != null) parts.add('${f.mlFed}ml');
    else if (f.source == 'pump' && f.linkedPumps != null) {
      try {
        final list = List<Map<String, dynamic>>.from(jsonDecode(f.linkedPumps!));
        final ml = list.fold<int>(0, (s, x) => s + (x['ml'] as num).toInt());
        if (ml > 0) parts.add('${ml}ml');
      } catch (_) {}
    }
    if (f.side != null) parts.add(f.side!);
    if (f.isOngoing && f.source != 'pump') parts.add('ongoing');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: widget.cardBg,
        border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('🍼', style: TextStyle(fontSize: 28)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Feed', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 4),
          if (_recentFeeds.isEmpty)
            Text('No data', style: TextStyle(fontSize: 13, color: Colors.grey.shade400))
          else ...[
            Text(_feedDetail(_recentFeeds[0]), style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
            if (_recentFeeds.length > 1)
              Text('prev: ${_feedDetail(_recentFeeds[1])}', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ],
          if (widget.recommendedSide != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: kFeedColor.withOpacity(0.12),
              ),
              child: Text('🤱 Next: ${widget.recommendedSide!.toUpperCase()}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kFeedColor)),
            ),
            Text(widget.recommendationReason ?? '', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ],
        ])),
      ]),
    );
  }
}

// ===== Compact stat card =====
class _MiniStat extends StatelessWidget {
  final Color cardBg; final String emoji; final String title;
  final String line1; final String? line2; final String? line3;
  const _MiniStat({required this.cardBg, required this.emoji, required this.title,
    required this.line1, this.line2, this.line3});
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
          if (line2 != null) Text(line2!, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          if (line3 != null) Text(line3!, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        ])),
      ]),
    );
  }
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
