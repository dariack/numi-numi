# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Baby Tracker** (Firebase project: `yuli-tracker`) is a Flutter app for tracking baby activities (feeding, sleep, diaper, pumping, medicine) with real-time multi-device sync. It targets Android, iOS, macOS, and Web.

## Common Commands

```bash
# Development
flutter pub get          # Install/update dependencies
flutter run              # Run on connected device/emulator
flutter run -d chrome    # Run web version

# Code quality
flutter analyze          # Run linter (see analysis_options.yaml)

# Build
flutter build apk        # Android APK
flutter build ios        # iOS (requires Xcode)
flutter build web        # Web (output to build/web/)

# Firebase (from repo root)
firebase deploy --only hosting    # Deploy web build
firebase deploy --only functions  # Deploy Cloud Functions

# Cloud Functions (from functions/)
npm run serve            # Run emulator locally
npm run logs             # View live logs
```

There is no single-test runner configured; `flutter test` runs all tests in `test/`.

## Architecture

### Service-Based Pattern (No State Management Library)

The app uses plain `StatefulWidget` with a service layer — no Provider, Riverpod, or BLoC. Services are instantiated in `MainApp.initState()` and passed down as constructor arguments or accessed via singleton.

**Services** (`lib/services/`):
- `FirestoreService` — all event CRUD, real-time streams, pump stock tracking, offline persistence
- `SettingsService` — tracker settings (which event types to show) + caregiver names
- `ReminderService` — feed/diaper reminder thresholds; listens to Firestore for partner updates
- `NotificationService` — singleton; schedules local push notifications with quiet-hours support
- `MedicineService` — medicines with complex schedules (asNeeded / onceDailyAt / customTimes / specificDays); looks back 48h for pending doses
- `WidgetService` — updates Android home screen widgets (2 customizable slots)

### Data Models (`lib/models/`)

- `BabyEvent` — covers all event types via `EventType` enum (`sleep, feed, diaper, pump`). Pump events carry `ml`, `storage` (room/fridge/freezer), `expiresAt`, `spoiled`, `pumpId`. Feed events have `source` (breast/pump) and `linkedPumps`.
- `Medicine` + `MedicineGiven` — medicine definition with schedule and administered-dose history
- `ReminderSettings` — thresholds + quiet hours; `isQuietNow()` handles midnight wrapping

### Firestore Structure

```
families/{familyId}/
├── events/          # All BabyEvent documents
├── medicines/       # Active medicine schedules
├── medicineGiven/   # Administered dose history
├── settings/config          # TrackerSettings (which types to track, birth date)
├── settings/notifications   # ReminderSettings
└── devices/         # Per-device caregiver names
```

All writes use fire-and-forget with Firestore offline persistence (unlimited cache size) — the UI updates immediately without awaiting the network round-trip.

### App Entry & Routing (`lib/main.dart`)

`AppRouter` checks SharedPreferences for `familyId`. If absent → family code entry screen. Otherwise → `MainApp` with 5 tabs: **Home, Pump, Insights, Sleep, Settings**.

`MainApp.initState()` boots all services, loads reminder settings, starts Firestore streams, and handles data migration for legacy event format (v2).

### Screens (`lib/screens/`)

| File | Purpose |
|---|---|
| `home_screen.dart` | Dashboard: ongoing-activity banner, quick-log buttons, stats cards, pump stock, medicine reminder banner |
| `pump_screen.dart` | Milk stock by storage location with expiry warnings |
| `insights_accordion_screen.dart` | Horizontal accordion: Feed / Diaper / Sleep / Medicine analytics |
| `sleep_analysis_screen.dart` | Sleep duration & pattern analysis |
| `settings_screen.dart` | All preferences incl. widget slots, reminders, family code |
| `medicine_screen.dart` | Add/edit medicines, mark as given, view history |
| `history_screen.dart` | Timeline of all events with filter, edit, delete |
| `log_event_sheet.dart` | Bottom sheet for logging a new event (all types) |

### Notifications

- Android channel: `yuli_reminders` (high importance)
- Notification IDs: feed = `1001`, diaper = `1002`
- Scheduled using `flutter_local_notifications` + `timezone` package
- `ReminderService` reschedules on every Firestore settings change

### Theme

Material Design 3, purple seed color `0xFF6B4EFF`, system-aware dark mode. No custom assets or fonts.

## Firebase / Backend Notes

- Firebase project: `yuli-tracker`
- `lib/firebase_options.dart` — auto-generated Firebase config (do not edit manually; regenerate with `flutterfire configure`)
- `functions/index.js` — legacy Dialogflow webhook (Node.js); largely superseded by direct Firestore writes from the app
- Web hosting serves `build/web/` via `firebase.json`
