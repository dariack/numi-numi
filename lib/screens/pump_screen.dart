import 'package:flutter/material.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';

const kPumpColor = Color(0xFFF472B6);

// Feed size thresholds (ml)
const _kSmallFeed = 50;
const _kMediumFeed = 80;
const _kBigFeed = 110;

String _feedsBySize(int ml) {
  final big = ml ~/ _kBigFeed;
  final med = ml ~/ _kMediumFeed;
  final small = ml ~/ _kSmallFeed;
  final parts = <String>[];
  if (big > 0) parts.add('$big big (${_kBigFeed}ml)');
  if (med > 0) parts.add('$med med (${_kMediumFeed}ml)');
  if (small > 0) parts.add('$small small (${_kSmallFeed}ml)');
  return parts.isEmpty ? 'less than 1 small feed' : parts.join(', ');
}

class PumpScreen extends StatefulWidget {
  final FirestoreService service;
  const PumpScreen({super.key, required this.service});
  @override
  State<PumpScreen> createState() => _PumpScreenState();
}

class _PumpScreenState extends State<PumpScreen> {
  Map<String, dynamic>? _data;
  List<Map<String, dynamic>> _stock = [];
  List<BabyEvent> _recentEvents = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      widget.service.getPumpStats(),
      widget.service.getAvailableStock(),
      widget.service.getRecentEvents(days: 5),
    ]);
    if (mounted) {
      setState(() {
        _data = results[0] as Map<String, dynamic>;
        _stock = results[1] as List<Map<String, dynamic>>;
        _recentEvents = results[2] as List<BabyEvent>;
        _loading = false;
      });
    }
  }

  Future<void> _markAsSpoiled(String pumpEventId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Mark as spoiled?'),
        content: const Text('This will flag the milk as spoiled and remove it from stock.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Spoiled', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.service.markSpoiled(pumpEventId);
      _load();
    }
  }

  Future<void> _markAsUsed(Map u) async {
    final pumpEventId = u['pumpEventId'] as String;
    final pumpedMl = u['pumpedMl'] as int;
    final remaining = u['remaining'] as int;
    final mlToUse = remaining > 0 ? remaining : pumpedMl;

    final selectedTime = await showModalBottomSheet<DateTime>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _MarkAsUsedSheet(pumpedMl: mlToUse),
    );

    if (selectedTime == null) return;

    final linkedPumpsStr = '[{"id":"$pumpEventId","ml":$mlToUse}]';
    await widget.service.addEvent(BabyEvent(
      id: '',
      type: EventType.feed,
      startTime: selectedTime,
      endTime: selectedTime,
      durationMinutes: 0,
      source: 'pump',
      linkedPumps: linkedPumpsStr,
      mlFed: mlToUse,
      createdBy: 'pump-screen',
    ));
    _load();
  }

  Widget _actionMenu({
    required BuildContext context,
    required VoidCallback onUsed,
    required VoidCallback onSpoiled,
  }) {
    return Theme(
      data: Theme.of(context).copyWith(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: SizedBox(
        width: 28,
        height: 28,
        child: PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          icon: Icon(Icons.more_horiz, size: 16, color: Colors.grey.shade400),
          onSelected: (v) {
            if (v == 'used') onUsed();
            if (v == 'spoiled') onSpoiled();
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'used', child: Text('Mark as used (feed)')),
            PopupMenuItem(
              value: 'spoiled',
              child: Text('Mark as spoiled', style: TextStyle(color: Colors.red.shade400)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E2130) : Colors.white;
    final borderColor = isDark ? Colors.grey.shade800 : Colors.grey.shade200;
    final avgPumped = (_data!['avgPumpedPerDay'] as double).round();
    final avgUsed = (_data!['avgUsedPerDay'] as double).round();
    final recentUsage = _data!['recentUsage'] as List;

    // 5-day avg pump-source feeds per day
    final now = DateTime.now();
    int totalFeedLogs = 0;
    for (int di = 1; di <= 5; di++) {
      final dayStart = DateTime(now.year, now.month, now.day - di);
      final dayEnd = DateTime(now.year, now.month, now.day - di + 1);
      totalFeedLogs += _recentEvents.where((e) =>
          e.type == EventType.feed &&
          e.source == 'pump' &&
          !e.startTime.isBefore(dayStart) &&
          e.startTime.isBefore(dayEnd)).length;
    }
    final avgFeedsPerDay = totalFeedLogs / 5;

    const storageEmoji = {'room': '🏠', 'fridge': '❄️', 'freezer': '🧊'};
    const storageOrder = ['room', 'fridge', 'freezer'];

    final storageMap = <String, int>{};
    final bagCount = <String, int>{};
    for (final u in _stock) {
      final p = u['event'] as BabyEvent;
      final storage = p.storage ?? 'room';
      storageMap[storage] = (storageMap[storage] ?? 0) + (u['remaining'] as int);
      bagCount[storage] = (bagCount[storage] ?? 0) + 1;
    }

    final sorted = [..._stock]..sort((a, b) =>
        (b['event'] as BabyEvent).startTime.compareTo((a['event'] as BabyEvent).startTime));

    Widget card({required Widget child}) => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: cardBg,
        border: Border.all(color: borderColor),
      ),
      child: child,
    );

    Widget sectionLabel(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: TextStyle(
          fontSize: 10, fontWeight: FontWeight.w700,
          color: Colors.grey.shade500, letterSpacing: 0.5)),
    );

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 5-day averages
          sectionLabel('5-DAY AVERAGES'),
          card(child: Row(children: [
            Expanded(child: Column(children: [
              Text(avgFeedsPerDay == avgFeedsPerDay.roundToDouble()
                      ? avgFeedsPerDay.toInt().toString()
                      : avgFeedsPerDay.toStringAsFixed(1),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF6366f1))),
              Text('Feeds/day', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ])),
            Expanded(child: Column(children: [
              Text('${avgPumped}ml',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: kPumpColor)),
              Text('Pumped/day', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ])),
            Expanded(child: Column(children: [
              Text('${avgUsed}ml',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.orange.shade400)),
              Text('Used/day', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ])),
          ])),

          // Stock by storage
          sectionLabel('STOCK'),
          if (storageMap.isEmpty)
            card(child: Text('No stock', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)))
          else
            card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Summary by storage type
              ...storageOrder.where((s) => storageMap.containsKey(s)).map((s) {
                final bc = bagCount[s] ?? 0;
                final ml = storageMap[s]!;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    Text(storageEmoji[s] ?? '', style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${ml}ml',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
                    Text('$bc bag${bc == 1 ? '' : 's'}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  ]),
                );
              }),
              if (storageMap.isNotEmpty) ...[
                Builder(builder: (_) {
                  final totalMl = storageMap.values.fold(0, (s, v) => s + v);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('~${_feedsBySize(totalMl)}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  );
                }),
                Divider(height: 14, color: borderColor),
                // Individual bags with actions
                ...sorted.map((u) {
                  final p = u['event'] as BabyEvent;
                  final rem = u['remaining'] as int;
                  final used = u['used'] as int;
                  final isPartial = used > 0;
                  final id = p.pumpId ?? '—';
                  final storage = p.storage ?? 'room';
                  final sEmoji = storageEmoji[storage] ?? '🏠';
                  String expStr = '';
                  if (p.expiresAt != null) {
                    final diff = p.expiresAt!.difference(DateTime.now());
                    expStr = diff.inDays > 1 ? 'exp ${diff.inDays}d'
                        : diff.inHours > 0 ? 'exp ${diff.inHours}h' : 'exp <1h';
                  }
                  final stockUsageMap = {
                    'pumpEventId': p.id,
                    'pumpedMl': p.ml ?? 0,
                    'remaining': rem,
                  };
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Text(sEmoji, style: const TextStyle(fontSize: 15)),
                      const SizedBox(width: 6),
                      Text('#$id',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                              color: Colors.grey.shade400)),
                      const SizedBox(width: 6),
                      Text('${rem}ml',
                          style: TextStyle(fontSize: 13,
                              color: isPartial ? Colors.orange.shade400 : null)),
                      if (isPartial) ...[
                        const SizedBox(width: 4),
                        Text('(${used}ml used)',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                      ],
                      if (expStr.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(expStr, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                      ],
                      const Spacer(),
                      _actionMenu(
                        context: context,
                        onUsed: () => _markAsUsed(stockUsageMap),
                        onSpoiled: () => _markAsSpoiled(p.id),
                      ),
                    ]),
                  );
                }),
              ],
            ])),

          // Recently pumped
          if (recentUsage.isNotEmpty) ...[
            sectionLabel('RECENTLY PUMPED'),
            card(child: Column(children: [
              ...recentUsage.take(8).map((u) {
                final pumpedAt = u['pumpedAt'] as DateTime;
                final pumpedMl = u['pumpedMl'] as int;
                final id = u['pumpId'];
                final fullyUsedItem = u['fullyUsed'] as bool;
                final usedMl = u['totalUsed'] as int;
                return Opacity(
                  opacity: fullyUsedItem ? 0.45 : 1.0,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                      Text('${pad2(pumpedAt.day)}/${pad2(pumpedAt.month)}',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 6),
                      Text('${pad2(pumpedAt.hour)}:${pad2(pumpedAt.minute)}',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                      const SizedBox(width: 6),
                      if (id != null)
                        Text('#$id',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                      const Spacer(),
                      Text('${pumpedMl}ml',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: kPumpColor)),
                      if (usedMl > 0) ...[
                        const SizedBox(width: 5),
                        Text('${usedMl}ml used',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                      ],
                      if (!fullyUsedItem) ...[
                        const SizedBox(width: 2),
                        _actionMenu(
                          context: context,
                          onUsed: () => _markAsUsed(u as Map<String, dynamic>),
                          onSpoiled: () => _markAsSpoiled(u['pumpEventId'] as String),
                        ),
                      ] else
                        const SizedBox(width: 28),
                    ]),
                  ),
                );
              }),
            ])),
          ],
        ],
      ),
    );
  }

  String pad2(int n) => n.toString().padLeft(2, '0');
}

