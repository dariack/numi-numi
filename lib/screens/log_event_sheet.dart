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
  // Shared
  DateTime _when = DateTime.now();
  bool _saving = false;
  bool _customTime = false;
  int _selectedQuickIdx = 0; // default "Now"

  // Sleep
  int? _durationMin;
  bool _isOngoing = false;
  bool _customDuration = false;

  // Feed
  String? _feedSource; // breast / pump (first thing asked for feed)
  String? _side;
  // Multi-pump: map of pumpId -> ml to deduct
  Map<String, int> _selectedPumps = {}; // {pumpEventId: mlToUse}
  int? _mlFed; // total ml fed (for display / override)
  int? _adHocMl; // ad-hoc ml input (creates pump on the fly)
  List<Map<String, dynamic>> _availableStock = [];
  bool _stockLoaded = false;

  // Diaper
  bool _pee = false;
  bool _poop = false;

  // Pump
  int? _pumpMl;
  String? _pumpStorage;

  // Multi-step for sleep & diaper (non-single-page types)
  int _step = 0;
  // 0 = when, 1 = duration (sleep), 2 = diaper what, 3 = side (ending sideless feed)

  bool get _isNow => !_customTime && _selectedQuickIdx == 0;
  bool get _isFeed => widget.type == EventType.feed;
  bool get _isPump => widget.type == EventType.pump;
  bool get _isSleep => widget.type == EventType.sleep;
  bool get _isDiaper => widget.type == EventType.diaper;

  @override
  void initState() {
    super.initState();
    if (widget.ongoing != null) {
      _when = widget.ongoing!.startTime;
      if (_isFeed && widget.ongoing!.side == null) {
        // Ending sideless feed — just show side picker
        _step = 3;
      } else {
        _step = 1; // duration step for ending ongoing
      }
    }
    if (_isFeed && widget.ongoing == null) {
      _loadStock(); // pre-load for pump source option
    }
  }

  Future<void> _loadStock() async {
    final stock = await widget.service.getAvailableStock();
    if (mounted) setState(() { _availableStock = stock; _stockLoaded = true; });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      BabyEvent? created;

      if (widget.ongoing != null) {
        // Ending an ongoing event
        final dur = _durationMin ?? DateTime.now().difference(_when).inMinutes;
        await widget.service.completeOngoing(widget.ongoing!.id, durationMinutes: dur, side: _side);
      } else if (_isPump) {
        final exp = BabyEvent.calcExpiration(_when, _pumpStorage);
        final nextId = await widget.service.getNextPumpId();
        created = await widget.service.addEvent(BabyEvent(
          id: '', type: EventType.pump, startTime: _when, side: _side,
          ml: _pumpMl, storage: _pumpStorage, expiresAt: exp, pumpId: nextId, createdBy: 'app',
        ));
      } else if (_isFeed) {
        // If pump source with ad-hoc ml, create a pump event first
        if (_feedSource == 'pump' && _adHocMl != null && _adHocMl! > 0) {
          final adHocPump = await widget.service.addEvent(BabyEvent(
            id: '', type: EventType.pump, startTime: _when,
            ml: _adHocMl, createdBy: 'app-adhoc',
          ));
          _selectedPumps[adHocPump.id] = _adHocMl!;
        }

        if (_feedSource == 'pump') {
          // Pump feed: duration 0, no side, not ongoing
          final totalMl = _selectedPumps.values.fold<int>(0, (s, v) => s + v);
          final linkedJson = _selectedPumps.entries
              .map((e) => '{"id":"${e.key}","ml":${e.value}}')
              .toList();
          final linkedPumpsStr = '[${linkedJson.join(',')}]';
          created = await widget.service.addEvent(BabyEvent(
            id: '', type: EventType.feed, startTime: _when,
            endTime: _when, durationMinutes: 0,
            createdBy: 'app', source: 'pump',
            linkedPumps: linkedPumpsStr,
            mlFed: totalMl > 0 ? totalMl : null,
          ));
        } else {
          // Breast feed: has duration, side, ongoing
          DateTime? endTime;
          if (_durationMin != null) endTime = _when.add(Duration(minutes: _durationMin!));
          created = await widget.service.addEvent(BabyEvent(
            id: '', type: EventType.feed, startTime: _when,
            endTime: endTime,
            durationMinutes: _isOngoing ? null : _durationMin,
            side: _side, createdBy: 'app', source: 'breast',
          ));
        }
      } else if (_isDiaper) {
        created = await widget.service.addEvent(BabyEvent(
          id: '', type: EventType.diaper, startTime: _when,
          pee: _pee, poop: _poop, createdBy: 'app',
        ));
      } else if (_isSleep) {
        DateTime? endTime;
        if (_durationMin != null) endTime = _when.add(Duration(minutes: _durationMin!));
        created = await widget.service.addEvent(BabyEvent(
          id: '', type: EventType.sleep, startTime: _when,
          endTime: endTime,
          durationMinutes: _isOngoing ? null : _durationMin, createdBy: 'app',
        ));
      }

      if (mounted) Navigator.pop(context, created ?? true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        setState(() => _saving = false);
      }
    }
  }

  String get _title {
    if (_isPump) return '🥛 Log Pump';
    if (widget.ongoing != null) return '${_typeEmoji} End ${_typeName}';
    return '$_typeEmoji Log ${_typeName}';
  }

  String get _typeEmoji => const {EventType.sleep: '😴', EventType.feed: '🍼', EventType.diaper: '🧷', EventType.pump: '🥛'}[widget.type]!;
  String get _typeName => const {EventType.sleep: 'Sleep', EventType.feed: 'Feed', EventType.diaper: 'Diaper Change', EventType.pump: 'Pump'}[widget.type]!;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(color: Colors.grey.shade600, borderRadius: BorderRadius.circular(2)))),
        Text(_title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),

        // === FEED: single page ===
        if (_isFeed && widget.ongoing == null) _buildFeedWizard(),

        // === PUMP: single page ===
        if (_isPump) _buildPumpWizard(),

        // === DIAPER: single page ===
        if (_isDiaper && widget.ongoing == null) _buildDiaperWizard(),

        // === SLEEP: multi-step ===
        if (_isSleep && widget.ongoing == null && _step == 0) _buildWhenStep(onNext: () {
          if (_isNow) { _isOngoing = true; _durationMin = null; _save(); }
          else setState(() => _step = 1);
        }),
        if (_isSleep && _step == 1) _buildDurationStep(onNext: () => _save()),

        // === ENDING ONGOING ===
        if (widget.ongoing != null && _step == 1) _buildDurationStep(onNext: () {
          if (_isFeed && widget.ongoing!.side == null) setState(() => _step = 3);
          else _save();
        }),
        if (widget.ongoing != null && _step == 3) _buildSidePicker(label: 'Which side?', onSave: () => _save()),
      ])),
    );
  }

  // ================================================================
  // FEED WIZARD (single page — like pump)
  // ================================================================
  Widget _buildFeedWizard() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 1. Source — first thing
      _label('Feeding from?'),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: _ToggleBtn(emoji: '🤱', label: 'Breast', selected: _feedSource == 'breast',
          onTap: () => setState(() { _feedSource = 'breast'; _selectedPumps.clear(); _mlFed = null; _adHocMl = null; }))),
        const SizedBox(width: 10),
        Expanded(child: _ToggleBtn(emoji: '🥛', label: 'Pumped Milk', selected: _feedSource == 'pump',
          onTap: () => setState(() { _feedSource = 'pump'; _side = null; }))),
      ]),

      const SizedBox(height: 16),

      // 2. When
      _label('When?'),
      const SizedBox(height: 8),
      _whenChips(),
      const SizedBox(height: 6),
      if (_isNow && _feedSource != 'pump') ...[
        const SizedBox(height: 6),
        Text('Will be logged as ongoing', style: TextStyle(fontSize: 12, color: Colors.orange.shade400, fontStyle: FontStyle.italic)),
      ],

      // 3. Source-specific fields
      if (_feedSource == 'breast') ...[
        const SizedBox(height: 16),
        _label('Side (optional)'),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _SmallToggle(label: '🤱 Left', selected: _side == 'left',
            onTap: () => setState(() => _side = _side == 'left' ? null : 'left'))),
          const SizedBox(width: 8),
          Expanded(child: _SmallToggle(label: '🤱 Right', selected: _side == 'right',
            onTap: () => setState(() => _side = _side == 'right' ? null : 'right'))),
        ]),

        if (!_isNow) ...[
          const SizedBox(height: 16),
          _label('Duration'),
          const SizedBox(height: 8),
          _durationChips(isSleep: false),
        ],
      ],

      if (_feedSource == 'pump') ...[
        const SizedBox(height: 16),
        _label('Select pump portions'),
        const SizedBox(height: 8),
        if (!_stockLoaded)
          const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
        else if (_availableStock.isEmpty)
          Text('No available pump portions', style: TextStyle(fontSize: 13, color: Colors.grey.shade500))
        else ..._availableStock.map((s) {
          final p = s['event'] as BabyEvent;
          final rem = s['remaining'] as int;
          final sel = _selectedPumps.containsKey(p.id);
          return Padding(padding: const EdgeInsets.only(bottom: 6), child: GestureDetector(
            onTap: () => setState(() {
              if (sel) { _selectedPumps.remove(p.id); }
              else { _selectedPumps[p.id] = rem; }
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
                border: Border.all(color: sel ? Theme.of(context).colorScheme.primary : Colors.grey.withOpacity(0.3), width: sel ? 2 : 1),
                color: sel ? Theme.of(context).colorScheme.primary.withOpacity(0.1) : null),
              child: Row(children: [
                Icon(sel ? Icons.check_box : Icons.check_box_outline_blank,
                  color: sel ? Theme.of(context).colorScheme.primary : Colors.grey.shade400, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.readablePumpId, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                  Text('${rem}ml remaining', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                ])),
                if (sel) ...[
                  SizedBox(width: 60, child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      border: OutlineInputBorder(), hintText: 'ml'),
                    controller: TextEditingController(text: _selectedPumps[p.id]?.toString() ?? ''),
                    onChanged: (v) { final n = int.tryParse(v); if (n != null && n > 0) _selectedPumps[p.id] = n; },
                  )),
                  const Text('ml', style: TextStyle(fontSize: 11)),
                ],
              ]),
            ),
          ));
        }),

        // Totals
        if (_selectedPumps.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('Selected: ${_selectedPumps.values.fold<int>(0, (s, v) => s + v)}ml from ${_selectedPumps.length} portion${_selectedPumps.length > 1 ? 's' : ''}',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary)),
        ],

        const SizedBox(height: 12),
        // Ad-hoc: enter ml without existing pump
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.withOpacity(0.3)),
            color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1E2130) : Colors.grey.shade50),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("Or enter ml without a pump record:", style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            const SizedBox(height: 6),
            TextField(
              keyboardType: TextInputType.number,
              decoration: InputDecoration(hintText: 'e.g. 60', border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)), isDense: true),
              onChanged: (v) => _adHocMl = int.tryParse(v),
            ),
          ]),
        ),
      ],

      const SizedBox(height: 20),
      _SaveButton(saving: _saving, onTap: () {
        if (_feedSource == null) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select breast or pumped milk')));
          return;
        }
        if (_feedSource == 'breast') {
          if (_isNow) { _isOngoing = true; _durationMin = null; }
        }
        // Pump feed: no duration/ongoing needed
        if (_feedSource == 'pump' && _selectedPumps.isEmpty && (_adHocMl == null || _adHocMl! <= 0)) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select a pump portion or enter ml')));
          return;
        }
        _save();
      }),
    ]);
  }

  // ================================================================
  // PUMP WIZARD (single page — unchanged)
  // ================================================================
  Widget _buildPumpWizard() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label('When was this pumped?'),
      const SizedBox(height: 8),
      _whenChips(),
      const SizedBox(height: 6),

      const SizedBox(height: 16),
      _label('Milliliters (optional)'),
      const SizedBox(height: 8),
      TextField(keyboardType: TextInputType.number,
        decoration: InputDecoration(hintText: 'e.g. 120', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), isDense: true),
        onChanged: (v) => _pumpMl = int.tryParse(v)),

      const SizedBox(height: 16),
      _label('Side (optional)'),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: _SmallToggle(label: 'Left', selected: _side == 'left', onTap: () => setState(() => _side = _side == 'left' ? null : 'left'))),
        const SizedBox(width: 8),
        Expanded(child: _SmallToggle(label: 'Right', selected: _side == 'right', onTap: () => setState(() => _side = _side == 'right' ? null : 'right'))),
        const SizedBox(width: 8),
        Expanded(child: _SmallToggle(label: 'Both', selected: _side == 'both', onTap: () => setState(() => _side = _side == 'both' ? null : 'both'))),
      ]),

      const SizedBox(height: 16),
      _label('Stored at (optional)'),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: _SmallToggle(label: '🏠 Room', selected: _pumpStorage == 'room', onTap: () => setState(() => _pumpStorage = _pumpStorage == 'room' ? null : 'room'))),
        const SizedBox(width: 8),
        Expanded(child: _SmallToggle(label: '❄️ Fridge', selected: _pumpStorage == 'fridge', onTap: () => setState(() => _pumpStorage = _pumpStorage == 'fridge' ? null : 'fridge'))),
        const SizedBox(width: 8),
        Expanded(child: _SmallToggle(label: '🧊 Freezer', selected: _pumpStorage == 'freezer', onTap: () => setState(() => _pumpStorage = _pumpStorage == 'freezer' ? null : 'freezer'))),
      ]),

      const SizedBox(height: 20),
      _SaveButton(saving: _saving, onTap: () => _save()),
    ]);
  }

  // ================================================================
  // SHARED STEP BUILDERS (sleep, diaper, ending ongoing)
  // ================================================================

  Widget _buildWhenStep({required VoidCallback onNext}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label('When did this happen?'),
      const SizedBox(height: 8),
      _whenChips(),
      const SizedBox(height: 6),
      if (_isNow && _isSleep) ...[
        const SizedBox(height: 6),
        Text('Will be logged as ongoing', style: TextStyle(fontSize: 12, color: Colors.orange.shade400, fontStyle: FontStyle.italic)),
      ],
      const SizedBox(height: 16),
      _SaveButton(label: _isNow && _isSleep ? 'Save' : 'Next', saving: _saving, onTap: onNext),
    ]);
  }

  Widget _buildDurationStep({required VoidCallback onNext}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label('How long?'),
      const SizedBox(height: 4),
      Text('Started at ${_fmtTime(_when)}', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      const SizedBox(height: 12),
      _durationChips(isSleep: _isSleep),
      const SizedBox(height: 6),
      const SizedBox(height: 16),
      _SaveButton(label: 'Save', saving: _saving, onTap: () {
        if (!_isOngoing && _durationMin == null) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick a duration or "Still ongoing"')));
          return;
        }
        onNext();
      }),
    ]);
  }

  Widget _durationChips({required bool isSleep}) {
    final isEnding = widget.ongoing != null;
    final endNowMin = isEnding ? DateTime.now().difference(_when).inMinutes : 0;
    final quickOptions = isSleep ? [30, 60, 120, 180] : [10, 15, 20, 30];
    final quickLabels = isSleep ? ['30m', '1h', '2h', '3h'] : ['10m', '15m', '20m', '30m'];
    return Row(children: [
      if (isEnding) ...[
        _CompactBtn(label: '⏹ ${endNowMin}m', selected: _durationMin == endNowMin && !_isOngoing,
          color: Colors.red, onTap: () => setState(() { _durationMin = endNowMin; _isOngoing = false; _customDuration = false; })),
        const SizedBox(width: 6),
      ],
      for (int i = 0; i < quickOptions.length; i++) ...[
        _CompactBtn(label: quickLabels[i], selected: _durationMin == quickOptions[i] && !_isOngoing,
          onTap: () => setState(() { _durationMin = quickOptions[i]; _isOngoing = false; _customDuration = false; })),
        if (i < quickOptions.length - 1) const SizedBox(width: 6),
      ],
      if (!isEnding) ...[
        const SizedBox(width: 6),
        _CompactBtn(label: '⏱', selected: _isOngoing, color: Colors.orange,
          onTap: () => setState(() { _isOngoing = true; _durationMin = null; _customDuration = false; })),
      ],
      const SizedBox(width: 6),
      // Custom duration button
      Expanded(child: GestureDetector(
        onTap: () async {
          final c = TextEditingController(text: _durationMin?.toString() ?? '');
          final result = await showDialog<int>(context: context, builder: (ctx) => AlertDialog(
            title: const Text('Duration (minutes)'),
            content: TextField(controller: c, keyboardType: TextInputType.number, autofocus: true,
              decoration: const InputDecoration(hintText: 'e.g. 45')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, int.tryParse(c.text)), child: const Text('OK')),
            ],
          ));
          if (result != null && result > 0) setState(() { _durationMin = result; _isOngoing = false; _customDuration = true; });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _customDuration ? Theme.of(context).colorScheme.primary : Colors.grey.withOpacity(0.3)),
            color: _customDuration ? Theme.of(context).colorScheme.primary.withOpacity(0.1) : null,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('✏️', style: const TextStyle(fontSize: 14)),
            if (_customDuration && _durationMin != null) ...[
              const SizedBox(height: 2),
              Text('${_durationMin}m', style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.primary)),
            ],
          ]),
        ),
      )),
    ]);
  }

  Widget _buildDiaperWizard() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // When
      _label('When?'),
      const SizedBox(height: 8),
      _whenChips(),
      const SizedBox(height: 6),

      const SizedBox(height: 16),
      // What
      _label('What was in the diaper?'),
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
      const SizedBox(height: 20),
      _SaveButton(label: 'Save', saving: _saving, onTap: () {
        if (!_pee && !_poop) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select at least pee or poop'))); return; }
        _save();
      }),
    ]);
  }

  Widget _buildDiaperStep() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label('What was in the diaper?'),
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
      _SaveButton(label: 'Save', saving: _saving, onTap: () {
        if (!_pee && !_poop) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select at least pee or poop'))); return; }
        _save();
      }),
    ]);
  }

  Widget _buildSidePicker({required String label, required VoidCallback onSave}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label('$label (optional)'),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _ToggleBtn(emoji: '🤱', label: 'Left', selected: _side == 'left', onTap: () => setState(() => _side = _side == 'left' ? null : 'left'))),
        const SizedBox(width: 10),
        Expanded(child: _ToggleBtn(emoji: '🤱', label: 'Right', selected: _side == 'right', onTap: () => setState(() => _side = _side == 'right' ? null : 'right'))),
      ]),
      const SizedBox(height: 16),
      _SaveButton(label: 'Save', saving: _saving, onTap: onSave),
    ]);
  }

  // ================================================================
  // SHARED WIDGETS
  // ================================================================

  Widget _label(String text) => Text(text, style: TextStyle(fontSize: 15, color: Colors.grey.shade400));

  Widget _whenChips() {
    final now = DateTime.now();
    // Single-row compact time selector
    return Row(children: [
      _CompactBtn(label: 'Now', selected: _selectedQuickIdx == 0 && !_customTime,
        onTap: () => setState(() { _when = DateTime.now(); _customTime = false; _selectedQuickIdx = 0; })),
      const SizedBox(width: 6),
      _CompactBtn(label: '5m', selected: _selectedQuickIdx == 4 && !_customTime,
        onTap: () => setState(() { _when = now.subtract(const Duration(minutes: 5)); _customTime = false; _selectedQuickIdx = 4; })),
      const SizedBox(width: 6),
      _CompactBtn(label: '15m', selected: _selectedQuickIdx == 1 && !_customTime,
        onTap: () => setState(() { _when = now.subtract(const Duration(minutes: 15)); _customTime = false; _selectedQuickIdx = 1; })),
      const SizedBox(width: 6),
      _CompactBtn(label: '30m', selected: _selectedQuickIdx == 2 && !_customTime,
        onTap: () => setState(() { _when = now.subtract(const Duration(minutes: 30)); _customTime = false; _selectedQuickIdx = 2; })),
      const SizedBox(width: 6),
      Expanded(child: GestureDetector(
        onTap: () async {
          final d = await showDatePicker(context: context, initialDate: _when,
            firstDate: now.subtract(const Duration(days: 30)), lastDate: now);
          if (d == null || !mounted) return;
          final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_when));
          if (t == null) return;
          final dt = DateTime(d.year, d.month, d.day, t.hour, t.minute);
          if (dt.isAfter(now)) return;
          setState(() { _when = dt; _customTime = true; _selectedQuickIdx = -1; });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _customTime ? Theme.of(context).colorScheme.primary : Colors.grey.withOpacity(0.3)),
            color: _customTime ? Theme.of(context).colorScheme.primary.withOpacity(0.1) : null,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('✏️', style: const TextStyle(fontSize: 14)),
            if (_customTime) ...[
              const SizedBox(height: 2),
              Text(_fmtDateTime(_when), style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.primary)),
            ],
          ]),
        ),
      )),
    ]);
  }

  String _fmtTime(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  String _fmtDateTime(DateTime d) => '${d.day}/${d.month} ${_fmtTime(d)}';
}

