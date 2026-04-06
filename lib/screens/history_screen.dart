import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';

class HistoryScreen extends StatefulWidget {
  final FirestoreService service;
  const HistoryScreen({super.key, required this.service});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _filter = 'all';
  String _timeFilter = 'all'; // all, today, yesterday, 2daysago, 3daysago

  List<BabyEvent> _applyTimeFilter(List<BabyEvent> events) {
    if (_timeFilter == 'all') return events;
    final now = DateTime.now();
    final today6 = DateTime(now.year, now.month, now.day, 6);
    if (_timeFilter == 'today') {
      return events.where((e) => !e.startTime.isBefore(today6)).toList();
    }
    if (_timeFilter == 'yesterday') {
      final y6 = today6.subtract(const Duration(days: 1));
      return events.where((e) => !e.startTime.isBefore(y6) && e.startTime.isBefore(today6)).toList();
    }
    if (_timeFilter == '2daysago') {
      final d2 = today6.subtract(const Duration(days: 2));
      final d1 = today6.subtract(const Duration(days: 1));
      return events.where((e) => !e.startTime.isBefore(d2) && e.startTime.isBefore(d1)).toList();
    }
    if (_timeFilter == '3daysago') {
      final d3 = today6.subtract(const Duration(days: 3));
      final d2 = today6.subtract(const Duration(days: 2));
      return events.where((e) => !e.startTime.isBefore(d3) && e.startTime.isBefore(d2)).toList();
    }
    return events;
  }

  String _getDayPeriod(DateTime dt) {
    final h = dt.hour;
    if (h >= 0 && h < 6) return 'night';
    if (h >= 6 && h < 12) return 'morning';
    if (h >= 12 && h < 18) return 'afternoon';
    return 'evening';
  }

