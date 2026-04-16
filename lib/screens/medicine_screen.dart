import 'package:flutter/material.dart';
import '../models/medicine.dart';
import '../services/medicine_service.dart';

class MedicineScreen extends StatelessWidget {
  final MedicineService service;
  const MedicineScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('💊 Medicines'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _openSheet(context, null),
          ),
        ],
      ),
      body: StreamBuilder<List<Medicine>>(
        stream: service.medicinesStream(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final medicines = snap.data ?? [];
          if (medicines.isEmpty) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('💊', style: TextStyle(fontSize: 48)),
                const SizedBox(height: 12),
                Text('No medicines set up yet',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
                const SizedBox(height: 20),
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add Medicine'),
                  onPressed: () => _openSheet(context, null),
                ),
              ]),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: medicines.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final m = medicines[i];
              return _MedicineCard(
                medicine: m,
                onEdit: () => _openSheet(context, m),
                onDelete: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text('Remove ${m.name}?'),
                      content: const Text('This will hide the medicine. History is kept.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        TextButton(onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Remove', style: TextStyle(color: Colors.red))),
                      ],
                    ),
                  );
                  if (confirm == true) await service.deleteMedicine(m.id);
                },
              );
            },
          );
        },
      ),
    );
  }

  void _openSheet(BuildContext context, Medicine? existing) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _MedicineSheet(service: service, existing: existing),
    );
  }
}

// ── Card ──────────────────────────────────────────────────────────────
class _MedicineCard extends StatelessWidget {
  final Medicine medicine;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _MedicineCard({required this.medicine, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: isDark ? const Color(0xFF1E2130) : Colors.white,
        border: Border.all(color: isDark ? Colors.grey.shade800 : Colors.grey.shade200),
      ),
      child: Row(children: [
        const Text('💊', style: TextStyle(fontSize: 28)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(medicine.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          if (medicine.dose != null)
            Text(medicine.dose!, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          const SizedBox(height: 2),
          Text(medicine.scheduleDescription,
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary)),
        ])),
        IconButton(icon: const Icon(Icons.edit_outlined, size: 20), onPressed: onEdit,
            color: Colors.grey.shade400),
        IconButton(icon: const Icon(Icons.delete_outline, size: 20), onPressed: onDelete,
            color: Colors.red.withOpacity(0.6)),
      ]),
    );
  }
}

// ── Add/Edit sheet ────────────────────────────────────────────────────
class _MedicineSheet extends StatefulWidget {
  final MedicineService service;
  final Medicine? existing;
  const _MedicineSheet({required this.service, this.existing});
  @override
  State<_MedicineSheet> createState() => _MedicineSheetState();
}

