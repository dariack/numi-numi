import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/settings_service.dart';
import '../services/widget_service.dart';
import '../services/reminder_service.dart';
import 'medicine_screen.dart';
import '../services/medicine_service.dart';
import '../services/notification_service.dart';
import '../models/reminder_settings.dart';

class SettingsScreen extends StatefulWidget {
  final SettingsService settingsService;
  final ReminderService? reminderService;
  final MedicineService? medicineService;
  final String familyId;
  final VoidCallback onChangeFamilyId;

  const SettingsScreen({
    super.key,
    required this.settingsService,
    this.reminderService,
    this.medicineService,
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s        = await widget.settingsService.get();
    final slots    = await WidgetService.getWidgetSlots();
    final bd       = await widget.settingsService.getBirthDate();
    final reminders = await widget.reminderService?.loadSettings() ?? const ReminderSettings();
    if (mounted) {
      setState(() {
        _settings = s; _widgetSlots = slots; _birthDate = bd; _reminders = reminders;
        _loading = false;
      });
    }
  }

  Future<void> _updateReminders(ReminderSettings updated) async {
    setState(() => _reminders = updated);
    await widget.reminderService?.updateSettings(updated);
  }

  Future<void> _showPendingDebug() async {
    final pending = await NotificationService.instance.getPending();
    if (!mounted) return;
    final msg = pending.isEmpty
        ? 'None scheduled'
        : pending.map((p) => '#${p.id}: ${p.title ?? ''}\n${p.body ?? ''}').join('\n\n');
    showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Scheduled Notifications'),
          content: Text(msg),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ));
  }

  Future<void> _toggleWidgetSlot(String type) async {
    final newSlots = List<String>.from(_widgetSlots);
    if (newSlots.contains(type)) {
      if (newSlots.length <= 1) return;
      newSlots.remove(type);
    } else {
      if (newSlots.length >= 2) newSlots.removeAt(0);
      newSlots.add(type);
    }
    await WidgetService.setWidgetSlots(
        newSlots[0], newSlots.length > 1 ? newSlots[1] : newSlots[0]);
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

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E2130) : Colors.white;
    final borderColor = isDark ? Colors.grey.shade800 : Colors.grey.shade200;
    final c = Theme.of(context).colorScheme.primary;

    Widget sectionLabel(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: TextStyle(
          fontSize: 10, fontWeight: FontWeight.w700,
          color: Colors.grey.shade500, letterSpacing: 0.5)),
    );

    Widget card({required Widget child}) => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: cardBg,
        border: Border.all(color: borderColor),
      ),
      child: child,
    );

    Widget thresholdPicker(int current, void Function(int) onSelect) {
      return Row(children: [2, 3, 4].map((h) {
        final sel = current == h;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              onSelect(h);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: sel ? c : Colors.grey.withOpacity(0.3), width: sel ? 2 : 1),
                color: sel ? c.withOpacity(0.12) : null,
              ),
              child: Text(h.toString() + 'h', style: TextStyle(
                  fontSize: 13,
                  fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                  color: sel ? c : Colors.grey.shade400)),
            ),
          ),
        );
      }).toList());
    }

    // ── Tab 1: General ───────────────────────────────────────────
    Widget generalTab() => ListView(padding: const EdgeInsets.all(16), children: [
      sectionLabel('TRACKING'),
      card(child: Column(children: [
        _TrackTile(
          emoji: '😴', title: 'Sleep', subtitle: 'Track sleep/wake events',
          value: _settings.trackSleep,
          onChanged: (v) { HapticFeedback.lightImpact(); _toggle('trackSleep'); },
        ),
        Divider(height: 1, color: borderColor),
        _TrackTile(
          emoji: '🍼', title: 'Feed', subtitle: 'Track feeding events',
          value: _settings.trackFeed,
          onChanged: (v) { HapticFeedback.lightImpact(); _toggle('trackFeed'); },
        ),
        Divider(height: 1, color: borderColor),
        _TrackTile(
          emoji: '🧷', title: 'Diaper', subtitle: 'Track diaper changes',
          value: _settings.trackDiaper,
          onChanged: (v) { HapticFeedback.lightImpact(); _toggle('trackDiaper'); },
        ),
        Divider(height: 1, color: borderColor),
        _TrackTile(
          emoji: '🥛', title: 'Pump', subtitle: 'Track pumping & milk stock',
          value: _settings.trackPump,
          onChanged: (v) { HapticFeedback.lightImpact(); _toggle('trackPump'); },
        ),
      ])),

      sectionLabel('WIDGET'),
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text('Choose 2 actions for your home screen widget:',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
      ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final opt in [
          {'type': 'feed',   'label': '🍼 Feed'},
          {'type': 'sleep',  'label': '😴 Sleep'},
          {'type': 'diaper', 'label': '🧷 Diaper'},
          {'type': 'pump',   'label': '🥛 Pump'},
        ])
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              _toggleWidgetSlot(opt['type']!);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _widgetSlots.contains(opt['type']) ? c : Colors.grey.withOpacity(0.3),
                  width: _widgetSlots.contains(opt['type']) ? 2 : 1,
                ),
                color: _widgetSlots.contains(opt['type']) ? c.withOpacity(0.12) : null,
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(opt['label']!, style: TextStyle(
                    fontSize: 13,
                    fontWeight: _widgetSlots.contains(opt['type'])
                        ? FontWeight.bold : FontWeight.normal,
                    color: _widgetSlots.contains(opt['type']) ? c : Colors.grey.shade400)),
                if (_widgetSlots.contains(opt['type']!)) ...[
                  const SizedBox(width: 6),
                  Text('${_widgetSlots.indexOf(opt['type']!) + 1}',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold, color: c)),
                ],
              ]),
            ),
          ),
      ]),
      const SizedBox(height: 24),
    ]);

    // ── Tab 2: Baby & Family ─────────────────────────────────────
    Widget babyTab() => ListView(padding: const EdgeInsets.all(16), children: [
      sectionLabel('BABY'),
      card(child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          const Text('📅', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Birth Date', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            Text(
              _birthDate != null
                  ? '${_birthDate!.day.toString().padLeft(2, "0")}/${_birthDate!.month.toString().padLeft(2, "0")}/${_birthDate!.year}'
                  : 'Not set',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ])),
          TextButton(
            onPressed: () async {
              HapticFeedback.lightImpact();
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
            child: Text(_birthDate != null ? 'Change' : 'Set',
                style: const TextStyle(fontSize: 13)),
          ),
        ]),
      )),

      if (widget.medicineService != null) ...[
        sectionLabel('MEDICINE'),
        card(child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            HapticFeedback.lightImpact();
            Navigator.push(context, MaterialPageRoute(
                builder: (_) => MedicineScreen(service: widget.medicineService!)));
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              const Text('💊', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 12),
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Medicine Schedule', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                Text('Set up medicines, doses & schedules',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ])),
              Icon(Icons.chevron_right, color: Colors.grey.shade500),
            ]),
          ),
        )),
      ],

      sectionLabel('FAMILY'),
      card(child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('👨‍👩‍👧', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Family Code', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              Text(widget.familyId, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            ])),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: 'Copy code',
              onPressed: () async {
                HapticFeedback.lightImpact();
                await Future.delayed(const Duration(milliseconds: 80));
                HapticFeedback.lightImpact();
                await Clipboard.setData(ClipboardData(text: widget.familyId));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Family code copied!'),
                          duration: Duration(seconds: 2)));
                }
              },
            ),
          ]),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: widget.onChangeFamilyId,
            child: Text('Change family code',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary)),
          ),
        ]),
      )),

      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        child: Text('Baby name coming soon',
            style: TextStyle(
                fontSize: 12, color: Colors.grey.shade500,
                fontStyle: FontStyle.italic)),
      ),
    ]);

    // ── Tab 3: Reminders ─────────────────────────────────────────
    Widget remindersTab() => ListView(padding: const EdgeInsets.all(16), children: [
      sectionLabel('REMINDERS'),
      card(child: Column(children: [
        SwitchListTile(
          dense: true,
          title: const Text('🍼 Feed reminder', style: TextStyle(fontSize: 13)),
          subtitle: Text(_reminders.feedEnabled
              ? 'Remind after ${_reminders.feedThresholdHours}h'
              : 'Off', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          value: _reminders.feedEnabled,
          onChanged: (v) {
            HapticFeedback.lightImpact();
            _updateReminders(_reminders.copyWith(feedEnabled: v));
          },
        ),
        if (_reminders.feedEnabled) ...[
          Divider(height: 1, color: borderColor),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              Text('Remind after: ', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
              thresholdPicker(_reminders.feedThresholdHours,
                  (h) => _updateReminders(_reminders.copyWith(feedThresholdHours: h))),
            ]),
          ),
        ],
        Divider(height: 1, color: borderColor),
        SwitchListTile(
          dense: true,
          title: const Text('🧷 Diaper reminder', style: TextStyle(fontSize: 13)),
          subtitle: Text(_reminders.diaperEnabled
              ? 'Remind after ${_reminders.diaperThresholdHours}h'
              : 'Off', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          value: _reminders.diaperEnabled,
          onChanged: (v) {
            HapticFeedback.lightImpact();
            _updateReminders(_reminders.copyWith(diaperEnabled: v));
          },
        ),
        if (_reminders.diaperEnabled) ...[
          Divider(height: 1, color: borderColor),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              Text('Remind after: ', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
              thresholdPicker(_reminders.diaperThresholdHours,
                  (h) => _updateReminders(_reminders.copyWith(diaperThresholdHours: h))),
            ]),
          ),
        ],
        Divider(height: 1, color: borderColor),
        SwitchListTile(
          dense: true,
          title: const Text('🌙 Quiet hours', style: TextStyle(fontSize: 13)),
          subtitle: Text(_reminders.quietHoursEnabled
              ? 'No reminders ${_reminders.quietFrom} – ${_reminders.quietTo}'
              : 'Off', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          value: _reminders.quietHoursEnabled,
          onChanged: (v) {
            HapticFeedback.lightImpact();
            _updateReminders(_reminders.copyWith(quietHoursEnabled: v));
          },
        ),
        if (_reminders.quietHoursEnabled) ...[
          Divider(height: 1, color: borderColor),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              _TimePickerTile(label: 'From', time: _reminders.quietFrom,
                  onChanged: (t) => _updateReminders(_reminders.copyWith(quietFrom: t))),
              const SizedBox(width: 16),
              _TimePickerTile(label: 'To', time: _reminders.quietTo,
                  onChanged: (t) => _updateReminders(_reminders.copyWith(quietTo: t))),
            ]),
          ),
        ],
      ])),

      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: _showPendingDebug,
          style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(44, 32)),
          child: Text('check scheduled',
              style: TextStyle(
                  fontSize: 11, color: Colors.grey.shade500,
                  fontStyle: FontStyle.italic)),
        ),
      ),
      const SizedBox(height: 24),
    ]);

    return DefaultTabController(
      length: 3,
      child: Column(children: [
        const SafeArea(child: SizedBox(height: 0)),
        TabBar(
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          tabs: const [
            Tab(text: 'General'),
            Tab(text: 'Baby & Family'),
            Tab(text: 'Reminders'),
          ],
        ),
        Expanded(child: TabBarView(children: [
          generalTab(),
          babyTab(),
          remindersTab(),
        ])),
      ]),
    );
  }
}

class _TrackTile extends StatelessWidget {
  final String emoji, title, subtitle;
  final bool value;
  final void Function(bool) onChanged;
  const _TrackTile({
    required this.emoji, required this.title,
    required this.subtitle, required this.value, required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => SwitchListTile(
    dense: true,
    title: Row(children: [
      Text(emoji, style: const TextStyle(fontSize: 18)),
      const SizedBox(width: 8),
      Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
    ]),
    subtitle: Padding(
      padding: const EdgeInsets.only(left: 26),
      child: Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
    ),
    value: value,
    onChanged: onChanged,
  );
}

class _TimePickerTile extends StatelessWidget {
  final String label;
  final String time;
  final void Function(String) onChanged;
  const _TimePickerTile({required this.label, required this.time, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final parts = time.split(':');
    final initial = TimeOfDay(
      hour:   int.tryParse(parts[0]) ?? 22,
      minute: int.tryParse(parts[1]) ?? 0,
    );
    return GestureDetector(
      onTap: () async {
        HapticFeedback.lightImpact();
        final picked = await showTimePicker(context: context, initialTime: initial);
        if (picked != null) {
          onChanged('${picked.hour.toString().padLeft(2, "0")}:${picked.minute.toString().padLeft(2, "0")}');
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.5)),
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
