import '../models/event.dart';
import '../models/medicine.dart';

class HandoffNoteService {
  static String buildMessage({
    required Map<String, dynamic> stats,
    required DateTime? birthDate,
    required List<BabyEvent> recentEvents,
    List<Map<String, dynamic>> pendingReminders = const [],
    String? babyName,
  }) {
    final now = DateTime.now();
    final buf = StringBuffer();
    final name = babyName ?? 'Baby';

    buf.writeln('🍼 *$name handoff note* — ${_fmtTime(now)}');

    // ── Feed ──────────────────────────────────────────────────────
    final lastFeed = stats['lastFeed'] as BabyEvent?;
    buf.writeln();
    buf.writeln('*🍼 Feed*');
    if (lastFeed != null) {
      final feedEnd = lastFeed.endTime ?? lastFeed.startTime;
      final details = <String>[_fmtTime(feedEnd)];
      if (lastFeed.durationMinutes != null) details.add(lastFeed.durationText);
      if (lastFeed.side != null) details.add(lastFeed.side!);
      buf.writeln('Last: ${details.join(' · ')}');

      final avgGapMin = _avgFeedGap(recentEvents, now);
      if (avgGapMin > 0) {
        final nextFeed = feedEnd.add(Duration(minutes: avgGapMin));
        final minsUntil = nextFeed.difference(now).inMinutes;
        if (minsUntil <= 0) {
          buf.writeln('Next: Due now (~every ${_fmtGap(avgGapMin)})');
        } else {
          buf.writeln('Next: ~${_fmtTime(nextFeed)} (in ${_fmtDur(Duration(minutes: minsUntil))})');
        }
      }
    } else {
      buf.writeln('No feed logged yet');
    }

    // ── Diaper ────────────────────────────────────────────────────
    final lastDiaper = stats['lastDiaper'] as BabyEvent?;
    buf.writeln();
    buf.writeln('*🧷 Diaper*');
    if (lastDiaper != null) {
      final dtype = lastDiaper.pee && lastDiaper.poop
          ? 'pee+poop'
          : lastDiaper.poop
              ? 'poop'
              : 'pee';
      buf.writeln('Last: ${_fmtTime(lastDiaper.startTime)} · $dtype');
      final nextCheck = lastDiaper.startTime.add(const Duration(hours: 3));
      final minsUntil = nextCheck.difference(now).inMinutes;
      buf.writeln(minsUntil <= 0 ? 'Check: Due now' : 'Check by: ~${_fmtTime(nextCheck)}');
    } else {
      buf.writeln('No diaper logged yet');
    }
    final pees = stats['pees24h'] as int? ?? 0;
    final poops = stats['poops24h'] as int? ?? 0;
    if (pees > 0 || poops > 0) buf.writeln('24h: $pees pee · $poops poop');

    // ── Sleep ─────────────────────────────────────────────────────
    final lastSleep = stats['lastSleep'] as BabyEvent?;
    final ongoing = stats['ongoing'] as BabyEvent?;
    buf.writeln();
    buf.writeln('*😴 Sleep*');
    if (ongoing != null && ongoing.type == EventType.sleep) {
      final dur = now.difference(ongoing.startTime);
      buf.writeln('Currently sleeping (${_fmtDur(dur)})');
    } else if (lastSleep != null) {
      final sleepEnd = lastSleep.endTime ?? lastSleep.startTime;
      final awake = now.difference(sleepEnd);
      final sleptStr = lastSleep.durationMinutes != null
          ? ' · slept ${_fmtDur(Duration(minutes: lastSleep.durationMinutes!))}'
          : '';
      buf.writeln('Woke at ${_fmtTime(sleepEnd)}$sleptStr · awake ${_fmtDur(awake)}');
      if (birthDate != null) {
        final ageWeeks = now.difference(birthDate).inDays ~/ 7;
        if (now.hour >= 18) {
          buf.writeln('Bedtime window: approach soon');
        } else {
          final ww = _wakeWindow(ageWeeks);
          if (ww != null) buf.writeln('Wake window: $ww');
        }
      }
    } else {
      buf.writeln('No sleep logged yet');
    }

    // ── Medicine ──────────────────────────────────────────────────
    if (pendingReminders.isNotEmpty) {
      buf.writeln();
      buf.writeln('*💊 Medicine*');
      for (final r in pendingReminders.take(6)) {
        final med = r['medicine'] as Medicine;
        final slot = r['scheduledTime'] as String;
        final isOverdue = r['isOverdue'] as bool? ?? false;
        buf.writeln('${isOverdue ? '⚠️' : '•'} ${med.displayName} at $slot${isOverdue ? ' *(overdue)*' : ''}');
      }
    }

    // ── Pump stock ────────────────────────────────────────────────
    final stockUnits = (stats['stockUnits'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (stockUnits.isNotEmpty) {
      final storageMap = <String, int>{};
      for (final u in stockUnits) {
        final s = (u['storage'] as String?) ?? 'room';
        storageMap[s] = (storageMap[s] ?? 0) + (u['remaining'] as int);
      }
      buf.writeln();
      buf.writeln('*🥛 Milk stock*');
      const emojis = {'room': '🏠', 'fridge': '❄️', 'freezer': '🧊'};
      const labels = {'room': 'room temp', 'fridge': 'fridge', 'freezer': 'freezer'};
      for (final s in ['room', 'fridge', 'freezer']) {
        if (storageMap.containsKey(s)) {
          buf.writeln('${emojis[s]} ${storageMap[s]}ml (${labels[s]})');
        }
      }
    }

    buf.writeln();
    buf.write('📱 Tracked with Baby Tracker');
    return buf.toString();
  }

  static String _fmtTime(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m${t.hour < 12 ? 'am' : 'pm'}';
  }

  static String _fmtDur(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    return '${d.inMinutes}m';
  }

  static String _fmtGap(int minutes) {
    if (minutes >= 60) return '${minutes ~/ 60}h${minutes % 60 > 0 ? " ${minutes % 60}m" : ""}';
    return '${minutes}m';
  }

  static String? _wakeWindow(int ageWeeks) {
    if (ageWeeks < 6) return '45–60 min';
    if (ageWeeks < 12) return '60–90 min';
    if (ageWeeks < 16) return '75–120 min';
    if (ageWeeks < 24) return '90–150 min';
    return '2–3 hours';
  }

  // Average feed gap (minutes) weighted for current time-of-day window.
  static int _avgFeedGap(List<BabyEvent> events, DateTime now) {
    final cutoff = now.subtract(const Duration(days: 5));
    final feeds = events
        .where((e) => e.type == EventType.feed && e.startTime.isAfter(cutoff))
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    if (feeds.length < 2) return 0;

    final isNight = now.hour >= 22 || now.hour < 10;

    bool inWindow(int h) => isNight ? (h >= 22 || h < 10) : (h >= 10 && h < 22);

    final gaps = <int>[];
    for (int i = 1; i < feeds.length; i++) {
      final prevEnd = feeds[i - 1].endTime ?? feeds[i - 1].startTime;
      final gap = feeds[i].startTime.difference(prevEnd).inMinutes;
      if (gap < 5 || gap >= 720) continue;
      if (inWindow(feeds[i - 1].startTime.hour)) gaps.add(gap);
    }

    if (gaps.isNotEmpty) {
      return gaps.fold<int>(0, (s, v) => s + v) ~/ gaps.length;
    }

    // Fallback: all gaps regardless of window
    final allGaps = <int>[];
    for (int i = 1; i < feeds.length; i++) {
      final prevEnd = feeds[i - 1].endTime ?? feeds[i - 1].startTime;
      final gap = feeds[i].startTime.difference(prevEnd).inMinutes;
      if (gap >= 5 && gap < 720) allGaps.add(gap);
    }
    if (allGaps.isEmpty) return 0;
    return allGaps.fold<int>(0, (s, v) => s + v) ~/ allGaps.length;
  }
}
