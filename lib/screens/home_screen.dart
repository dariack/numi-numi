import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';
import '../services/medicine_service.dart';
import '../services/reminder_service.dart';
import '../models/medicine.dart';
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
  final MedicineService? medicineService;
  final ReminderService? reminderService;
  final void Function(String)? onTabChange;
  const HomeScreen({super.key, required this.service, required this.settings, this.medicineService, this.reminderService, this.onTabChange});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription<List<BabyEvent>>? _streamSub;
  String? _myDeviceId; // to detect partner events
  BabyEvent? _partnerLastEvent; // most recent event NOT by this device
  DateTime? _partnerEventSeen; // when we first saw it (for fade-out)
  List<BabyEvent> _events = [];
  Map<String, dynamic> _stats = {};
  bool _loading = true;
  List<Medicine> _medicines = [];
  List<Map<String, dynamic>> _pendingReminders = [];
  StreamSubscription<List<Medicine>>? _medicinesSub;

  // Only used to refresh "X min ago" labels — no data re-fetching
  Timer? _tickTimer;

  late final WidgetService _widgetService;

  @override
  void initState() {
    super.initState();
    _widgetService =
        WidgetService(firestore: widget.service, settings: widget.settings);
    _subscribeStream();
    _subscribeMedicines();
    // Tick timer is set up in _subscribeMedicines (60s interval)
    _loadDeviceId();
  }

  Future<void> _loadDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? id = prefs.getString('device_id');
    if (id == null) {
      id = 'device_${DateTime.now().millisecondsSinceEpoch}';
      await prefs.setString('device_id', id);
    }
    if (mounted) setState(() => _myDeviceId = id);
  }

  void _checkPartnerActivity(List<BabyEvent> events) {
    if (_myDeviceId == null) return;
    // Find most recent event not logged by this device
    // "app" = logged on mobile, "web" = logged on web
    // We use device_id stored in createdBy for our own device
    final recent = events.where((e) =>
        e.createdBy != null &&
        e.createdBy != _myDeviceId &&
        DateTime.now().difference(e.startTime).inMinutes < 10).toList();
    if (recent.isEmpty) {
      if (mounted && _partnerLastEvent != null) {
        setState(() { _partnerLastEvent = null; _partnerEventSeen = null; });
      }
      return;
    }
    final newest = recent.first;
    if (newest.id != _partnerLastEvent?.id) {
      if (mounted) setState(() {
        _partnerLastEvent = newest;
        _partnerEventSeen = DateTime.now();
      });
    }
  }

  // Returns a contextual suggestion or null
  String? _getSuggestion(Map<String, dynamic> stats) {
    final now = DateTime.now();
    final lastFeed = stats['lastFeed'] as BabyEvent?;
    final lastDiaper = stats['lastDiaper'] as BabyEvent?;

    if (lastFeed != null) {
      final feedEnd = lastFeed.endTime ?? lastFeed.startTime;
      final feedMins = now.difference(feedEnd).inMinutes;
      // Show suggestion at 80% of typical interval
      final avgGap = (stats['avgFeedGapMin'] as num?)?.toInt() ?? 180;
      if (feedMins >= (avgGap * 0.8).round() && feedMins < avgGap * 1.5) {
        final h = feedMins ~/ 60;
        final m = feedMins % 60;
        final timeStr = h > 0 ? '${h}h ${m}m' : '${m}m';
        return '⏰ $timeStr since last feed — usually every ${avgGap ~/ 60}h${avgGap % 60 > 0 ? " ${avgGap % 60}m" : ""}';
      }
    }
    if (lastDiaper != null) {
      final diaperMins = now.difference(lastDiaper.startTime).inMinutes;
      if (diaperMins >= 200) {
        final h = diaperMins ~/ 60;
        final m = diaperMins % 60;
        return '🧷 ${h}h ${m > 0 ? "${m}m " : ""}since last diaper change';
      }
    }
    return null;
  }

  void _subscribeMedicines() {
    if (widget.medicineService == null) return;
    _medicinesSub = widget.medicineService!.medicinesStream().listen((medicines) async {
      if (!mounted) return;
      _medicines = medicines;
      final reminders = await widget.medicineService!.getPendingReminders(medicines);
      if (mounted) setState(() => _pendingReminders = reminders);
    });
    // Refresh reminders every minute (time-based)
    _tickTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (!mounted) return;
      setState(() {}); // refresh time labels
      if (widget.medicineService != null && _medicines.isNotEmpty) {
        final reminders = await widget.medicineService!.getPendingReminders(_medicines);
        if (mounted) setState(() => _pendingReminders = reminders);
      }
    });
  }

  void _subscribeStream() {
    _streamSub = widget.service.eventsStream(limit: 300).listen((events) {
      if (!mounted) return;
      final stats = widget.service.computeStatsFromEvents(events);
      setState(() {
        _events = events;
        _stats = stats;
        _loading = false;
      });
      _widgetService.update();
      // Reschedule reminders whenever event list changes (catches partner actions too)
      widget.reminderService?.rescheduleAll(events);
      // Check for partner activity
      _checkPartnerActivity(events);
    }, onError: (_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  void _openLog(EventType type) async {
    HapticFeedback.mediumImpact();
    final ongoing = _stats['ongoing'] as BabyEvent?;
    final result = await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => LogEventSheet(
          type: type,
          service: widget.service,
          ongoing: (ongoing != null && ongoing.type == type) ? ongoing : null),
    );
    if (result != null) {
      HapticFeedback.lightImpact(); // confirm haptic
      // Stream auto-updates the UI — just show snackbar
      if (!mounted) return;
      String msg;
      if (result is BabyEvent) {
        final t =
            '${result.startTime.hour.toString().padLeft(2, "0")}:${result.startTime.minute.toString().padLeft(2, "0")}';
        msg = '${result.displayName} at $t';
        if (result.durationMinutes != null) msg += ' · ${result.durationText}';
        if (result.side != null) msg += ' · ${result.side}';
        if (result.ml != null) msg += ' · ${result.ml}ml';
        if (result.isOngoing) msg += ' (ongoing)';
      } else {
        msg = ongoing != null && ongoing.type == type
            ? '${type.name} ended'
            : '${type.name} logged';
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(
        content: Text('✓ $msg'),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        dismissDirection: DismissDirection.horizontal,
        action: result is BabyEvent
            ? SnackBarAction(
                label: 'UNDO',
                onPressed: () async {
                  await widget.service.deleteEvent(result.id);
                  // Stream handles UI update automatically
                })
            : null,
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

  String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';




  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusBg = isDark ? const Color(0xFF151820) : Colors.grey.shade50;
    final cardBg = isDark ? const Color(0xFF1E2130) : Colors.white;
    final cfg = widget.settings;

    final lastSleep = _stats['lastSleep'] as BabyEvent?;
    final lastFeed = _stats['lastFeed'] as BabyEvent?;
    final lastDiaper = _stats['lastDiaper'] as BabyEvent?;
    final ongoing = _stats['ongoing'] as BabyEvent?;
    final recommendedSide = _stats['recommendedSide'] as String?;
    final recommendationReason = _stats['recommendationReason'] as String?;
    final recentFeeds = (_stats['recentFeeds'] as List<BabyEvent>?) ?? [];
    final stockUnits = (_stats['stockUnits'] as List<Map<String, dynamic>>?) ?? [];
    final expirationWarnings =
        (_stats['expirationWarnings'] as List<Map<String, dynamic>>?) ?? [];

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: () async {
        // Pull-to-refresh: wait for next stream emission (Firestore re-fetches from server)
        await widget.service
            .eventsStream(limit: 300)
            .first
            .timeout(const Duration(seconds: 5))
            .catchError((_) => _events);
      },
      child: ListView(padding: EdgeInsets.zero, children: [
        SafeArea(
            child: Container(
                color: statusBg,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Quick Stats',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade500,
                              letterSpacing: 0.5)),
                      const SizedBox(height: 10),

                      // Medicine reminders
                      ..._pendingReminders.map((r) {
                        final med = r['medicine'] as Medicine;
                        final slot = r['scheduledTime'] as String;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.purple.withOpacity(0.1),
                              border: Border.all(color: Colors.purple, width: 2),
                            ),
                            child: Row(children: [
                              const Text('💊', style: TextStyle(fontSize: 22)),
                              const SizedBox(width: 10),
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('Give ${med.displayName}',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.purple)),
                                Text('Scheduled: $slot',
                                    style: TextStyle(fontSize: 12, color: Colors.purple.withOpacity(0.7))),
                              ])),
                              TextButton(
                                onPressed: () async {
                                  await widget.medicineService!.markGiven(
                                      medicine: med, scheduledTime: slot);
                                  final reminders = await widget.medicineService!
                                      .getPendingReminders(_medicines);
                                  if (mounted) setState(() => _pendingReminders = reminders);
                                },
                                style: TextButton.styleFrom(
                                  backgroundColor: Colors.purple.withOpacity(0.15),
                                  foregroundColor: Colors.purple,
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                child: const Text('✓ Given', style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                            ]),
                          ),
                        );
                      }),

                      if (ongoing != null) ...[
                        _OngoingBanner(
                            event: ongoing,
                            onTap: () => _openLog(ongoing.type)),
                        const SizedBox(height: 10),
                      ],

                      // Expiration warnings
                      ...expirationWarnings.map((w) {
                        final p = w['event'] as BabyEvent;
                        final urgency = w['urgency'] as String;
                        final timeLeft = w['timeLeft'] as Duration;
                        final color = urgency == 'critical'
                            ? Colors.red
                            : urgency == 'warning'
                                ? Colors.orange
                                : Colors.amber;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: color.withOpacity(0.1),
                              border: Border.all(color: color)),
                          child: Row(children: [
                            Text(urgency == 'critical' ? '🚨' : '⚠️',
                                style: const TextStyle(fontSize: 20)),
                            const SizedBox(width: 10),
                            Expanded(
                                child: Text(
                                    '${p.readablePumpId} expires in ${_fmt(timeLeft)}',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: color))),
                          ]),
                        );
                      }),

                      if (cfg.trackSleep) ...[
                        _MiniStat(
                            cardBg: cardBg,
                            emoji: '😴',
                            title: 'Sleep',
                            line1: lastSleep != null
                                ? 'Last: ${_ago(lastSleep.endTime ?? lastSleep.startTime)} ago'
                                : 'No data',
                            onTap: () => widget.onTabChange?.call('sleep'),
                            onResume: lastSleep != null &&
                                    !lastSleep.isOngoing &&
                                    lastSleep.endTime != null &&
                                    DateTime.now().difference(lastSleep.endTime!).inMinutes <= 5
                                ? () => widget.service.resumeEvent(lastSleep.id)
                                : null),
                        const SizedBox(height: 8),
                      ],

                      if (cfg.trackFeed) ...[
                        _FeedStatCard(
                          cardBg: cardBg,
                          recentFeeds: recentFeeds,
                          recommendedSide: recommendedSide,
                          recommendationReason: recommendationReason,
                          onTap: () => widget.onTabChange?.call('feed'),
                          onResume: (f) => widget.service.resumeEvent(f.id),
                        ),
                        const SizedBox(height: 8),
                      ],

                      if (cfg.trackDiaper) ...[
                        _MiniStat(
                            cardBg: cardBg,
                            emoji: '🧷',
                            title: 'Diaper',
                            line1: lastDiaper != null
                                ? '(${_hhmm(lastDiaper.startTime)}) ${_ago(lastDiaper.startTime)} ago · ${lastDiaper.pee && lastDiaper.poop ? "pee+poop" : lastDiaper.poop ? "poop" : "pee"}'
                                : 'No data',
                            onTap: () => widget.onTabChange?.call('diaper')),
                        const SizedBox(height: 8),
                      ],

                      if (cfg.trackPump) ...[
                        _PumpStockCard(
                            cardBg: cardBg,
                            stockUnits: stockUnits,
                            onTap: () => widget.onTabChange?.call('pump')),
                        const SizedBox(height: 8),
                      ],
                    ]))),

        // ── Partner activity strip ────────────────────────────
        if (_partnerLastEvent != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: AnimatedOpacity(
              opacity: _partnerEventSeen != null &&
                  DateTime.now().difference(_partnerEventSeen!).inMinutes >= 10 ? 0 : 1,
              duration: const Duration(seconds: 2),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.grey.shade800.withOpacity(0.5),
                ),
                child: Row(children: [
                  const Text('🤝', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                    '${_partnerLastEvent!.displayName} logged ${_timeAgo(_partnerLastEvent!.startTime)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                  )),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],

        // ── Log buttons — big 2×2 grid ──────────────────────────
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("What's happening?",
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade500,
                          letterSpacing: 0.5)),
                  const SizedBox(height: 12),
                  // 2×2 grid — always fill width evenly
                  GridView.count(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: 2.4,
                    children: [
                      if (cfg.trackFeed)
                        _LogBtn(
                            emoji: ongoing?.type == EventType.feed ? '⏰' : '🍼',
                            label: ongoing?.type == EventType.feed ? 'End Feed' : 'Feed',
                            color: kFeedColor,
                            active: ongoing?.type == EventType.feed,
                            onTap: () => _openLog(EventType.feed)),
                      if (cfg.trackDiaper)
                        _LogBtn(
                            emoji: '🧷',
                            label: 'Diaper',
                            color: kDiaperColor,
                            onTap: () => _openLog(EventType.diaper)),
                      if (cfg.trackSleep)
                        _LogBtn(
                            emoji: ongoing?.type == EventType.sleep ? '⏰' : '😴',
                            label: ongoing?.type == EventType.sleep ? 'End Sleep' : 'Sleep',
                            color: kSleepColor,
                            active: ongoing?.type == EventType.sleep,
                            onTap: () => _openLog(EventType.sleep)),
                      if (cfg.trackPump)
                        _LogBtn(
                            emoji: '🥛',
                            label: 'Pump',
                            color: kPumpColor,
                            onTap: () => _openLog(EventType.pump)),
                    ],
                  ),
                ])),

        // ── Contextual suggestion strip ──────────────────────────
        Builder(builder: (context) {
          final suggestion = _getSuggestion(_stats);
          if (suggestion == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: kFeedColor.withOpacity(0.08),
                border: Border.all(color: kFeedColor.withOpacity(0.2)),
              ),
              child: Text(suggestion,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
            ),
          );
        }),

      ]),
    );
  }

  String _timeAgo(DateTime t) {
    final mins = DateTime.now().difference(t).inMinutes;
    if (mins < 1) return 'just now';
    if (mins < 60) return '${mins}m ago';
    return '${mins ~/ 60}h ${mins % 60}m ago';
  }

  double _btnWidth(BuildContext context, TrackerSettings cfg) {
    final count = [
      cfg.trackSleep,
      cfg.trackFeed,
      cfg.trackDiaper,
      cfg.trackPump
    ].where((v) => v).length;
    final screenW = MediaQuery.of(context).size.width - 32;
    if (count <= 3) return (screenW - (count - 1) * 10) / count;
    return (screenW - 10) / 2;
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _medicinesSub?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }
}

