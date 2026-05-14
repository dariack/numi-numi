import 'package:flutter/material.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';

const kPumpColor = Color(0xFFF472B6);

const _storageEmoji = {'room': '🏠', 'fridge': '❄️', 'freezer': '🧊'};
const _storageOrder = ['room', 'fridge', 'freezer'];

// Classify each bag by its ml: ≤60 = small, 61-90 = medium, >90 = large.
String _bagsBySize(List<int> bags) {
  int small = 0, med = 0, large = 0;
  for (final ml in bags) {
    if (ml <= 60) small++;
    else if (ml <= 90) med++;
    else large++;
  }
  if (small + med + large == 0) return '';
  final parts = <String>[
    if (large > 0) '$large large',
    if (med > 0) '$med med',
    if (small > 0) '$small small',
  ];
  return parts.join(' + ');
}

String _p2(int n) => n.toString().padLeft(2, '0');

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

  Future<void> _markAsUsed(Map<String, dynamic> u) async {
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

  // Build unified row: left=emoji+id+exp+date, right=ml(pink)+used+menu
  Widget _bagRow(Map<String, dynamic> u, Color borderColor) {
    final pumpedAt = u['pumpedAt'] as DateTime;
    final pumpedMl = u['pumpedMl'] as int;
    final usedMl = u['usedMl'] as int;
    final fullyUsed = u['fullyUsed'] as bool;
    final storage = (u['storage'] as String?) ?? 'room';
    final expiresAt = u['expiresAt'] as DateTime?;
    final pumpId = u['pumpId'];

    final emoji = _storageEmoji[storage] ?? '🏠';

    String expStr = '';
    if (expiresAt != null) {
      final diff = expiresAt.difference(DateTime.now());
      if (diff.isNegative) {
        expStr = 'exp!';
      } else if (storage == 'room') {
        final h = diff.inHours;
        final m = diff.inMinutes % 60;
        expStr = h > 0 ? 'exp ${h}h ${m}m' : 'exp ${m}m';
      } else {
        final d = diff.inDays;
        expStr = d > 0 ? 'exp ${d}d' : 'exp <1d';
      }
    }

    final dateStr =
        '${_p2(pumpedAt.day)}/${_p2(pumpedAt.month)} ${_p2(pumpedAt.hour)}:${_p2(pumpedAt.minute)}';

    return Opacity(
      opacity: fullyUsed ? 0.4 : 1.0,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Text(emoji, style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 5),
          if (pumpId != null) ...[
            Text('#$pumpId',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: Colors.grey.shade400)),
            const SizedBox(width: 5),
          ],
          if (expStr.isNotEmpty) ...[
            Text(expStr,
                style: TextStyle(
                    fontSize: 11,
                    color: expStr == 'exp!' ? Colors.red.shade400 : Colors.grey.shade500)),
            const SizedBox(width: 5),
          ],
          Expanded(
            child: Text('(pumped $dateStr)',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                overflow: TextOverflow.ellipsis),
          ),
          Text('${pumpedMl}ml',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.bold, color: kPumpColor)),
          if (usedMl > 0) ...[
            const SizedBox(width: 5),
            Text('${usedMl}ml used',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ],
          if (!fullyUsed) ...[
            const SizedBox(width: 2),
            _actionMenu(
              onUsed: () => _markAsUsed(u),
              onSpoiled: () => _markAsSpoiled(u['pumpEventId'] as String),
            ),
          ] else
            const SizedBox(width: 28),
        ]),
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

    // Storage summary — active (non-fully-used) bags only
    final storageMap = <String, int>{};
    final storageBagMls = <String, List<int>>{};
    for (final u in _stock) {
      final p = u['event'] as BabyEvent;
      final storage = p.storage ?? 'room';
      final rem = u['remaining'] as int;
      storageMap[storage] = (storageMap[storage] ?? 0) + rem;
      storageBagMls.putIfAbsent(storage, () => []).add(rem);
    }

    // Build unified bag row list: active stock + recently fully-used (last 3d)
    final stockIds = _stock.map((u) => (u['event'] as BabyEvent).id).toSet();
    final allRows = <Map<String, dynamic>>[];

    for (final u in _stock) {
      final p = u['event'] as BabyEvent;
      allRows.add({
        'pumpEventId': p.id,
        'pumpId': p.pumpId,
        'pumpedAt': p.startTime,
        'pumpedMl': p.ml ?? 0,
        'remaining': u['remaining'] as int,
        'usedMl': u['used'] as int,
        'fullyUsed': false,
        'expiresAt': p.expiresAt,
        'storage': p.storage ?? 'room',
      });
    }
    for (final u in recentUsage) {
      final id = u['pumpEventId'] as String;
      if (!stockIds.contains(id)) {
        allRows.add({
          'pumpEventId': id,
          'pumpId': u['pumpId'],
          'pumpedAt': u['pumpedAt'] as DateTime,
          'pumpedMl': u['pumpedMl'] as int,
          'remaining': u['remaining'] as int,
          'usedMl': u['totalUsed'] as int,
          'fullyUsed': u['fullyUsed'] as bool,
          'expiresAt': u['expiresAt'] as DateTime?,
          'storage': (u['storage'] as String?) ?? 'room',
        });
      }
    }
    allRows.sort((a, b) =>
        (b['pumpedAt'] as DateTime).compareTo(a['pumpedAt'] as DateTime));

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
          sectionLabel('5-DAY AVERAGES'),
          card(child: Row(children: [
            Expanded(child: Column(children: [
              Text(avgFeedsPerDay == avgFeedsPerDay.roundToDouble()
                      ? avgFeedsPerDay.toInt().toString()
                      : avgFeedsPerDay.toStringAsFixed(1),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
                      color: Color(0xFF6366f1))),
              Text('Feeds/day', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ])),
            Expanded(child: Column(children: [
              Text('${avgPumped}ml',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
                      color: kPumpColor)),
              Text('Pumped/day', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ])),
            Expanded(child: Column(children: [
              Text('${avgUsed}ml',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
                      color: Colors.orange.shade400)),
              Text('Used/day', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ])),
          ])),

          sectionLabel('BAGS'),
          if (allRows.isEmpty)
            card(child: Text('No bags', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)))
          else
            card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Storage summary (active stock only)
              if (storageMap.isNotEmpty) ...[
                ...(_storageOrder.where((s) => storageMap.containsKey(s)).map((s) {
                  final ml = storageMap[s]!;
                  final bags = storageBagMls[s] ?? [];
                  final sizeSummary = _bagsBySize(bags);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(children: [
                      Text(_storageEmoji[s]!, style: const TextStyle(fontSize: 18)),
                      const SizedBox(width: 8),
                      Text('${ml}ml',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      if (sizeSummary.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text('($sizeSummary)',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                      ],
                    ]),
                  );
                })),
                Divider(height: 16, color: borderColor),
              ],
              // All rows (active + recently used/spoiled)
              ...allRows.map((u) => _bagRow(u, borderColor)),
            ])),
        ],
      ),
    );
  }
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