  String _periodDisplay(String key, List<BabyEvent> events) {
    const emojis = {'night': '🌙', 'morning': '🌅', 'afternoon': '☀️', 'evening': '🌇'};
    const names = {'night': 'Night (00-06)', 'morning': 'Morning (06-12)', 'afternoon': 'Afternoon (12-18)', 'evening': 'Evening (18-00)'};
    return '${emojis[key]} ${names[key]}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Column(
        children: [
          SafeArea(child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(
              children: [
                // Type filters
                SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
                  _Chip(label: 'All', selected: _filter == 'all', onTap: () => setState(() => _filter = 'all')),
                  const SizedBox(width: 6),
                  _Chip(label: '😴 Sleep', selected: _filter == 'sleep', onTap: () => setState(() => _filter = 'sleep')),
                  const SizedBox(width: 6),
                  _Chip(label: '🍼 Feed', selected: _filter == 'feed', onTap: () => setState(() => _filter = 'feed')),
                  const SizedBox(width: 6),
                  _Chip(label: '🧷 Diaper', selected: _filter == 'diaper', onTap: () => setState(() => _filter = 'diaper')),
                ])),
                const SizedBox(height: 6),
                // Time filters
                SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
                  _Chip(label: 'All time', selected: _timeFilter == 'all', onTap: () => setState(() => _timeFilter = 'all')),
                  const SizedBox(width: 6),
                  _Chip(label: 'Today', selected: _timeFilter == 'today', onTap: () => setState(() => _timeFilter = 'today')),
                  const SizedBox(width: 6),
                  _Chip(label: 'Yesterday', selected: _timeFilter == 'yesterday', onTap: () => setState(() => _timeFilter = 'yesterday')),
                  const SizedBox(width: 6),
                  _Chip(label: '2 days ago', selected: _timeFilter == '2daysago', onTap: () => setState(() => _timeFilter = '2daysago')),
                  const SizedBox(width: 6),
                  _Chip(label: '3 days ago', selected: _timeFilter == '3daysago', onTap: () => setState(() => _timeFilter = '3daysago')),
                ])),
              ],
            ),
          )),
          Expanded(child: StreamBuilder<List<BabyEvent>>(
            stream: widget.service.eventsStream(limit: 500),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('Error: ${snapshot.error}'));
              }
              var events = snapshot.data ?? [];

              // Apply type filter locally (avoids needing composite indexes)
              if (_filter != 'all') {
                events = events.where((e) => e.type.name == _filter).toList();
              }

              // Apply time filter
              events = _applyTimeFilter(events);

              if (events.isEmpty) {
                return const Center(child: Text('No events'));
              }

              // Group by day, then by period
              final grouped = <String, Map<String, List<BabyEvent>>>{};
              for (final e in events) {
                final dayKey = _dayLabel(e.startTime);
                final period = _getDayPeriod(e.startTime);
                grouped.putIfAbsent(dayKey, () => {});
                grouped[dayKey]!.putIfAbsent(period, () => []);
                grouped[dayKey]![period]!.add(e);
              }

              final hasDur = _filter == 'sleep' || _filter == 'feed';
              String _fmtDurMin(int min) {
                if (min <= 0) return '';
                if (min < 60) return '${min}m';
                final h = min ~/ 60;
                final m = min % 60;
                return m > 0 ? '${h}h ${m}m' : '${h}h';
              }
              int _sumDur(List<BabyEvent> evs) => evs.fold(0, (s, e) => s + (e.durationMinutes ?? 0));

              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 20),
                itemCount: grouped.length,
                itemBuilder: (context, i) {
                  final dayKey = grouped.keys.elementAt(i);
                  final periods = grouped[dayKey]!;
                  final dayCount = periods.values.fold<int>(0, (s, l) => s + l.length);
                  final dayDur = hasDur ? _sumDur(periods.values.expand((l) => l).toList()) : 0;
                  final dayExtra = hasDur && dayDur > 0 ? ' · ${_fmtDurMin(dayDur)}' : '';
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Day header
                    Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
                      child: Text(_filter != 'all' ? '$dayKey ($dayCount$dayExtra)' : dayKey, style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary, fontWeight: FontWeight.bold))),
                    // Periods
                    for (final period in (periods.keys.toList()..sort((a, b) {
                        final aTime = periods[a]!.first.startTime;
                        final bTime = periods[b]!.first.startTime;
                        return bTime.compareTo(aTime);
                      })))
                      ...[
                        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: Builder(builder: (_) {
                            final pEvs = periods[period]!;
                            final pDur = hasDur ? _sumDur(pEvs) : 0;
                            final pExtra = hasDur && pDur > 0 ? ' · ${_fmtDurMin(pDur)}' : '';
                            return Text(_filter != 'all'
                              ? '${_periodDisplay(period, pEvs)} (${pEvs.length}$pExtra)'
                              : _periodDisplay(period, pEvs),
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                                color: Colors.grey.shade500));
                          })),
                        ...periods[period]!.map((event) => _EventTile(
                          event: event,
                          onDelete: () => _confirmDelete(event),
                          onEdit: () => _editEvent(event),
                        )),
                      ],
                  ]);
                },
              );
            },
          )),
        ],
      ),
    );
  }

  // For night events (midnight-6am), group with previous day
  DateTime _effectiveDay(DateTime dt) {
    if (dt.hour < 6) return dt.subtract(const Duration(days: 1));
    return dt;
  }

  String _dayLabel(DateTime dt) {
    final effective = _effectiveDay(dt);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final d = DateTime(effective.year, effective.month, effective.day);
    if (d == today) return 'Today';
    if (d == yesterday) return 'Yesterday';
    return DateFormat('EEEE, MMM d').format(effective);
  }

  void _confirmDelete(BabyEvent event) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete event?'),
      content: Text('Delete ${event.displayName} at ${DateFormat('HH:mm').format(event.startTime)}?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () async {
          Navigator.pop(ctx);
          await widget.service.deleteEvent(event.id);
        }, child: const Text('Delete', style: TextStyle(color: Colors.red))),
      ],
    ));
  }

  void _editEvent(BabyEvent event) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _EditEventSheet(event: event, service: widget.service),
    );
    if (result == true) setState(() {});
  }
}

class _Chip extends StatelessWidget {
  final String label; final bool selected; final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(onTap: onTap, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(20),
        color: selected ? Theme.of(context).colorScheme.primary.withOpacity(0.15) : null,
        border: Border.all(color: selected ? Theme.of(context).colorScheme.primary : Colors.grey.withOpacity(0.3))),
      child: Text(label, style: TextStyle(fontWeight: selected ? FontWeight.bold : FontWeight.normal, fontSize: 13,
        color: selected ? Theme.of(context).colorScheme.primary : Colors.grey.shade400)),
    ));
  }
}

