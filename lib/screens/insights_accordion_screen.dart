import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/event.dart';
import '../services/firestore_service.dart';
import '../services/medicine_service.dart';
import 'insights_screen.dart';
import 'medicine_screen.dart';

const _kIndigo = Color(0xFF6366f1);

class InsightsAccordionScreen extends StatefulWidget {
  final FirestoreService service;
  final MedicineService? medicineService;
  const InsightsAccordionScreen({
    super.key,
    required this.service,
    this.medicineService,
  });
  @override
  State<InsightsAccordionScreen> createState() => _InsightsAccordionScreenState();
}

class _InsightsAccordionScreenState extends State<InsightsAccordionScreen> {
  // Which section is open: null = all closed, 'feed'/'sleep'/'diaper'/'pump'/'medicine'
  String? _open;

  // Summary data — loaded once on mount
  Map<String, dynamic>? _feedSummary;
  Map<String, dynamic>? _pumpSummary;
  bool _summaryLoading = true;

  // Track which sections have been opened (for lazy init)
  final Set<String> _initialised = {};

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  Future<void> _loadSummary() async {
    final results = await Future.wait([
      widget.service.getFeedInsights(),
      widget.service.getPumpStats(),
    ]);
    if (mounted) setState(() {
      _feedSummary = results[0] as Map<String, dynamic>;
      _pumpSummary = results[1] as Map<String, dynamic>;
      _summaryLoading = false;
    });
  }

  void _toggle(String id) {
    HapticFeedback.lightImpact();
    setState(() {
      _open = _open == id ? null : id;
      if (_open != null) _initialised.add(_open!);
    });
  }

  String _fmtDur(Duration? d) {
    if (d == null) return '--';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    return '${d.inMinutes}m';
  }

  String _fmtMin(num? m) {
    if (m == null || m <= 0) return '--';
    final mins = m.round();
    if (mins >= 60) return '${mins ~/ 60}h ${mins % 60}m';
    return '${mins}m';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dividerColor = isDark ? Colors.grey.shade800 : Colors.grey.shade200;

    return RefreshIndicator(
      onRefresh: () async {
        setState(() { _summaryLoading = true; _feedSummary = null; _pumpSummary = null; });
        await _loadSummary();
      },
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _buildSection(
            id: 'feed',
            emoji: '🍼',
            label: 'Feeding',
            color: Colors.orange,
            summary: _feedSummary == null ? null : _buildFeedSummary(),
            isDark: isDark,
            dividerColor: dividerColor,
            child: _initialised.contains('feed')
                ? SizedBox(
                    height: 420,
                    child: ActionTabScreen(service: widget.service, type: EventType.feed),
                  )
                : null,
          ),
          _buildSection(
            id: 'sleep',
            emoji: '😴',
            label: 'Sleep',
            color: const Color(0xFFa78bfa),
            summary: 'Recent sleep patterns',
            isDark: isDark,
            dividerColor: dividerColor,
            child: _initialised.contains('sleep')
                ? SizedBox(
                    height: 380,
                    child: ActionTabScreen(service: widget.service, type: EventType.sleep),
                  )
                : null,
          ),
          _buildSection(
            id: 'diaper',
            emoji: '🧷',
            label: 'Diaper',
            color: Colors.teal,
            summary: 'Recent diaper activity',
            isDark: isDark,
            dividerColor: dividerColor,
            child: _initialised.contains('diaper')
                ? SizedBox(
                    height: 420,
                    child: ActionTabScreen(service: widget.service, type: EventType.diaper),
                  )
                : null,
          ),
          _buildSection(
            id: 'pump',
            emoji: '🥛',
            label: 'Pump & Stock',
            color: const Color(0xFFF472B6),
            summary: _pumpSummary == null ? null : _buildPumpSummary(),
            isDark: isDark,
            dividerColor: dividerColor,
            child: _initialised.contains('pump')
                ? SizedBox(
                    height: 460,
                    child: ActionTabScreen(service: widget.service, type: EventType.pump),
                  )
                : null,
          ),
          if (widget.medicineService != null)
            _buildSection(
              id: 'medicine',
              emoji: '💊',
              label: 'Medicine',
              color: const Color(0xFFa855f7),
              summary: 'Medicine schedule & history',
              isDark: isDark,
              dividerColor: dividerColor,
              child: _initialised.contains('medicine')
                  ? SizedBox(
                      height: 500,
                      child: MedicineScreen(service: widget.medicineService!),
                    )
                  : null,
            ),
        ],
      ),
    );
  }

  String? _buildFeedSummary() {
    if (_feedSummary == null) return null;
    final timeSince = _feedSummary!['timeSinceLast'] as Duration?;
    final rec = _feedSummary!['recommendedSide'] as String?;
    final parts = <String>[];
    if (timeSince != null) parts.add(_fmtDur(timeSince) + ' since last feed');
    if (rec != null) parts.add('Next: ' + rec.toUpperCase());
    return parts.isEmpty ? 'No recent feeds' : parts.join(' · ');
  }

  String? _buildPumpSummary() {
    if (_pumpSummary == null) return null;
    final avg = (_pumpSummary!['avgPumpedPerDay'] as num?)?.round() ?? 0;
    final recent = (_pumpSummary!['recentUsage'] as List?)?.length ?? 0;
    final parts = <String>[];
    if (avg > 0) parts.add(avg.toString() + 'ml/day avg');
    if (recent > 0) parts.add(recent.toString() + ' recent pumps');
    return parts.isEmpty ? 'No pump data' : parts.join(' · ');
  }

  Widget _buildSection({
    required String id,
    required String emoji,
    required String label,
    required Color color,
    required String? summary,
    required bool isDark,
    required Color dividerColor,
    required Widget? child,
  }) {
    final isOpen = _open == id;
    final isLoading = _summaryLoading && (id == 'feed' || id == 'pump');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header row — always visible
        InkWell(
          onTap: () => _toggle(id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(children: [
              Text(emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 2),
                  isLoading
                      ? Text('Loading...', style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500))
                      : Text(summary ?? '—', style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              const SizedBox(width: 8),
              AnimatedRotation(
                turns: isOpen ? 0.25 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(Icons.chevron_right,
                    color: isOpen ? color : Colors.grey.shade600, size: 22),
              ),
            ]),
          ),
        ),

        // Expanded content — animated
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 250),
          crossFadeState: isOpen ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox.shrink(),
          secondChild: isOpen && child != null
              ? Column(children: [
                  Divider(height: 1, color: color.withOpacity(0.3)),
                  child,
                ])
              : const SizedBox.shrink(),
        ),

        Divider(height: 1, color: dividerColor),
      ],
    );
  }
}