class _MarkAsUsedSheet extends StatefulWidget {
  final int pumpedMl;
  const _MarkAsUsedSheet({required this.pumpedMl});
  @override
  State<_MarkAsUsedSheet> createState() => _MarkAsUsedSheetState();
}

class _MarkAsUsedSheetState extends State<_MarkAsUsedSheet> {
  DateTime _when = DateTime.now();
  int _selectedQuickIdx = 0;
  bool _customTime = false;

  String _fmtTime(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  String _fmtDateTime(DateTime d) => '${d.day}/${d.month} ${_fmtTime(d)}';

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final primary = Theme.of(context).colorScheme.primary;

    Widget chip(String label, int idx, Duration offset) => GestureDetector(
      onTap: () => setState(() {
        _when = now.subtract(offset);
        _selectedQuickIdx = idx;
        _customTime = false;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: (!_customTime && _selectedQuickIdx == idx) ? primary : Colors.grey.withOpacity(0.3),
            width: (!_customTime && _selectedQuickIdx == idx) ? 2 : 1,
          ),
          color: (!_customTime && _selectedQuickIdx == idx) ? primary.withOpacity(0.12) : null,
        ),
        child: Text(label, style: TextStyle(
          fontSize: 13,
          fontWeight: (!_customTime && _selectedQuickIdx == idx) ? FontWeight.bold : FontWeight.normal,
          color: (!_customTime && _selectedQuickIdx == idx) ? primary : Colors.grey.shade400,
        )),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Mark as used — ${widget.pumpedMl}ml',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('When was this fed to baby?',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
        const SizedBox(height: 16),
        Row(children: [
          chip('Now',  0, Duration.zero),
          const SizedBox(width: 6),
          chip('5m',   4, const Duration(minutes: 5)),
          const SizedBox(width: 6),
          chip('15m',  1, const Duration(minutes: 15)),
          const SizedBox(width: 6),
          chip('30m',  2, const Duration(minutes: 30)),
          const SizedBox(width: 6),
          Expanded(child: GestureDetector(
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _when,
                firstDate: now.subtract(const Duration(days: 30)),
                lastDate: now,
              );
              if (d == null || !mounted) return;
              final t = await showTimePicker(
                context: context,
                initialTime: TimeOfDay.fromDateTime(_when),
              );
              if (t == null) return;
              final dt = DateTime(d.year, d.month, d.day, t.hour, t.minute);
              if (dt.isAfter(now)) return;
              setState(() { _when = dt; _customTime = true; _selectedQuickIdx = -1; });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _customTime ? primary : Colors.grey.withOpacity(0.3)),
                color: _customTime ? primary.withOpacity(0.1) : null,
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('✏️', style: TextStyle(fontSize: 14)),
                if (_customTime) ...[
                  const SizedBox(height: 2),
                  Text(_fmtDateTime(_when),
                      style: TextStyle(fontSize: 10, color: primary)),
                ],
              ]),
            ),
          )),
        ]),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.pop(context, _when),
            child: const Text('Log feed'),
          ),
        ),
      ]),
    );
  }
}