// ================================================================
// REUSABLE WIDGETS
// ================================================================

class _CompactBtn extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;
  const _CompactBtn({required this.label, required this.selected, required this.onTap, this.color});
  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? c : Colors.grey.withOpacity(0.3), width: selected ? 2 : 1),
          color: selected ? c.withOpacity(0.12) : null,
        ),
        child: Text(label, style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          color: selected ? c : Colors.grey.shade400)),
      ),
    );
  }
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

class _SmallToggle extends StatelessWidget {
  final String label; final bool selected; final VoidCallback onTap;
  const _SmallToggle({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.primary;
    return GestureDetector(onTap: onTap, child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
        color: selected ? c.withOpacity(0.12) : null,
        border: Border.all(color: selected ? c : Colors.grey.withOpacity(0.3), width: selected ? 2 : 1)),
      child: Center(child: Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: selected ? c : Colors.grey.shade400))),
    ));
  }
}

class _SaveButton extends StatelessWidget {
  final VoidCallback onTap; final String label; final bool saving;
  const _SaveButton({required this.onTap, this.label = 'Save', this.saving = false});
  @override
  Widget build(BuildContext context) {
    return SizedBox(width: double.infinity, height: 50, child: FilledButton(
      onPressed: saving ? null : onTap,
      child: saving ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
        : Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
    ));
  }
}