// ===== Feed stat card — pure StatelessWidget, receives data from parent =====
class _FeedStatCard extends StatelessWidget {
  final Color cardBg;
  final List<BabyEvent> recentFeeds;
  final String? recommendedSide;
  final String? recommendationReason;
  final VoidCallback? onTap;
  final void Function(BabyEvent)? onResume;
  const _FeedStatCard(
      {required this.cardBg,
      required this.recentFeeds,
      this.recommendedSide,
      this.recommendationReason,
      this.onTap,
      this.onResume});

  String _fmt(Duration? d) {
    if (d == null) return '--';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    return '${d.inMinutes}m';
  }

  String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _feedDetail(BabyEvent f) {
    final endT = f.endTime ?? f.startTime;
    final ago = _fmt(DateTime.now().difference(endT));
    final parts = <String>['(${_hhmm(f.startTime)}) $ago ago'];
    if (f.durationMinutes != null)
      parts.add(f.durationText);
    else if (f.mlFed != null)
      parts.add('${f.mlFed}ml');
    else if (f.source == 'pump' && f.linkedPumps != null) {
      try {
        final list =
            List<Map<String, dynamic>>.from(jsonDecode(f.linkedPumps!));
        final ml =
            list.fold<int>(0, (s, x) => s + (x['ml'] as num).toInt());
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
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: cardBg,
          border: Border.all(
              color:
                  isDark ? Colors.grey.shade800 : Colors.grey.shade200)),
      child: GestureDetector(
        onTap: onTap,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('🍼', style: TextStyle(fontSize: 28)),
        const SizedBox(width: 12),
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              const Text('Feed',
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 4),
              if (recentFeeds.isEmpty)
                Text('No data',
                    style: TextStyle(
                        fontSize: 13, color: Colors.grey.shade400))
              else
                ...recentFeeds.map((f) {
                  final endT = f.endTime ?? f.startTime;
                  final canResume = !f.isOngoing &&
                      f.endTime != null &&
                      DateTime.now().difference(endT).inMinutes <= 5 &&
                      (f.type == EventType.feed);
                  return Row(children: [
                    Expanded(child: Text(_feedDetail(f),
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade400))),
                    if (canResume)
                      GestureDetector(
                        onTap: () => onResume?.call(f),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text('resume',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                                fontStyle: FontStyle.italic,
                              )),
                        ),
                      ),
                  ]);
                }),
              if (recommendedSide != null) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: kFeedColor.withOpacity(0.12),
                  ),
                  child: Text('🤱 Next: ${recommendedSide!.toUpperCase()}',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: kFeedColor)),
                ),
                Text(recommendationReason ?? '',
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade500)),
              ],
            ])),
      ])),
    );
  }
}

