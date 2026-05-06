import 'package:flutter/material.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';

const kPumpColor = Color(0xFFF472B6);

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
    int daysWithData = 0;
    for (int di = 1; di <= 5; di++) {
      final dayStart = DateTime(now.year, now.month, now.day - di);
      final dayEnd = DateTime(now.year, now.month, now.day - di + 1);
      final count = _recentEvents.where((e) =>
          e.type == EventType.feed &&
          e.source == 'pump' &&
          !e.startTime.isBefore(dayStart) &&
          e.startTime.isBefore(dayEnd)).length;
      if (count > 0) daysWithData++;
      totalFeedLogs += count;
    }
    final avgFeedsPerDay = daysWithData == 0 ? 0.0 : totalFeedLogs / 5;
    final twoDaysAgo = DateTime.now().subtract(const Duration(days: 2));
    const storageEmoji = {'room': '🏠', 'fridge': '❄️', 'freezer': '🧊'};
    const storageOrder = ['room', 'fridge', 'freezer'];

    final storageMap = <String, int>{};
    final bottleCount = <String, int>{};
    for (final u in _stock) {
      final p = u['event'] as BabyEvent;
      final storage = p.storage ?? 'room';
      storageMap[storage] = (storageMap[storage] ?? 0) + (u['remaining'] as int);
      bottleCount[storage] = (bottleCount[storage] ?? 0) + 1;
    }

    final sorted = [..._stock]..sort((a, b) =>
        (b['event'] as BabyEvent).startTime.compareTo((a['event'] as BabyEvent).startTime));

    final fullyUsed = recentUsage.where((u) =>
        (u['fullyUsed'] as bool) &&
        (u['pumpedAt'] as DateTime).isAfter(twoDaysAgo)).toList();

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
              Text(avgPumped.toString() + 'ml',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: kPumpColor)),
              Text('Pumped/day', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ])),
            Expanded(child: Column(children: [
              Text(avgUsed.toString() + 'ml',
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
                final bc = bottleCount[s] ?? 0;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Text(storageEmoji[s] ?? '', style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(storageMap[s].toString() + 'ml',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
                    Text(bc.toString() + ' portion' + (bc == 1 ? '' : 's'),
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  ]),
                );
              }),
              if (storageMap.isNotEmpty) ...[
                Builder(builder: (_) {
                  final totalMl = storageMap.values.fold(0, (s, v) => s + v);
                  final feeds = (totalMl / 90).round();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('~$feeds feed${feeds == 1 ? '' : 's'} from ${totalMl}ml total',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  );
                }),
                Divider(height: 16, color: borderColor),
                // Individual bottles
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
                    if (diff.inDays > 1) {
                      expStr = 'exp ' + diff.inDays.toString() + 'd';
                    } else if (diff.inHours > 0) {
                      expStr = 'exp ' + diff.inHours.toString() + 'h';
                    } else {
                      expStr = 'exp <1h';
                    }
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Text(sEmoji, style: const TextStyle(fontSize: 16)),
                      const SizedBox(width: 8),
                      Text('#' + id.toString(),
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                              color: Colors.grey.shade400)),
                      const SizedBox(width: 8),
                      Text(rem.toString() + 'ml',
                          style: TextStyle(fontSize: 13,
                              color: isPartial ? Colors.orange.shade400 : null)),
                      if (isPartial) ...[
                        const SizedBox(width: 4),
                        Text('(' + used.toString() + 'ml used)',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                      ],
                      const Spacer(),
                      if (expStr.isNotEmpty)
                        Text(expStr, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
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
                  opacity: fullyUsedItem ? 0.4 : 1.0,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(children: [
                      Text(pad2(pumpedAt.day) + '/' + pad2(pumpedAt.month),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      Text(pad2(pumpedAt.hour) + ':' + pad2(pumpedAt.minute),
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                      const SizedBox(width: 8),
                      if (id != null)
                        Text('#' + id.toString(),
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                      const Spacer(),
                      Text(pumpedMl.toString() + 'ml',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: kPumpColor)),
                      if (usedMl > 0) ...[
                        const SizedBox(width: 6),
                        Text(usedMl.toString() + 'ml used',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                      ],
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

  String pad2(int n) => n.toString().padLeft(2, "0");
}
