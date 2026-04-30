import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/medicine.dart';

class MedicineService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final String familyId;

  MedicineService({required this.familyId});

  CollectionReference get _medicines =>
      _db.collection('families').doc(familyId).collection('medicines');
  CollectionReference get _given =>
      _db.collection('families').doc(familyId).collection('medicineGiven');

  // ===== MEDICINES CRUD =====

  Stream<List<Medicine>> medicinesStream() {
    return _medicines
        .where('active', isEqualTo: true)
        .snapshots()
        .map((s) => s.docs
            .map((d) { try { return Medicine.fromFirestore(d); } catch (_) { return null; } })
            .whereType<Medicine>()
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt)));
  }

  Future<void> addMedicine(Medicine m) async {
    await _medicines.add(m.toFirestore());
  }

  Future<void> updateMedicine(Medicine m) async {
    await _medicines.doc(m.id).set(m.toFirestore());
  }

  Future<void> deleteMedicine(String id) async {
    await _medicines.doc(id).update({'active': false});
  }

  // ===== GIVEN LOG =====

  Future<void> deleteGiven(String id) async {
    await _given.doc(id).delete();
  }

  Future<void> markGiven({
    required Medicine medicine,
    String? scheduledTime,
    DateTime? givenAt,
    String givenBy = 'app',
  }) async {
    await _given.add(MedicineGiven(
      id: '',
      medicineId: medicine.id,
      medicineName: medicine.name,
      dose: medicine.dose,
      givenAt: givenAt ?? DateTime.now(),
      givenBy: givenBy,
      scheduledTime: scheduledTime,
    ).toFirestore());
  }

  Stream<List<MedicineGiven>> givenStream({int limitDays = 30}) {
    // No composite index needed — fetch all and sort client-side
    return _given
        .snapshots()
        .map((s) {
          final since = DateTime.now().subtract(Duration(days: limitDays));
          final items = s.docs
              .map((d) { try { return MedicineGiven.fromFirestore(d); } catch (_) { return null; } })
              .whereType<MedicineGiven>()
              .where((g) => g.givenAt.isAfter(since))
              .toList();
          items.sort((a, b) => b.givenAt.compareTo(a.givenAt));
          return items;
        });
  }

  // ===== REMINDERS =====

  /// Returns pending reminders: scheduled doses not yet given within ±60min window.
  /// Returns list of {medicine, scheduledTime} maps.
  Future<List<Map<String, dynamic>>> getPendingReminders(
      List<Medicine> medicines) async {
    final now = DateTime.now();

    // Look back up to 48h to catch missed doses that were never given
    final lookbackStart = now.subtract(const Duration(hours: 48));
    final snap = await _given.get();
    final recentGiven = snap.docs
        .map((d) { try { return MedicineGiven.fromFirestore(d); } catch (_) { return null; } })
        .whereType<MedicineGiven>()
        .where((g) => g.givenAt.isAfter(lookbackStart))
        .toList();

    final pending = <Map<String, dynamic>>[];

    // Day name helper
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    String fmtSlotLabel(DateTime slotDate, String timeSlot, int dayOffset) {
      final d = slotDate.day.toString().padLeft(2, "0");
      final m = slotDate.month.toString().padLeft(2, "0");
      final dayName = dayNames[slotDate.weekday - 1];
      if (dayOffset == 0) return 'Today at ' + timeSlot;
      if (dayOffset == 1) return 'Yesterday (' + dayName + ' ' + d + '/' + m + ') at ' + timeSlot;
      return dayName + ' ' + d + '/' + m + ' at ' + timeSlot;
    }

    for (final med in medicines) {
      if (!med.active) continue;
      if (med.scheduleType == ScheduleType.asNeeded) continue;

      // Check past 3 days — catches doses missed across midnight reliably
      for (int dayOffset = 2; dayOffset >= 0; dayOffset--) {
        final slotDate = DateTime(now.year, now.month, now.day - dayOffset);

        // For specificDays: check if slotDate is a valid day
        if (med.scheduleType == ScheduleType.specificDays) {
          final dow = (slotDate.weekday - 1) % 7;
          if (!med.daysOfWeek.contains(dow)) continue;
        }

        for (final timeSlot in med.timesOfDay) {
          final parts = timeSlot.split(':');
          if (parts.length != 2) continue;
          final slotH = int.tryParse(parts[0]) ?? 0;
          final slotM = int.tryParse(parts[1]) ?? 0;
          final slotTime = DateTime(slotDate.year, slotDate.month, slotDate.day, slotH, slotM);

          // Only show if slot time has passed (or within 15min before)
          if (now.isBefore(slotTime.subtract(const Duration(minutes: 15)))) continue;

          // Don't show slots older than 48h
          if (now.difference(slotTime).inHours > 48) continue;

          // Check if already given for this exact slot
          final alreadyGiven = recentGiven.any((g) =>
              g.medicineId == med.id &&
              g.scheduledTime == timeSlot &&
              g.givenAt.year == slotDate.year &&
              g.givenAt.month == slotDate.month &&
              g.givenAt.day == slotDate.day);
          if (alreadyGiven) continue;

          final isToday = dayOffset == 0;
          pending.add({
            'medicine': med,
            'scheduledTime': timeSlot,
            'slotTime': slotTime,
            'slotDate': slotDate,
            'dayLabel': fmtSlotLabel(slotDate, timeSlot, dayOffset),
            'isOverdue': !isToday || now.difference(slotTime).inMinutes > 30,
          });
        }
      }
    }

    // Sort: overdue first, then by slot time
    pending.sort((a, b) {
      final aOver = a['isOverdue'] as bool;
      final bOver = b['isOverdue'] as bool;
      if (aOver != bOver) return aOver ? -1 : 1;
      return (a['slotTime'] as DateTime).compareTo(b['slotTime'] as DateTime);
    });

    return pending;
  }
}
