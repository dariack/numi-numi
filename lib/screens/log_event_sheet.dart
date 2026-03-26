import 'package:flutter/material.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';

class LogEventSheet extends StatefulWidget {
  final EventType type;
  final FirestoreService service;
  final BabyEvent? ongoing;

  const LogEventSheet({super.key, required this.type, required this.service, this.ongoing});

  @override
  State<LogEventSheet> createState() => _LogEventSheetState();
}

class _LogEventSheetState extends State<LogEventSheet> {
  int _step = 0;
  DateTime _when = DateTime.now();
  int? _durationMin;
  bool _isOngoing = false;
  String? _side;
  bool _pee = false;
  bool _poop = false;
  bool _saving = false;
  bool _customTime = false;
  bool _customDuration = false;
  int _selectedQuickIdx = -1; // track which quick chip is selected

  bool get _hasDuration => widget.type == EventType.sleep || widget.type == EventType.feed;
  bool get _isNow => !_customTime && _selectedQuickIdx == 0;

  @override
  void initState() {
    super.initState();
    if (widget.ongoing != null) {
      _when = widget.ongoing!.startTime;
      _step = 1;
    } else {
      _selectedQuickIdx = 0; // default to "now"
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      BabyEvent? created;
      if (widget.ongoing != null) {
        final dur = _durationMin ?? DateTime.now().difference(_when).inMinutes;
        await widget.service.completeOngoing(widget.ongoing!.id, durationMinutes: dur);
      } else {
        DateTime? endTime;
        if (_hasDuration && _durationMin != null) {
          endTime = _when.add(Duration(minutes: _durationMin!));
        }
        final event = BabyEvent(
          id: '', type: widget.type, startTime: _when,
          endTime: endTime, durationMinutes: _isOngoing ? null : _durationMin,
          side: widget.type == EventType.feed ? _side : null,
          pee: _pee, poop: _poop, createdBy: 'app',
        );
        created = await widget.service.addEvent(event);
      }
      if (mounted) Navigator.pop(context, created ?? true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        setState(() => _saving = false);
      }
    }
  }