// ===== Compact stat card =====
class _MiniStat extends StatelessWidget {
  final Color cardBg;
  final String emoji;
  final String title;
  final String line1;
  final String? line2;
  final String? line3;
  final VoidCallback? onTap;
  final VoidCallback? onResume;
  const _MiniStat(
      {required this.cardBg,
      required this.emoji,
      required this.title,
      required this.line1,
      this.line2,
      this.line3,
      this.onTap,
      this.onResume});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: cardBg,
          border: Border.all(
              color:
                  isDark ? Colors.grey.shade800 : Colors.grey.shade200)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(emoji, style: const TextStyle(fontSize: 28)),
        const SizedBox(width: 12),
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 4),
              Text(line1,
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey.shade400)),
              if (line2 != null)
                Text(line2!,
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade500)),
              if (line3 != null)
                Text(line3!,
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade500)),
              if (onResume != null)
                GestureDetector(
                  onTap: onResume,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('resume',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                          fontStyle: FontStyle.italic,
                        )),
                  ),
                ),
            ])),
      ]),
    ));
  }
}

// ===== Pump stock card — individual units with expiry =====
class _PumpStockCard extends StatelessWidget {
  final Color cardBg;
  final List<Map<String, dynamic>> stockUnits;
  final VoidCallback? onTap;
  const _PumpStockCard({required this.cardBg, required this.stockUnits, this.onTap});

