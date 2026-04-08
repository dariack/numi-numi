import 'package:flutter/material.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  final SettingsService settingsService;
  final String familyId;
  final VoidCallback onChangeFamilyId;

  const SettingsScreen({
    super.key,
    required this.settingsService,
    required this.familyId,
    required this.onChangeFamilyId,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  TrackerSettings _settings = const TrackerSettings();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await widget.settingsService.get();
    if (mounted) setState(() { _settings = s; _loading = false; });
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
                Text('Code: ${widget.familyId}',
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