  void _nextStep() {
    if (_step == 0) {
      if (widget.type == EventType.diaper) {
        setState(() => _step = 2);
      } else if (_isNow) {
        // Started NOW → auto-ongoing, skip duration
        if (widget.type == EventType.feed) {
          _isOngoing = true;
          _durationMin = null;
          setState(() => _step = 3); // go to side
        } else {
          _isOngoing = true;
          _durationMin = null;
          _save();
        }
      } else {
        setState(() => _step = 1);
      }
    } else if (_step == 1) {
      if (widget.type == EventType.feed) {
        setState(() => _step = 3);
      } else {
        _save();
      }
    } else if (_step == 2) {
      if (!_pee && !_poop) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select at least pee or poop')));
        return;
      }
      _save();
    } else if (_step == 3) {
      _save();
    }
  }

  String get _title {
    if (widget.ongoing != null) {
      return '${_typeEmoji} End ${_typeName}';
    }
    return '$_typeEmoji Log ${_typeName}';
  }

  String get _typeEmoji {
    switch (widget.type) {
      case EventType.sleep: return '😴';
      case EventType.feed: return '🍼';
      case EventType.diaper: return '🧷';
    }
  }

  String get _typeName {
    switch (widget.type) {
      case EventType.sleep: return 'Sleep';
      case EventType.feed: return 'Feed';
      case EventType.diaper: return 'Diaper Change';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(color: Colors.grey.shade600, borderRadius: BorderRadius.circular(2)))),
        Text(_title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        if (_step == 0) _buildWhenStep(),
        if (_step == 1) _buildDurationStep(),
        if (_step == 2) _buildDiaperStep(),
        if (_step == 3) _buildSideStep(),
      ]),
    );
  }

  Widget _buildWhenStep() {
    final now = DateTime.now();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('When did this happen?', style: TextStyle(fontSize: 15, color: Colors.grey.shade400)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _QuickBtn(label: 'Now', selected: _selectedQuickIdx == 0 && !_customTime,
          onTap: () => setState(() { _when = DateTime.now(); _customTime = false; _selectedQuickIdx = 0; })),
        _QuickBtn(label: '15m ago', selected: _selectedQuickIdx == 1 && !_customTime,
          onTap: () => setState(() { _when = now.subtract(const Duration(minutes: 15)); _customTime = false; _selectedQuickIdx = 1; })),
        _QuickBtn(label: '30m ago', selected: _selectedQuickIdx == 2 && !_customTime,
          onTap: () => setState(() { _when = now.subtract(const Duration(minutes: 30)); _customTime = false; _selectedQuickIdx = 2; })),
        _QuickBtn(label: '1h ago', selected: _selectedQuickIdx == 3 && !_customTime,
          onTap: () => setState(() { _when = now.subtract(const Duration(hours: 1)); _customTime = false; _selectedQuickIdx = 3; })),
      ]),
      const SizedBox(height: 8),
      GestureDetector(
        onTap: () async {
          final date = await showDatePicker(context: context, initialDate: _when, firstDate: now.subtract(const Duration(days: 30)), lastDate: now);
          if (date == null || !mounted) return;
          final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_when));
          if (time == null) return;
          final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
          if (dt.isAfter(now)) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot be in the future'))); return; }
          setState(() { _when = dt; _customTime = true; _selectedQuickIdx = -1; });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _customTime ? Theme.of(context).colorScheme.primary : Colors.grey.withOpacity(0.3))),
          child: Row(children: [
            Icon(Icons.edit_calendar, size: 18, color: Colors.grey.shade400), const SizedBox(width: 8),
            Text(_customTime ? _fmtDateTime(_when) : 'Pick custom time',
              style: TextStyle(color: _customTime ? null : Colors.grey.shade500)),
          ]),
        ),
      ),
      if (_isNow && _hasDuration) ...[
        const SizedBox(height: 10),
        Text('Event will be logged as ongoing', style: TextStyle(fontSize: 12, color: Colors.orange.shade400, fontStyle: FontStyle.italic)),
      ],
      const SizedBox(height: 16),
      _NextButton(onTap: _nextStep, label: _isNow && _hasDuration && widget.type != EventType.feed ? 'Save' : 'Next'),
    ]);
  }

  Widget _buildDurationStep() {
    final isSleep = widget.type == EventType.sleep;
    final quickOptions = isSleep ? [30, 60, 120, 180] : [10, 15, 20, 30];
    final quickLabels = isSleep ? ['30m', '1h', '2h', '3h'] : ['10m', '15m', '20m', '30m'];
    final isEnding = widget.ongoing != null;
    final endNowMin = isEnding ? DateTime.now().difference(_when).inMinutes : 0;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('How long?', style: TextStyle(fontSize: 15, color: Colors.grey.shade400)),
      const SizedBox(height: 4),
      Text('Started at ${_fmtTime(_when)}', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (isEnding)
          _QuickBtn(label: '⏹ End now (${endNowMin}m)', selected: _durationMin == endNowMin && !_isOngoing,
            color: Colors.red,
            onTap: () => setState(() { _durationMin = endNowMin; _isOngoing = false; _customDuration = false; })),
        for (int i = 0; i < quickOptions.length; i++)
          _QuickBtn(label: quickLabels[i], selected: _durationMin == quickOptions[i] && !_isOngoing,
            onTap: () => setState(() { _durationMin = quickOptions[i]; _isOngoing = false; _customDuration = false; })),
        if (!isEnding)
          _QuickBtn(label: '⏱ Still ongoing', selected: _isOngoing, color: Colors.orange,
            onTap: () => setState(() { _isOngoing = true; _durationMin = null; _customDuration = false; })),
      ]),
      const SizedBox(height: 8),
      if (!_isOngoing)
        GestureDetector(
          onTap: () async {
            final c = TextEditingController(text: _durationMin?.toString() ?? '');
            final result = await showDialog<int>(context: context, builder: (ctx) => AlertDialog(
              title: const Text('Duration (minutes)'),
              content: TextField(controller: c, keyboardType: TextInputType.number, autofocus: true, decoration: const InputDecoration(hintText: 'e.g. 45')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                TextButton(onPressed: () => Navigator.pop(ctx, int.tryParse(c.text)), child: const Text('OK')),
              ],
            ));
            if (result != null && result > 0) setState(() { _durationMin = result; _customDuration = true; });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _customDuration ? Theme.of(context).colorScheme.primary : Colors.grey.withOpacity(0.3))),
            child: Row(children: [
              Icon(Icons.timer, size: 18, color: Colors.grey.shade400), const SizedBox(width: 8),
              Text(_customDuration ? '$_durationMin minutes' : 'Custom duration',
                style: TextStyle(color: _customDuration ? null : Colors.grey.shade500)),
            ]),
          ),
        ),
      const SizedBox(height: 16),
      _NextButton(onTap: () {
        if (!_isOngoing && _durationMin == null) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick a duration or "Still ongoing"')));
          return;
        }
        _nextStep();
      }, label: widget.type == EventType.feed ? 'Next' : 'Save', saving: _saving),
    ]);
  }

  Widget _buildDiaperStep() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('What was in the diaper?', style: TextStyle(fontSize: 15, color: Colors.grey.shade400)),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _ToggleBtn(emoji: '💧', label: 'Pee', selected: _pee, onTap: () => setState(() => _pee = !_pee))),
        const SizedBox(width: 10),
        Expanded(child: _ToggleBtn(emoji: '💩', label: 'Poop', selected: _poop, onTap: () => setState(() => _poop = !_poop))),
      ]),
      const SizedBox(height: 8),
      GestureDetector(
        onTap: () => setState(() { _pee = true; _poop = true; }),
        child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
            border: Border.all(color: (_pee && _poop) ? Colors.purple : Colors.grey.withOpacity(0.3)),
            color: (_pee && _poop) ? Colors.purple.withOpacity(0.1) : null),
          child: Center(child: Text('🧷 Both', style: TextStyle(fontWeight: FontWeight.bold, color: (_pee && _poop) ? Colors.purple : Colors.grey.shade500)))),
      ),
      const SizedBox(height: 16),
      _NextButton(onTap: _nextStep, label: 'Save', saving: _saving),
    ]);
  }

  Widget _buildSideStep() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Which side? (optional)', style: TextStyle(fontSize: 15, color: Colors.grey.shade400)),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _ToggleBtn(emoji: '🤱', label: 'Left', selected: _side == 'left', onTap: () => setState(() => _side = _side == 'left' ? null : 'left'))),
        const SizedBox(width: 10),
        Expanded(child: _ToggleBtn(emoji: '🤱', label: 'Right', selected: _side == 'right', onTap: () => setState(() => _side = _side == 'right' ? null : 'right'))),
      ]),
      const SizedBox(height: 16),
      _NextButton(onTap: () => _save(), label: 'Save', saving: _saving),
    ]);
  }

  String _fmtTime(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  String _fmtDateTime(DateTime d) => '${d.day}/${d.month} ${_fmtTime(d)}';
}