  String _expiry(DateTime? d) {
    if (d == null) return '';
    return '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')} ${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
  }

  String _pumped(DateTime d) =>
      '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')} ${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Sort by pumped time descending
    final sorted = [...stockUnits]..sort((a, b) =>
        (b['event'] as BabyEvent).startTime.compareTo((a['event'] as BabyEvent).startTime));

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: cardBg,
            border: Border.all(
                color: isDark ? Colors.grey.shade800 : Colors.grey.shade200)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('🥛', style: TextStyle(fontSize: 28)),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('Pump Stock',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 4),
                if (sorted.isEmpty)
                  Text('Stock: empty',
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade400))
                else
                  ...sorted.map((u) {
                    final p = u['event'] as BabyEvent;
                    final rem = u['remaining'] as int;
                    final idStr = p.pumpId ?? '—';
                    final storageEmoji = {'room': '🏠', 'fridge': '❄️', 'freezer': '🧊'};
                    final emoji = storageEmoji[u['storage'] as String? ?? 'room'] ?? '🏠';
                    final exp = p.expiresAt != null ? ' · expires: ${_expiry(p.expiresAt)}' : '';
                    return Text(
                        '$emoji #$idStr · ${rem}ml$exp',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade400));
                  }),
              ])),
        ]),
      ),
    );
  }
}

