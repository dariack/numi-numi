import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';
import '../services/medicine_service.dart';
import '../services/reminder_service.dart';
import '../models/medicine.dart';
import '../services/settings_service.dart';
import '../services/notification_service.dart';
import '../services/widget_service.dart';
import 'log_event_sheet.dart';
import 'history_screen.dart';
import '../services/handoff_service.dart';
import 'package:url_launcher/url_launcher.dart';

const kSleepColor = Color(0xFFa78bfa);
const kFeedColor = Colors.orange;
const kDiaperColor = Colors.teal;
const kPumpColor = Color(0xFFF472B6);

class HomeScreen extends StatefulWidget {
  final FirestoreService service;
  final TrackerSettings settings;
  final MedicineService? medicineService;
  final ReminderService? reminderService;
  final SettingsService? settingsService;
  final void Function(String)? onTabChange;
  const HomeScreen({super.key, required this.service, required this.settings, this.medicineService, this.reminderService, this.settingsService, this.onTabChange});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription<List<BabyEvent>>? _streamSub;
  String? _myDeviceId;
  String _myCaregiverName = '';
  List<BabyEvent> _partnerRecentEvents = [];
  final Set<String> _seenPartnerEventIds = {};
  DateTime? _partnerEventSeen;
  final Map<String, String> _deviceNames = {};
  final Set<String> _dismissedReminders = {};
  final Set<String> _dismissedSuggestions = {};
  final Set<String> _dismissedStripEventIds = {};
  bool _partnerInitialized = false; // skip notification on first stream emission
  List<BabyEvent> _events = [];
  Map<String, dynamic> _stats = {};
  bool _loading = true;
  List<Medicine> _medicines = [];
  List<Map<String, dynamic>> _pendingReminders = [];
  StreamSubscription<List<Medicine>>? _medicinesSub;
  StreamSubscription<Map<String, String>>? _deviceNamesSub;

