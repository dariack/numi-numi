import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../services/widget_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/reminder_service.dart';
import '../services/notification_service.dart';
import '../models/reminder_settings.dart';

class SettingsScreen extends StatefulWidget {
  final SettingsService settingsService;
  final ReminderService? reminderService;
  final String familyId;
  final VoidCallback onChangeFamilyId;

  const SettingsScreen({
    super.key,
    required this.settingsService,
    this.reminderService,
    required this.familyId,
    required this.onChangeFamilyId,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  TrackerSettings _settings = const TrackerSettings();
  bool _loading = true;
  List<String> _widgetSlots = ['feed', 'diaper'];
  DateTime? _birthDate;
  ReminderSettings _reminders = const ReminderSettings();
  final _nameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await widget.settingsService.get();
    final slots = await WidgetService.getWidgetSlots();
    final bd = await widget.settingsService.getBirthDate();
    final reminders = await widget.reminderService?.loadSettings() ?? const ReminderSettings();
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('caregiver_name') ?? '';
    if (mounted) setState(() { _settings = s; _widgetSlots = slots; _birthDate = bd; _reminders = reminders; _nameCtrl.text = name; _loading = false; });
  }

  Future<void> _updateReminders(ReminderSettings updated) async {
    setState(() => _reminders = updated);
    await widget.reminderService?.updateSettings(updated);
  }

  Future<void> _showPendingDebug() async {
    final pending = await NotificationService.instance.getPending();
    if (!mounted) return;
    final msg = pending.isEmpty ? 'None scheduled'
        : pending.map((p) {
            return '#' + p.id.toString() + ': ' + (p.title ?? '') + '\n' + (p.body ?? '');
          }).join('\n\n');
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Scheduled Notifications'),
      content: Text(msg),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
    ));
  }

  Widget _buildReminderSection(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c = Theme.of(context).colorScheme.primary;
    final cardBg = isDark ? const Color(0xFF1E2130) : Colors.white;
    final borderColor = isDark ? Colors.grey.shade800 : Colors.grey.shade200;

    Widget thresholdPicker(int current, void Function(int) onSelect) {
      return Row(children: [2, 3, 4].map((h) {
        final sel = current == h;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onTap: () => onSelect(h),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: sel ? c : Colors.grey.withOpacity(0.3), width: sel ? 2 : 1),
                color: sel ? c.withOpacity(0.12) : null,
              ),
              child: Text(h.toString() + 'h', style: TextStyle(
                fontSize: 13, fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                color: sel ? c : Colors.grey.shade400)),
            ),
          ),
        );
      }).toList());
    }

    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
          color: cardBg, border: Border.all(color: borderColor)),
      child: Column(children: [
        SwitchListTile(
          title: const Text('🍼 Feed reminder'),
          subtitle: Text(_reminders.feedEnabled
              ? 'Remind after ' + _reminders.feedThresholdHours.toString() + 'h'
              : 'Off', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          value: _reminders.feedEnabled,
          onChanged: (v) => _updateReminders(_reminders.copyWith(feedEnabled: v)),
        ),
        if (_reminders.feedEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              Text('Remind after: ', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
              thresholdPicker(_reminders.feedThresholdHours,
                  (h) => _updateReminders(_reminders.copyWith(feedThresholdHours: h))),
            ]),
          ),
        Divider(height: 1, color: borderColor),
        SwitchListTile(
          title: const Text('🧷 Diaper reminder'),
          subtitle: Text(_reminders.diaperEnabled
              ? 'Remind after ' + _reminders.diaperThresholdHours.toString() + 'h'
              : 'Off', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          value: _reminders.diaperEnabled,
          onChanged: (v) => _updateReminders(_reminders.copyWith(diaperEnabled: v)),
        ),
        if (_reminders.diaperEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              Text('Remind after: ', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
              thresholdPicker(_reminders.diaperThresholdHours,
                  (h) => _updateReminders(_reminders.copyWith(diaperThresholdHours: h))),
            ]),
          ),
        Divider(height: 1, color: borderColor),
        SwitchListTile(
          title: const Text('🌙 Quiet hours'),
          subtitle: Text(_reminders.quietHoursEnabled
              ? 'No reminders ' + _reminders.quietFrom + ' – ' + _reminders.quietTo
              : 'Off', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          value: _reminders.quietHoursEnabled,
          onChanged: (v) => _updateReminders(_reminders.copyWith(quietHoursEnabled: v)),
        ),
        if (_reminders.quietHoursEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              _TimePickerTile(label: 'From', time: _reminders.quietFrom,
                  onChanged: (t) => _updateReminders(_reminders.copyWith(quietFrom: t))),
              const SizedBox(width: 16),
              _TimePickerTile(label: 'To', time: _reminders.quietTo,
                  onChanged: (t) => _updateReminders(_reminders.copyWith(quietTo: t))),
            ]),
          ),
      ]),
    );
  }

  Future<void> _toggleWidgetSlot(String type) async {
    List<String> newSlots = List.from(_widgetSlots);
    if (newSlots.contains(type)) {
      if (newSlots.length <= 1) return; // must keep at least 1
      newSlots.remove(type);
    } else {
      if (newSlots.length >= 2) newSlots.removeAt(0); // drop oldest
      newSlots.add(type);
    }
    await WidgetService.setWidgetSlots(newSlots[0], newSlots.length > 1 ? newSlots[1] : newSlots[0]);
    if (mounted) setState(() => _widgetSlots = newSlots);
  }

  Future<void> _toggle(String key) async {
    TrackerSettings updated;
    switch (key) {
      case 'trackSleep':
        updated = _settings.copyWith(trackSleep: !_settings.trackSleep);
        break;
      case 'trackFeed':
        updated = _settings.copyWith(trackFeed: !_settings.trackFeed);
        break;
      case 'trackDiaper':
        updated = _settings.copyWith(trackDiaper: !_settings.trackDiaper);
        break;
      case 'trackPump':
        updated = _settings.copyWith(trackPump: !_settings.trackPump);
        break;
      default:
        return;
    }
    setState(() => _settings = updated);
    await widget.settingsService.save(updated);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final items = [
      _ToggleItem(
        emoji: '😴',
        title: 'Sleep',
        subtitle: 'Track sleep/wake events',
        value: _settings.trackSleep,
        onToggle: () => _toggle('trackSleep'),
      ),
      _ToggleItem(
        emoji: '🍼',
        title: 'Feed',
        subtitle: 'Track feeding events',
        value: _settings.trackFeed,
        onToggle: () => _toggle('trackFeed'),
      ),
      _ToggleItem(
        emoji: '🧷',
        title: 'Diaper',
        subtitle: 'Track diaper changes',
        value: _settings.trackDiaper,
        onToggle: () => _toggle('trackDiaper'),
      ),
      _ToggleItem(
        emoji: '🥛',
        title: 'Pump',
        subtitle: 'Track breast milk pumping & stock',
        value: _settings.trackPump,
        onToggle: () => _toggle('trackPump'),
      ),
    ];

    return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SafeArea(child: SizedBox(height: 8)),
          Text('Track Actions',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade500,
                  letterSpacing: 0.5)),
          const SizedBox(height: 12),
          ...items.map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _SettingsToggle(item: item),
              )),
          const SizedBox(height: 24),
          Text('Baby',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                  color: Colors.grey.shade500, letterSpacing: 0.5)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.grey.shade800 : Colors.grey.shade200),
            ),
            child: Row(children: [
              const Text('📅', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Birth Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                Text(_birthDate != null
                    ? '${_birthDate!.day.toString().padLeft(2,'0')}/${_birthDate!.month.toString().padLeft(2,'0')}/${_birthDate!.year}'
                    : 'Not set',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              ])),
              TextButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _birthDate ?? DateTime.now().subtract(const Duration(days: 60)),
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                    helpText: 'Select birth date',
                  );
                  if (picked != null) {
                    await widget.settingsService.saveBirthDate(picked);
                    if (mounted) setState(() => _birthDate = picked);
                  }
                },
                child: Text(_birthDate != null ? 'Change' : 'Set'),
              ),
            ]),
          ),
          const SizedBox(height: 24),
          Text('Widget',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade500,
                  letterSpacing: 0.5)),
          const SizedBox(height: 8),
          Text('Choose 2 actions to show on your home screen widget:',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final opt in [
              {'type': 'feed',   'label': '🍼 Feed'},
              {'type': 'sleep',  'label': '😴 Sleep'},
              {'type': 'diaper', 'label': '🧷 Diaper'},
              {'type': 'pump',   'label': '🥛 Pump'},
            ])
              GestureDetector(
                onTap: () => _toggleWidgetSlot(opt['type']!),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _widgetSlots.contains(opt['type'])
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey.withOpacity(0.3),
                      width: _widgetSlots.contains(opt['type']) ? 2 : 1,
                    ),
                    color: _widgetSlots.contains(opt['type'])
                        ? Theme.of(context).colorScheme.primary.withOpacity(0.12)
                        : null,
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(opt['label']!, style: TextStyle(
                      fontSize: 14,
                      fontWeight: _widgetSlots.contains(opt['type'])
                          ? FontWeight.bold : FontWeight.normal,
                      color: _widgetSlots.contains(opt['type'])
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey.shade400,
                    )),
                    if (_widgetSlots.contains(opt['type'])) ...[
                      const SizedBox(width: 6),
                      Text(
                        '${_widgetSlots.indexOf(opt['type']!) + 1}',
                        style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ]),
                ),
              ),
          ]),
          const SizedBox(height: 24),
          Row(children: [
            Text('Reminders',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                    color: Colors.grey.shade500, letterSpacing: 0.5)),
            const Spacer(),
            TextButton(
              onPressed: _showPendingDebug,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(44, 32),
              ),
              child: Text('check scheduled',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500,
                      fontStyle: FontStyle.italic))),
          ]),
          const SizedBox(height: 8),
          _buildReminderSection(context),
          const SizedBox(height: 24),
          Text('Family',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade500,
                  letterSpacing: 0.5)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.grey.shade800
                      : Colors.grey.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Caregiver name
                TextField(
                  controller: _nameCtrl,
                  decoration: InputDecoration(
                    labelText: 'Your name',
                    hintText: 'e.g. Daria, Mom, Nanny',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onSubmitted: (v) async {
                    final p = await SharedPreferences.getInstance();
                    await p.setString('caregiver_name', v.trim());
                  },
                  onEditingComplete: () async {
                    final p = await SharedPreferences.getInstance();
                    await p.setString('caregiver_name', _nameCtrl.text.trim());
                  },
                ),
                const SizedBox(height: 12),
                Text('Code: \${widget.familyId}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: widget.onChangeFamilyId,
                  child: Text('Change family code',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                ),
              ],
            ),
          ),
        ],
    );
  }
}

class _ToggleItem {
  final String emoji;
  final String title;
  final String subtitle;
  final bool value;
  final VoidCallback onToggle;

  _ToggleItem({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onToggle,
  });
}

class _SettingsToggle extends StatelessWidget {
  final _ToggleItem item;
  const _SettingsToggle({required this.item});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isDark ? Colors.grey.shade800 : Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Text(item.emoji, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
                Text(item.subtitle,
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              ],
            ),
          ),
          Switch(
            value: item.value,
            onChanged: (_) => item.onToggle(),
          ),
        ],
      ),
    );
  }
}

class _TimePickerTile extends StatelessWidget {
  final String label;
  final String time; // "HH:MM"
  final void Function(String) onChanged;
  const _TimePickerTile({required this.label, required this.time, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final parts = time.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts[0]) ?? 22,
      minute: int.tryParse(parts[1]) ?? 0,
    );
    return GestureDetector(
      onTap: () async {
        final picked = await showTimePicker(context: context, initialTime: initial);
        if (picked != null) {
          final newTime =
              '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
          onChanged(newTime);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.5)),
          color: Theme.of(context).colorScheme.primary.withOpacity(0.06),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          const SizedBox(width: 6),
          Text(time, style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary)),
        ]),
      ),
    );
  }
}