class _MedicineSheetState extends State<_MedicineSheet> {
  final _nameCtrl = TextEditingController();
  final _doseCtrl = TextEditingController();
  ScheduleType _scheduleType = ScheduleType.onceDailyAt;
  List<String> _times = ['08:00'];
  List<int> _days = []; // for specificDays
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final m = widget.existing;
    if (m != null) {
      _nameCtrl.text = m.name;
      _doseCtrl.text = m.dose ?? '';
      _scheduleType = m.scheduleType;
      _times = List.from(m.timesOfDay.isNotEmpty ? m.timesOfDay : ['08:00']);
      _days = List.from(m.daysOfWeek);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _doseCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickTime(int index) async {
    final parts = _times[index].split(':');
    final initial = TimeOfDay(
        hour: int.tryParse(parts[0]) ?? 8,
        minute: int.tryParse(parts[1]) ?? 0);
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) {
      setState(() {
        _times[index] =
            '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      });
    }
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a medicine name')));
      return;
    }
    if (_scheduleType != ScheduleType.asNeeded && _times.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add at least one time')));
      return;
    }

    setState(() => _saving = true);
    final m = Medicine(
      id: widget.existing?.id ?? '',
      name: name,
      dose: _doseCtrl.text.trim().isNotEmpty ? _doseCtrl.text.trim() : null,
      scheduleType: _scheduleType,
      timesOfDay: _scheduleType == ScheduleType.asNeeded ? [] : List.from(_times),
      daysOfWeek: _scheduleType == ScheduleType.specificDays ? List.from(_days) : [],
      active: true,
      createdAt: widget.existing?.createdAt ?? DateTime.now(),
    );

    if (widget.existing != null) {
      await service.updateMedicine(m);
    } else {
      await service.addMedicine(m);
    }
    if (mounted) Navigator.pop(context);
  }

  MedicineService get service => widget.service;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(color: Colors.grey.shade600, borderRadius: BorderRadius.circular(2)))),
        Text(widget.existing != null ? '✏️ Edit Medicine' : '💊 Add Medicine',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),

        // Name
        _label('Name'),
        const SizedBox(height: 6),
        TextField(
          controller: _nameCtrl,
          autofocus: widget.existing == null,
          decoration: InputDecoration(
            hintText: 'e.g. Vitamin D, Iron drops',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),

        // Dose (optional)
        _label('Dose (optional)'),
        const SizedBox(height: 6),
        TextField(
          controller: _doseCtrl,
          decoration: InputDecoration(
            hintText: 'e.g. 0.5ml, 1 drop',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),

        // Schedule type
        _label('Schedule'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _ScheduleChip(label: 'Once daily', selected: _scheduleType == ScheduleType.onceDailyAt,
            onTap: () => setState(() { _scheduleType = ScheduleType.onceDailyAt; if (_times.isEmpty) _times = ['08:00']; if (_times.length > 1) _times = [_times.first]; })),
          _ScheduleChip(label: 'Multiple times', selected: _scheduleType == ScheduleType.customTimes,
            onTap: () => setState(() { _scheduleType = ScheduleType.customTimes; if (_times.isEmpty) _times = ['08:00']; })),
          _ScheduleChip(label: 'Specific days', selected: _scheduleType == ScheduleType.specificDays,
            onTap: () => setState(() { _scheduleType = ScheduleType.specificDays; if (_times.isEmpty) _times = ['08:00']; })),
          _ScheduleChip(label: 'As needed', selected: _scheduleType == ScheduleType.asNeeded,
            onTap: () => setState(() => _scheduleType = ScheduleType.asNeeded)),
        ]),
        const SizedBox(height: 14),

        // Days of week picker (specificDays only)
        if (_scheduleType == ScheduleType.specificDays) ...[
          _label('Days'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: List.generate(7, (i) {
            final sel = _days.contains(i);
            return GestureDetector(
              onTap: () => setState(() { if (sel) _days.remove(i); else _days.add(i); }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: sel ? Theme.of(context).colorScheme.primary : Colors.grey.withOpacity(0.3), width: sel ? 2 : 1),
                  color: sel ? Theme.of(context).colorScheme.primary.withOpacity(0.12) : null,
                ),
                child: Text(dayLabels[i], style: TextStyle(
                    fontSize: 13, fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                    color: sel ? Theme.of(context).colorScheme.primary : Colors.grey.shade400)),
              ),
            );
          })),
          const SizedBox(height: 14),
        ],

        // Time slots
        if (_scheduleType != ScheduleType.asNeeded) ...[
          _label('Time${_times.length > 1 ? 's' : ''}'),
          const SizedBox(height: 8),
          ..._times.asMap().entries.map((entry) {
            final i = entry.key;
            final t = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(child: GestureDetector(
                  onTap: () => _pickTime(i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.5)),
                      color: Theme.of(context).colorScheme.primary.withOpacity(0.06),
                    ),
                    child: Row(children: [
                      Icon(Icons.access_time, size: 18, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(t, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.primary)),
                    ]),
                  ),
                )),
                if (_scheduleType == ScheduleType.customTimes && _times.length > 1)
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                    onPressed: () => setState(() => _times.removeAt(i)),
                  ),
              ]),
            );
          }),
          if (_scheduleType == ScheduleType.customTimes)
            TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add time'),
              onPressed: () => setState(() => _times.add('12:00')),
            ),
          const SizedBox(height: 6),
        ],

        const SizedBox(height: 10),
        SizedBox(width: double.infinity, height: 50,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(widget.existing != null ? 'Save Changes' : 'Add Medicine',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          )),
      ])),
    );
  }

  Widget _label(String text) =>
      Text(text, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade400));
}

class _ScheduleChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ScheduleChip({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? c : Colors.grey.withOpacity(0.3), width: selected ? 2 : 1),
          color: selected ? c.withOpacity(0.12) : null,
        ),
        child: Text(label, style: TextStyle(
            fontSize: 13, fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? c : Colors.grey.shade400)),
      ),
    );
  }
}