class _EventTile extends StatelessWidget {
  final BabyEvent event; final VoidCallback onDelete; final VoidCallback onEdit;
  const _EventTile({required this.event, required this.onDelete, required this.onEdit});
  @override
  Widget build(BuildContext context) {
    final time = DateFormat('HH:mm').format(event.startTime);
    final props = <String>[];
    if (event.duration != null) props.add(event.durationText);
    if (event.side != null) props.add(event.side!);
    if (event.isOngoing) props.add('ongoing');

    return ListTile(
      leading: SizedBox(width: 48, child: Text(time, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.grey.shade400))),
      title: Text(event.displayName, style: const TextStyle(fontSize: 14)),
      subtitle: props.isNotEmpty ? Text(props.join(' · '), style: TextStyle(fontSize: 12, color: Colors.grey.shade500)) : null,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(icon: const Icon(Icons.edit_outlined, size: 20), onPressed: onEdit,
          color: Colors.grey.shade500),
        IconButton(icon: const Icon(Icons.delete_outline, size: 20), onPressed: onDelete,
          color: Colors.red.withOpacity(0.6)),
      ]),
    );
  }
}

class _EditEventSheet extends StatefulWidget {
  final BabyEvent event; final FirestoreService service;
  const _EditEventSheet({required this.event, required this.service});
  @override
  State<_EditEventSheet> createState() => _EditEventSheetState();
}

class _EditEventSheetState extends State<_EditEventSheet> {
  late DateTime _start;
  late int? _duration;
  late String? _side;
  late bool _pee;
  late bool _poop;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _start = widget.event.startTime;
    _duration = widget.event.durationMinutes;
    _side = widget.event.side;
    _pee = widget.event.pee;
    _poop = widget.event.poop;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      DateTime? endTime;
      if (_duration != null) endTime = _start.add(Duration(minutes: _duration!));
      final updated = BabyEvent(
        id: widget.event.id, type: widget.event.type, startTime: _start,
        endTime: endTime, durationMinutes: _duration, side: _side,
        pee: _pee, poop: _poop, createdBy: widget.event.createdBy, createdAt: widget.event.createdAt,
      );
      await widget.service.updateEvent(updated);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasDur = widget.event.type != EventType.diaper;
    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(color: Colors.grey.shade600, borderRadius: BorderRadius.circular(2)))),
        Text('Edit ${widget.event.displayName}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),

        ListTile(contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.access_time),
          title: Text(DateFormat('MMM d, HH:mm').format(_start)),
          trailing: const Icon(Icons.edit),
          onTap: () async {
            final date = await showDatePicker(context: context, initialDate: _start,
              firstDate: _start.subtract(const Duration(days: 30)), lastDate: DateTime.now());
            if (date == null || !mounted) return;
            final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_start));
            if (time == null) return;
            setState(() => _start = DateTime(date.year, date.month, date.day, time.hour, time.minute));
          },
        ),

        if (hasDur)
          ListTile(contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.timer),
            title: Text(_duration != null ? '$_duration min' : 'Ongoing'),
            trailing: const Icon(Icons.edit),
            onTap: () async {
              final c = TextEditingController(text: _duration?.toString() ?? '');
              final result = await showDialog<int>(context: context, builder: (ctx) => AlertDialog(
                title: const Text('Duration (minutes)'),
                content: TextField(controller: c, keyboardType: TextInputType.number, autofocus: true),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  TextButton(onPressed: () => Navigator.pop(ctx, int.tryParse(c.text)), child: const Text('OK')),
                ],
              ));
              if (result != null && result > 0) setState(() => _duration = result);
            },
          ),

        if (widget.event.type == EventType.feed)
          ListTile(contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.swap_horiz),
            title: Text('Side: ${_side ?? "none"}'),
            trailing: const Icon(Icons.edit),
            onTap: () => setState(() {
              if (_side == null) _side = 'left';
              else if (_side == 'left') _side = 'right';
              else _side = null;
            }),
          ),

        if (widget.event.type == EventType.diaper) ...[
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('💧 Pee'), value: _pee,
            onChanged: (v) => setState(() => _pee = v)),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('💩 Poop'), value: _poop,
            onChanged: (v) => setState(() => _poop = v)),
        ],

        const SizedBox(height: 16),
        SizedBox(width: double.infinity, height: 50, child: FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Text('Save Changes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        )),
      ]),
    );
  }
}