class _QuickBtn extends StatelessWidget {
  final String label; final bool selected; final VoidCallback onTap; final Color? color;
  const _QuickBtn({required this.label, required this.selected, required this.onTap, this.color});
  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return GestureDetector(onTap: onTap, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
        color: selected ? c.withOpacity(0.15) : null,
        border: Border.all(color: selected ? c : Colors.grey.withOpacity(0.3), width: selected ? 2 : 1)),
      child: Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: selected ? c : Colors.grey.shade400)),
    ));
  }
}

class _ToggleBtn extends StatelessWidget {
  final String emoji; final String label; final bool selected; final VoidCallback onTap;
  const _ToggleBtn({required this.emoji, required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.primary;
    return GestureDetector(onTap: onTap, child: Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14),
        color: selected ? c.withOpacity(0.12) : null,
        border: Border.all(color: selected ? c : Colors.grey.withOpacity(0.3), width: selected ? 2 : 1)),
      child: Column(children: [
        Text(emoji, style: const TextStyle(fontSize: 28)), const SizedBox(height: 4),
        Text(label, style: TextStyle(fontWeight: FontWeight.bold, color: selected ? c : Colors.grey.shade400)),
      ]),
    ));
  }
}

class _NextButton extends StatelessWidget {
  final VoidCallback onTap; final String label; final bool saving;
  const _NextButton({required this.onTap, required this.label, this.saving = false});
  @override
  Widget build(BuildContext context) {
    return SizedBox(width: double.infinity, height: 50, child: FilledButton(
      onPressed: saving ? null : onTap,
      child: saving ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
        : Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
    ));
  }
}
