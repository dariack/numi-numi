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

  Future<void> markGiven({
    required Medicine medicine,
    String? scheduledTime,
    String givenBy = 'app',
  }) async {
    await _given.add(MedicineGiven(
      id: '',
      medicineId: medicine.id,
      medicineName: medicine.name,
      dose: medicine.dose,
      givenAt: DateTime.now(),
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
    final todayStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    // Fetch today's given records — no compound index, filter client-side
    final todayStart = DateTime(now.year, now.month, now.day);
    final snap = await _given.get();
    final givenToday = snap.docs
        .map((d) { try { return MedicineGiven.fromFirestore(d); } catch (_) { return null; } })
        .whereType<MedicineGiven>()
        .toList();

    final pending = <Map<String, dynamic>>[];

    for (final med in medicines) {
      if (!med.active) continue;
      if (med.scheduleType == ScheduleType.asNeeded) continue;

      // Check if today is a valid day for specificDays schedule
      if (med.scheduleType == ScheduleType.specificDays) {
        // DateTime weekday: Mon=1…Sun=7, our daysOfWeek: 0=Mon…6=Sun
        final todayDow = (now.weekday - 1) % 7;
        if (!med.daysOfWeek.contains(todayDow)) continue;
      }

      for (final timeSlot in med.timesOfDay) {
        // Parse slot "HH:MM"
        final parts = timeSlot.split(':');
        if (parts.length != 2) continue;
        final slotH = int.tryParse(parts[0]) ?? 0;
        final slotM = int.tryParse(parts[1]) ?? 0;
        final slotTime = DateTime(now.year, now.month, now.day, slotH, slotM);

        // Only show reminder if we're past the scheduled time (or within 15min before)
        if (now.isBefore(slotTime.subtract(const Duration(minutes: 15)))) continue;

        // Check if already given for this slot today
        final alreadyGiven = givenToday.any((g) =>
            g.medicineId == med.id && g.scheduledTime == timeSlot);
        if (alreadyGiven) continue;

        pending.add({'medicine': med, 'scheduledTime': timeSlot, 'slotTime': slotTime});
      }
    }

    return pending;
  }
}