  int _logCount = 0;
  int _nextConfettiAt = 0; // set on first log
  DateTime? _birthDate;

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
    _loadDeviceId();
    _loadBirthDate();
    _deviceNamesSub = widget.service.deviceNamesStream().listen((names) {
      if (mounted) setState(() => _deviceNames
        ..clear()
        ..addAll(names));
    });
    // Tick timer is set up in _subscribeMedicines (60s interval)
  }

  static const _affirmations = [
    "Real heroes feed at 3am 🍼",
    "You're more capable than you know 💪",
    "Yuli is so lucky to have you ✨",
    "Every log is an act of love ❤️",
    "Sleep-deprived and still crushing it 🌙",
    "You're building the most important bond 🌟",
    "No manual needed — you've got this 💛",
    "Best mama in the universe 🌍",
    "You noticed, you showed up, you cared 🏆",
    "Tired? Yes. Amazing? Absolutely. 💫",
    "Yuli is growing because of you 👶",
    "This is what unconditional love looks like 💖",
    "Every small moment adds up to everything 🌸",
    "You are your baby's whole world 🌈",
    "Superhero status: confirmed 🦸",
    "You're doing the hardest and most beautiful job 🎀",
    "Look at you — tracking every little thing 📋",
    "Postpartum warrior right here 🔥",
    "Strong mama, happy baby 💕",
    "You showed up today — that's everything 🥇",
    "The love you give is immeasurable 🌻",
    "You make it look effortless (we know it's not) ✨",
    "World's most dedicated parent 🏅",
    "Every feed, every change, every cuddle — it counts 💝",
    "You're not just surviving — you're thriving 🌷",
  ];

  void _showConfetti(BuildContext ctx) {
    _logCount++;
    if (_nextConfettiAt == 0) {
      // First log: pick a random threshold between 3 and 7
      _nextConfettiAt = 3 + math.Random().nextInt(5);
    }
    if (_logCount < _nextConfettiAt) return;
    // Reset threshold for next surprise
    _nextConfettiAt = _logCount + 3 + math.Random().nextInt(5);

    final overlay = Overlay.of(ctx);
    final rng = math.Random();
    final msg = _affirmations[rng.nextInt(_affirmations.length)];
    late OverlayEntry entry;
    entry = OverlayEntry(builder: (_) => _ConfettiOverlay(
      message: msg,
      onDone: () => entry.remove(),
    ));
    overlay.insert(entry);
  }

  Future<void> _loadDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? id = prefs.getString('device_id');
    if (id == null) {
      // Use hostname as a stable base so device_id survives app reinstall.
      // Falls back to timestamp on web or if hostname is unavailable.
      String stableId;
      if (!kIsWeb) {
        try {
          final host = io.Platform.localHostname;
          final clean = host.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
          stableId = clean.isNotEmpty ? 'dev_$clean' : 'device_${DateTime.now().millisecondsSinceEpoch}';
        } catch (_) {
          stableId = 'device_${DateTime.now().millisecondsSinceEpoch}';
        }
      } else {
        stableId = 'web_${DateTime.now().millisecondsSinceEpoch}';
      }
      id = stableId;
      await prefs.setString('device_id', id);
    }

    if (mounted) setState(() { _myDeviceId = id; });
    // Re-run in case events stream fired before device ID was ready
    if (_events.isNotEmpty) _checkPartnerActivity(_events);
  }

  void _checkPartnerActivity(List<BabyEvent> events) {
    if (_myDeviceId == null) return;

    // All devices (including self) within 10 min — for the strip
    final allRecent = events.where((e) =>
        e.createdBy != null &&
        DateTime.now().difference(e.startTime).inMinutes < 10).toList();

    // Partner-only events — for OS notifications (never notify self)
    final partnerRecent = allRecent.where((e) => e.createdBy != _myDeviceId).toList();

    final wasInitialized = _partnerInitialized;
    _partnerInitialized = true;

    // Fire notifications for new partner events only
    final newPartnerEvents = wasInitialized
        ? partnerRecent.where((e) => !_seenPartnerEventIds.contains(e.id)).toList()
        : <BabyEvent>[];

    if (newPartnerEvents.isNotEmpty) {
      _seenPartnerEventIds.addAll(newPartnerEvents.map((e) => e.id));
      final byCaregiver = <String, List<BabyEvent>>{};
      for (final e in newPartnerEvents) { (byCaregiver[e.createdBy!] ??= []).add(e); }
      for (final entry in byCaregiver.entries) {
        final name = entry.value.first.createdByName ?? _deviceNames[entry.key] ?? 'Partner';
        final evtNames = entry.value.map((e) => _stripLabel(e)).join(', ');
        NotificationService.instance.showPartnerActivity(
          caregiverName: name,
          eventName: evtNames,
        );
      }
    }

    // Update strip with all recent events (any device)
    if (allRecent.isEmpty) {
      if (mounted && _partnerRecentEvents.isNotEmpty)
        setState(() { _partnerRecentEvents = []; _partnerEventSeen = null; });
      return;
    }

    final same = allRecent.length == _partnerRecentEvents.length &&
        allRecent.map((e) => e.id).toSet().containsAll(_partnerRecentEvents.map((e) => e.id));
    if (!same || newPartnerEvents.isNotEmpty) {
      if (mounted) setState(() {
        _partnerRecentEvents = allRecent;
        if (newPartnerEvents.isNotEmpty) _partnerEventSeen = DateTime.now();
      });
    }
  }

  String _stripLabel(BabyEvent e) {
    switch (e.type) {
      case EventType.feed:
        if (e.source == 'pump') {
          int? ml = e.mlFed;
          if (ml == null && e.linkedPumps != null) {
            try {
              final list = List<Map<String, dynamic>>.from(jsonDecode(e.linkedPumps!));
              ml = list.fold<int>(0, (s, x) => s + (x['ml'] as num).toInt());
            } catch (_) {}
          }
          return ml != null ? 'fed pumped milk · ${ml}ml' : 'fed pumped milk';
        }
        if (e.isOngoing) return 'started feeding${e.side != null ? ' · ${e.side}' : ''}';
        return 'finished feeding${e.side != null ? ' · ${e.side}' : ''}${e.durationMinutes != null ? ' · ${e.durationText}' : ''}';
      case EventType.sleep:
        if (e.isOngoing) return 'started sleeping';
        return 'finished sleeping${e.durationMinutes != null ? ' · ${e.durationText}' : ''}';
      case EventType.diaper:
        if (e.pee && e.poop) return 'diaper · pee + poop';
        if (e.poop) return 'diaper · poop';
        return 'diaper · pee';
      case EventType.pump:
        return e.ml != null ? 'pumped · ${e.ml}ml' : 'pump session';
    }
  }

  List<String> _getSuggestions(Map<String, dynamic> stats) {
    final now = DateTime.now();
    final suggestions = <String>[];
    final lastFeed = stats['lastFeed'] as BabyEvent?;
    if (lastFeed != null) {
      final feedEnd = lastFeed.endTime ?? lastFeed.startTime;
      final feedMins = now.difference(feedEnd).inMinutes;
      final avgGap = (stats['avgFeedGapMin'] as num?)?.toInt() ?? 180;
      if (feedMins >= (avgGap * 0.8).round() && feedMins < avgGap * 1.5) {
        final h = feedMins ~/ 60; final m = feedMins % 60;
        final t = (h > 0 ? h.toString() + 'h ' : '') + m.toString() + 'm';
        suggestions.add('⏰ ' + t + ' since last feed — usually every ' + (avgGap ~/ 60).toString() + 'h');
      }
    }
    final lastDiaper = stats['lastDiaper'] as BabyEvent?;
    if (lastDiaper != null) {
      final diaperMins = now.difference(lastDiaper.startTime).inMinutes;
      if (diaperMins >= 180) {
        final h = diaperMins ~/ 60; final m = diaperMins % 60;
        suggestions.add('🧷 ' + h.toString() + 'h ' + (m > 0 ? m.toString() + 'm ' : '') + 'since last diaper check');
      }
    }
    final stock = stats['pumpStock'] as Map<String, List<Map<String, dynamic>>>?;
    if (stock != null) {
      for (final item in (stock['room'] ?? [])) {
        final exp = item['expires'] as DateTime?;
        if (exp != null) {
          final minsLeft = exp.difference(now).inMinutes;
          if (minsLeft > 0 && minsLeft <= 60) {
            final id = item['pumpId'] != null ? '#' + item['pumpId'].toString() : '';
            suggestions.add('⚠️ Room temp milk ' + id + ' expires in ' + minsLeft.toString() + 'm');
          }
        }
      }
      for (final item in (stock['fridge'] ?? [])) {
        final exp = item['expires'] as DateTime?;
        if (exp != null) {
          final hoursLeft = exp.difference(now).inHours;
          if (hoursLeft > 0 && hoursLeft <= 24) {
            final id = item['pumpId'] != null ? '#' + item['pumpId'].toString() : '';
            suggestions.add('🧊 Fridge milk ' + id + ' expires in ' + hoursLeft.toString() + 'h — use soon');
          }
        }
      }
      for (final item in (stock['freezer'] ?? [])) {
        final exp = item['expires'] as DateTime?;
        if (exp != null) {
          final daysLeft = exp.difference(now).inDays;
          if (daysLeft > 0 && daysLeft <= 30) {
            final id = item['pumpId'] != null ? '#' + item['pumpId'].toString() : '';
            suggestions.add('🧊 Freezer milk ' + id + ' expires in ' + daysLeft.toString() + 'd');
          }
        }
      }
    }
    return suggestions;
  }

  String _timeAgo(DateTime t) {
    final mins = DateTime.now().difference(t).inMinutes;
    if (mins < 1) return 'just now';
    if (mins < 60) return mins.toString() + 'm ago';
    return (mins ~/ 60).toString() + 'h ' + (mins % 60).toString() + 'm ago';
  }

  void _subscribeMedicines() {
    if (widget.medicineService == null) return;
    _medicinesSub = widget.medicineService!.medicinesStream().listen((medicines) async {
      if (!mounted) return;
      _medicines = medicines;
      final reminders = await widget.medicineService!.getPendingReminders(medicines);
      if (mounted) setState(() => _pendingReminders = reminders);
    });
    // Refresh reminders + partner strip every minute (time-based)
    _tickTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (!mounted) return;
      setState(() {}); // refresh time labels and prune partner strip
      if (_events.isNotEmpty) _checkPartnerActivity(_events);
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
      _checkPartnerActivity(events);
      _widgetService.update();
      widget.reminderService?.rescheduleAll(events);
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
          ongoing: (ongoing != null && ongoing.type == type) ? ongoing : null,
          deviceId: _myDeviceId ?? 'app',
          caregiverName: _myCaregiverName),
    );
    if (result != null) {
      HapticFeedback.lightImpact();
      _showConfetti(context);
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
      '${t.hour.toString().padLeft(2, "0")}:${t.minute.toString().padLeft(2, "0")}';

  Future<void> _loadBirthDate() async {
    final bd = await widget.settingsService?.getBirthDate();
    if (mounted && bd != null) setState(() => _birthDate = bd);
  }

  Future<void> _shareHandoff(BuildContext ctx) async {
    HapticFeedback.mediumImpact();
    final messenger = ScaffoldMessenger.of(ctx);
    final msg = HandoffNoteService.buildMessage(
      stats: _stats,
      birthDate: _birthDate,
      recentEvents: _events,
      pendingReminders: _pendingReminders,
    );
    if (kIsWeb) {
      await Clipboard.setData(ClipboardData(text: msg));
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
        content: Text('Handoff note copied to clipboard!'),
        duration: Duration(seconds: 3),
      ));
    } else {
      final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(msg)}');
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication)
          .catchError((_) => false);
      if (!launched) {
        await Clipboard.setData(ClipboardData(text: msg));
        if (!mounted) return;
        messenger.showSnackBar(const SnackBar(
          content: Text('Copied to clipboard (WhatsApp not found)'),
          duration: Duration(seconds: 3),
        ));
      }
    }
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

        // ── 1. Partner activity strip — very top ─────────────────
        Builder(builder: (_) {
          final visible = _partnerRecentEvents
              .where((e) => !_dismissedStripEventIds.contains(e.id))
              .toList();
          if (visible.isEmpty) return const SizedBox.shrink();

          final selfEvents = visible.where((e) => e.createdBy == _myDeviceId).toList()
            ..sort((a, b) => b.startTime.compareTo(a.startTime));
          final partnerMap = <String, List<BabyEvent>>{};
          for (final e in visible) {
            if (e.createdBy != _myDeviceId) (partnerMap[e.createdBy!] ??= []).add(e);
          }

          // Build one Dismissible row per event (self) or per caregiver (partner)
          final rows = <Widget>[
            ...selfEvents.map((e) => Dismissible(
              key: Key('strip_${e.id}'),
              direction: DismissDirection.horizontal,
              background: _DismissBg(align: Alignment.centerLeft),
              secondaryBackground: _DismissBg(align: Alignment.centerRight),
              onDismissed: (_) {
                HapticFeedback.lightImpact();
                setState(() => _dismissedStripEventIds.add(e.id));
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.grey.shade800.withOpacity(0.5),
                ),
                child: Row(children: [
                  const Text('📋', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                    'You logged ${_stripLabel(e)} · ${_timeAgo(e.startTime)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                  )),
                  GestureDetector(
                    onTap: () async {
                      HapticFeedback.lightImpact();
                      await widget.service.deleteEvent(e.id);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: Colors.red.withOpacity(0.12),
                      ),
                      child: Text('Undo', style: TextStyle(fontSize: 11, color: Colors.red.shade400, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ]),
              ),
            )),
            ...partnerMap.entries.map((entry) {
              final evts = [...entry.value]..sort((a, b) => b.startTime.compareTo(a.startTime));
              final name = evts.first.createdByName ?? _deviceNames[entry.key] ?? 'Partner';
              final evtText = evts.map((e) => _stripLabel(e)).join(' · ');
              // Dismiss all events from this partner at once
              return Dismissible(
                key: Key('strip_${entry.key}_${evts.first.id}'),
                direction: DismissDirection.horizontal,
                background: _DismissBg(align: Alignment.centerLeft),
                secondaryBackground: _DismissBg(align: Alignment.centerRight),
                onDismissed: (_) {
                  HapticFeedback.lightImpact();
                  setState(() => _dismissedStripEventIds.addAll(evts.map((e) => e.id)));
                },
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.grey.shade800.withOpacity(0.5),
                  ),
                  child: Row(children: [
                    const Text('📋', style: TextStyle(fontSize: 14)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(
                      '$name logged $evtText · ${_timeAgo(evts.first.startTime)}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                    )),
                  ]),
                ),
              );
            }),
          ];

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(children: rows),
          );
        }),

        // ── 2. Contextual suggestion strip ───────────────────────
        Builder(builder: (context) {
          String suggKey(String s) {
            if (s.startsWith('⏰')) return 'feed_timing';
            if (s.startsWith('🧷')) return 'diaper_timing';
            final m = RegExp(r'#(\S+)').firstMatch(s);
            final id = m?.group(1) ?? 'unk';
            if (s.startsWith('⚠️')) return 'room_$id';
            if (s.contains('Fridge')) return 'fridge_$id';
            return 'freezer_$id';
          }
          final suggestions = _getSuggestions(_stats)
              .where((s) => !_dismissedSuggestions.contains(suggKey(s)))
              .toList();
          if (suggestions.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Column(children: suggestions.map((s) {
              final key = suggKey(s);
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Dismissible(
                  key: Key('sugg_$key'),
                  direction: DismissDirection.horizontal,
                  background: _DismissBg(align: Alignment.centerLeft),
                  secondaryBackground: _DismissBg(align: Alignment.centerRight),
                  onDismissed: (_) {
                    HapticFeedback.lightImpact();
                    setState(() => _dismissedSuggestions.add(key));
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: s.startsWith('⚠️') ? Colors.orange.withOpacity(0.08) : kFeedColor.withOpacity(0.08),
                      border: Border.all(
                          color: s.startsWith('⚠️')
                              ? Colors.orange.withOpacity(0.3)
                              : kFeedColor.withOpacity(0.2)),
                    ),
                    child: Text(s, style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
                  ),
                ),
              );
            }).toList()),
          );
        }),

        // ── 3. Medicine reminders — persist until given/dismissed ─
        Builder(builder: (context) {
          final visible = _pendingReminders.where((r) {
            final med = r['medicine'] as Medicine;
            final slot = r['scheduledTime'] as String;
            final slotDate = r['slotDate'] as DateTime?;
            final key = med.id + '_' + slot + '_' +
                (slotDate != null ? slotDate.day.toString() + '_' + slotDate.month.toString() : '');
            return !_dismissedReminders.contains(key);
          }).toList();
          if (visible.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Column(children: visible.map((r) {
              final med = r['medicine'] as Medicine;
              final slot = r['scheduledTime'] as String;
              final slotDate = r['slotDate'] as DateTime?;
              final dayLabel = r['dayLabel'] as String? ?? 'Today at ' + slot;
              final isOverdue = r['isOverdue'] as bool? ?? false;
              final dismissKey = med.id + '_' + slot + '_' +
                  (slotDate != null ? slotDate.day.toString() + '_' + slotDate.month.toString() : '');
              final borderCol = isOverdue ? Colors.orange : Colors.purple;
              final bgCol = isOverdue
                  ? Colors.orange.withOpacity(0.08)
                  : Colors.purple.withOpacity(0.08);
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Dismissible(
                  key: Key('med_$dismissKey'),
                  direction: DismissDirection.horizontal,
                  background: _DismissBg(align: Alignment.centerLeft),
                  secondaryBackground: _DismissBg(align: Alignment.centerRight),
                  onDismissed: (_) {
                    HapticFeedback.lightImpact();
                    setState(() => _dismissedReminders.add(dismissKey));
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: bgCol,
                      border: Border.all(color: borderCol.withOpacity(0.4)),
                    ),
                    child: Row(children: [
                      const Text('💊', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(
                        '${med.displayName} · $dayLabel${isOverdue ? ' · overdue' : ''}',
                        style: TextStyle(fontSize: 12, color: borderCol.withOpacity(0.85)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () async {
                          HapticFeedback.mediumImpact();
                          _showConfetti(context);
                          await widget.medicineService!.markGiven(
                              medicine: med, scheduledTime: slot,
                              givenAt: slotDate);
                          final reminders = await widget.medicineService!
                              .getPendingReminders(_medicines);
                          if (mounted) setState(() => _pendingReminders = reminders);
                        },
                        child: Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            color: borderCol.withOpacity(0.15),
                          ),
                          child: Icon(Icons.check, size: 14, color: borderCol),
                        ),
                      ),
                    ]),
                  ),
                ),
              );
            }).toList()),
          );
        }),

        // ── 4. Ongoing action banner ─────────────────────────────
        if (ongoing != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: _OngoingBannerCompact(
              event: ongoing!,
              onTap: () => _openLog(ongoing!.type),
            ),
          ),

        // Log buttons 2x2 grid
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
                  Builder(builder: (_) {
                    final btns = <Widget>[
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
                    ];
                    return SizedBox(
                      height: 56,
                      child: Row(children: [
                        for (int i = 0; i < btns.length; i++) ...[
                          if (i > 0) const SizedBox(width: 10),
                          Expanded(child: btns[i]),
                        ],
                      ]),
                    );
                  }),
                ])),

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
                                ? '(' + _hhmm(lastDiaper.startTime) + ') ' + _ago(lastDiaper.startTime) + ' ago · ' + (lastDiaper.pee && lastDiaper.poop ? 'pee+poop' : lastDiaper.poop ? 'poop' : 'pee')
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

        // ── Share handoff note button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: GestureDetector(
            onTap: () => _shareHandoff(context),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade800),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.ios_share, size: 16, color: Colors.grey.shade500),
                const SizedBox(width: 8),
                Text(
                  kIsWeb ? 'Copy handoff note' : 'Share handoff note',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade500,
                      fontWeight: FontWeight.w500),
                ),
              ]),
            ),
          ),
        ),

        // ── View History button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => HistoryScreen(
                  service: widget.service,
                  medicineService: widget.medicineService,
                ),
              ));
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade800),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.history, size: 16, color: Colors.grey.shade500),
                const SizedBox(width: 8),
                Text('View History',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade500,
                        fontWeight: FontWeight.w500)),
              ]),
            ),
          ),
        ),
      ]),
    );
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
    _deviceNamesSub?.cancel();
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
      '${t.hour.toString().padLeft(2, "0")}:${t.minute.toString().padLeft(2, "0")}';

  String _feedDetail(BabyEvent f) {
    final endT = f.endTime ?? f.startTime;
    final ago = _fmt(DateTime.now().difference(endT));
    final parts = <String>['(${_hhmm(f.startTime)}) $ago ago'];
    if (f.source == 'pump') {
      // Pump feeds: always show ml, never duration (duration is always 0)
      int ml = f.mlFed ?? 0;
      if (ml == 0 && f.linkedPumps != null) {
        try {
          final list = List<Map<String, dynamic>>.from(jsonDecode(f.linkedPumps!));
          ml = list.fold<int>(0, (s, x) => s + (x['ml'] as num).toInt());
        } catch (_) {}
      }
      if (ml > 0) parts.add('${ml}ml');
    } else {
      if (f.durationMinutes != null) parts.add(f.durationText);
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
        onTap: onTap == null ? null : () { HapticFeedback.lightImpact(); onTap!(); },
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
                        onTap: () { HapticFeedback.lightImpact(); onResume?.call(f); },
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
                const SizedBox(height: 4),
                Text(
                  '🤱 Next: ' + recommendedSide!.toUpperCase(),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: kFeedColor.withOpacity(0.8)),
                ),
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
      onTap: onTap == null ? null : () { HapticFeedback.lightImpact(); onTap!(); },
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
                  onTap: () { HapticFeedback.lightImpact(); onResume!(); },
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
    return '${d.day.toString().padLeft(2, "0")}/${d.month.toString().padLeft(2, "0")} ${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}';
  }

  String _pumped(DateTime d) =>
      '${d.day.toString().padLeft(2, "0")}/${d.month.toString().padLeft(2, "0")} ${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Sort by pumped time descending
    final sorted = [...stockUnits]..sort((a, b) =>
        (b['event'] as BabyEvent).startTime.compareTo((a['event'] as BabyEvent).startTime));

    return GestureDetector(
      onTap: onTap == null ? null : () { HapticFeedback.lightImpact(); onTap!(); },
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
                Builder(builder: (_) {
                  if (sorted.isEmpty) {
                    return Text('Stock: empty',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade400));
                  }
                  final storageMap = <String, int>{};
                  final portionMap = <String, int>{};
                  for (final u in sorted) {
                    final storage = (u['storage'] as String?) ?? 'room';
                    final rem = u['remaining'] as int;
                    if (rem > 0) {
                      storageMap[storage] = (storageMap[storage] ?? 0) + rem;
                      portionMap[storage] = (portionMap[storage] ?? 0) + 1;
                    }
                  }
                  if (storageMap.isEmpty) {
                    return Text('Stock: empty',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade400));
                  }
                  const storageEmoji = {'room': '🏠', 'fridge': '❄️', 'freezer': '🧊'};
                  const order = ['room', 'fridge', 'freezer'];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: order
                        .where((s) => storageMap.containsKey(s))
                        .map((s) {
                          final ml = storageMap[s]!;
                          final portions = portionMap[s] ?? 0;
                          final feeds = (ml / 90).round();
                          return Text(
                            '${storageEmoji[s] ?? '🏠'} ${ml}ml ($portions portion${portions == 1 ? '' : 's'}, ~$feeds feed${feeds == 1 ? '' : 's'})',
                            style: TextStyle(fontSize: 13, color: Colors.grey.shade400));
                        })
                        .toList(),
                  );
                }),
              ])),
        ]),
      ),
    );
  }
}