class _OngoingBanner extends StatelessWidget {
  final BabyEvent event;
  final VoidCallback onTap;
  const _OngoingBanner({required this.event, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final dur = DateTime.now().difference(event.startTime);
    final color = event.type == EventType.sleep ? kSleepColor : kFeedColor;
    final fmtDur = dur.inHours > 0
        ? '${dur.inHours}h ${dur.inMinutes.remainder(60)}m'
        : '${dur.inMinutes}m';
    final sideText = event.side != null ? ' (${event.side})' : '';
    return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: color.withOpacity(0.12),
              border: Border.all(color: color, width: 2)),
          child: Row(children: [
            Text(event.type == EventType.sleep ? '😴' : '🍼',
                style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(
                      '${event.type == EventType.sleep ? "Sleeping" : "Feeding$sideText"} now',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: color)),
                  Text('$fmtDur · tap to end',
                      style: TextStyle(
                          color: color.withOpacity(0.7), fontSize: 13)),
                ])),
            Icon(Icons.stop_circle_outlined, color: color, size: 32),
          ]),
        ));
  }
}

class _LogBtn extends StatelessWidget {
  final String emoji;
  final String label;
  final Color color;
  final bool active;
  final VoidCallback onTap;
  const _LogBtn(
      {required this.emoji,
      required this.label,
      required this.color,
      this.active = false,
      required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: active ? color.withOpacity(0.15) : color.withOpacity(0.06),
              border: Border.all(
                  color: active ? color : color.withOpacity(0.4), width: 2),
              boxShadow: active
                  ? [BoxShadow(color: color.withOpacity(0.2), blurRadius: 8)]
                  : null),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 10),
            Text(label,
                style: TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 15, color: color)),
          ]),
        ));
  }
}