// Compact prominent banner for top of page
class _OngoingBannerCompact extends StatelessWidget {
  final BabyEvent event;
  final VoidCallback onTap;
  const _OngoingBannerCompact({required this.event, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final dur = DateTime.now().difference(event.startTime);
    final color = event.type == EventType.sleep ? kSleepColor : kFeedColor;
    final fmtDur = dur.inHours > 0
        ? dur.inHours.toString() + 'h ' + dur.inMinutes.remainder(60).toString() + 'm'
        : dur.inMinutes.toString() + 'm';
    final sideText = event.side != null ? ' · ' + event.side! : '';
    final emoji = event.type == EventType.sleep ? '😴' : '🍼';
    final label = event.type == EventType.sleep ? 'Sleeping' : 'Feeding' + sideText;

    return GestureDetector(
      onTap: () { HapticFeedback.mediumImpact(); onTap(); }, // confetti fired in _openLog result
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: color.withOpacity(0.1),
          border: Border.all(color: color, width: 1.5),
        ),
        child: Row(children: [
          Text(emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          Expanded(child: Row(children: [
            Text(label,
                style: TextStyle(fontWeight: FontWeight.w700,
                    fontSize: 13, color: color)),
            const SizedBox(width: 6),
            Text('· ' + fmtDur,
                style: TextStyle(fontSize: 12, color: color.withOpacity(0.7))),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: color.withOpacity(0.15),
              border: Border.all(color: color.withOpacity(0.5)),
            ),
            child: Text('Tap to end',
                style: TextStyle(fontSize: 11, color: color,
                    fontWeight: FontWeight.w600)),
          ),
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
                      (event.type == EventType.sleep ? 'Sleeping' : 'Feeding' + sideText) + ' now',
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
        onTap: () { HapticFeedback.mediumImpact(); onTap(); },
        child: Container(
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: active ? color.withOpacity(0.15) : color.withOpacity(0.06),
              border: Border.all(
                  color: active ? color : color.withOpacity(0.4), width: 2),
              boxShadow: active
                  ? [BoxShadow(color: color.withOpacity(0.2), blurRadius: 8)]
                  : null),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(emoji, style: const TextStyle(fontSize: 26)),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 14, color: color)),
            ]),
          ),
        ));
  }
}

// ── Confetti + affirmation overlay ────────────────────────────────────
class _ConfettiOverlay extends StatefulWidget {
  final String message;
  final VoidCallback onDone;
  const _ConfettiOverlay({required this.message, required this.onDone});
  @override
  State<_ConfettiOverlay> createState() => _ConfettiOverlayState();
}

class _ConfettiOverlayState extends State<_ConfettiOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  late Animation<double> _slide;
  final List<_Particle> _particles = [];

  static const _confettiColors = [
    Color(0xFFf97316), Color(0xFF22c55e), Color(0xFF6366f1),
    Color(0xFFec4899), Color(0xFFf59e0b), Color(0xFF2dd4bf),
    Color(0xFFe879f9), Color(0xFF34d399), Color(0xFF60a5fa),
    Color(0xFFfb7185), Color(0xFFa3e635), Color(0xFFfbbf24),
  ];

  @override
  void initState() {
    super.initState();
    final rng = math.Random();
    for (int i = 0; i < 75; i++) {
      _particles.add(_Particle(
        x: rng.nextDouble(),
        startY: -60.0 + rng.nextDouble() * 80, // start above or just inside top
        speed: 0.55 + rng.nextDouble() * 0.55,
        drift: (rng.nextDouble() - 0.5) * 120, // horizontal drift over full animation
        wobble: 2.0 + rng.nextDouble() * 4.0,  // sine wave frequency
        wobbleAmp: 8.0 + rng.nextDouble() * 18.0, // sine wave amplitude px
        spin: (rng.nextDouble() - 0.5) * 12,   // rotation speed
        color: _confettiColors[rng.nextInt(_confettiColors.length)],
        size: 5.0 + rng.nextDouble() * 7.0,
        shape: rng.nextInt(3), // 0=rect, 1=strip, 2=circle
      ));
    }
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 3600));
    _fade  = CurvedAnimation(parent: _ctrl, curve: const Interval(0.74, 1.0));
    _slide = CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.25, curve: Curves.easeOut));
    _ctrl.forward().then((_) => widget.onDone());
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final t = _ctrl.value;
        return FadeTransition(
          opacity: Tween<double>(begin: 1, end: 0).animate(_fade),
          child: Stack(children: [
            // Affirmation pill — slides up from bottom third
            Positioned(
              bottom: 130 + _slide.value * 40,
              left: 24, right: 24,
              child: Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.80),
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 16, offset: const Offset(0, 4))],
                ),
                child: Text(widget.message,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.nunito(
                        color: Colors.white,
                        fontSize: 16, fontWeight: FontWeight.w700,
                        height: 1.3, decoration: TextDecoration.none)),
              )),
            ),
            // Confetti particles
            ..._particles.map((p) {
              final fallY = t * p.speed * screenH * 1.1;
              final wobbleX = math.sin(t * p.wobble * math.pi) * p.wobbleAmp;
              final cx = p.x * screenW + t * p.drift + wobbleX;
              final cy = p.startY + fallY;
              final rot = t * p.spin;
              // Determine dimensions by shape
              final w = p.shape == 1 ? p.size * 0.35 : p.size;
              final h = p.shape == 1 ? p.size * 2.2  : p.size * 0.55;
              final radius = p.shape == 2 ? p.size / 2 : 2.0;
              return Positioned(
                left: cx,
                top: cy,
                child: Transform.rotate(
                  angle: rot,
                  child: Container(
                    width: w, height: h,
                    decoration: BoxDecoration(
                      color: p.color,
                      borderRadius: BorderRadius.circular(radius),
                    ),
                  ),
                ),
              );
            }),
          ]),
        );
      },
    );
  }
}

class _Particle {
  final double x, startY, speed, drift, wobble, wobbleAmp, spin, size;
  final Color color;
  final int shape; // 0=rect, 1=strip, 2=circle
  const _Particle({
    required this.x, required this.startY, required this.speed,
    required this.drift, required this.wobble, required this.wobbleAmp,
    required this.spin, required this.size, required this.color,
    required this.shape,
  });
}

// Shared swipe-to-dismiss background (red tint + X icon)
class _DismissBg extends StatelessWidget {
  final AlignmentGeometry align;
  const _DismissBg({required this.align});
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(10),
      color: Colors.red.withOpacity(0.12),
    ),
    alignment: align,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Icon(Icons.close, size: 16, color: Colors.red.shade400),
  );
}
