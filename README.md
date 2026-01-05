# Prayer Times App
 
 and android app i created for fun and to fix a problem that i have been experiancing with prayer times from other apps that dont match morocco's ministry times, so you end up really confused, this app pulls the data directly from the ministry's official page so no need to struggle any longer.

## Features

### Core Functionality
- **Dual Prayer Time Sources**
  - Ministry of Religious Affairs API (Moroccan Government)
  - AlAdhan API with custom Islamic calculation methods
  - Offline calculation mode for areas without internet
  
- **Home Screen Widgets**
  - Vertical widget (3-column layout)
  - Horizontal widget (2x3 grid layout)
  - Manual refresh button with fresh data fetching
  - Real-time prayer time highlighting
  - Customizable appearance (colors, transparency, dark mode)

- **Smart Notifications**
  - Global/advanced notification control
  - Athan (Islamic call to prayer) audio notifications
  - Notification sounds based on preference
  - Scheduled prayer time reminders

- **Prayer Calendar**
  - Sourced from : https://habous.gov.ma/prieres/
  - Monthly Islamic calendar view 
  - Gregorian and Hijri date support
  - Historical prayer times for any day
  - City-based prayer time lookup

- **Location Management**
  - All cities supported by the ministry are also here
  - Manual coordinate input
  - Quick Access favorites system

- **Offline Support**
  - Offline prayer calculation without internet

## Architecture

### Technology Stack
- **Frontend**: Flutter (Dart)
- **Backend/Android**: Kotlin
- **Data Storage**: SharedPreferences (Dart & Android)
- **Background Tasks**: WorkManager (daily/monthly refresh)
- **Notifications**: flutter_local_notifications
- **JSON Parsing**: Gson

### Key Components

#### Dart/Flutter Layer
- `lib/main.dart` - Main app UI and state management
- `lib/services/api_service.dart` - API communication
- `lib/services/background_tasks.dart` - Scheduled tasks (daily/monthly refresh)
- `lib/services/daily_prayer_parser.dart` - Ministry API HTML parsing
- `lib/widgets/widget_info_manager.dart` - Widget cache management
- `lib/utils/responsive_sizes.dart` - Responsive UI sizing

#### Kotlin/Android Layer
- `MainActivity.kt` - Dart↔Android communication bridge
- `PrayerWidgetProvider.kt` - Vertical/minimal widget (3-column)
- `PrayerWidgetProviderHorizontal.kt` - Horizontal widget (2x3 grid)
- `WidgetCacheUpdateWorker.kt` - Background worker for widget cache updates
- `WidgetCacheService.kt` - Low-level widget cache persistence

### Data Flow

**Manual Widget Refresh:**
1. User taps refresh button on widget
2. `PrayerWidgetProvider.onReceive()` → `handleManualRefresh()`
3. `WidgetCacheUpdateWorker` enqueued with unique ID
4. Worker broadcasts `REFRESH_WIDGET_CACHE` to wake Dart
5. Dart fetches fresh prayer times via API
6. Worker reads updated cache from `FlutterSharedPreferences`
7. Saves to `widget_prefs` SharedPreferences
8. `triggerWidgetUpdate()` broadcasts to both widgets
9. Widget UI updates with fresh data

**Daily Refresh:**
1. BackgroundTasks schedules daily refresh at 12:30 AM
2. Worker runs periodically (platform-dependent)
3. Fetches new prayer times from API/Ministry
4. Updates widget cache automatically
5. Optional notification sent (dev toggle)

**Prayer Highlighting:**
1. Widget shows next prayer time
2. AlarmManager schedules exact alarm at prayer time
3. Alarm fires → broadcasts `ACTION_UPDATE_PRAYER_HIGHLIGHT`
4. Widget UI highlights next prayer card
5. Next alarm scheduled for following prayer time

## Getting Started

### Prerequisites
- Flutter SDK (3.0+)
- Android SDK (API 33+)
- Kotlin 1.9+
- Gradle 8.0+




### Configuration

**API Endpoints:**
- Ministry API: `https://habous.gov.ma/prieres/horaire_hijri_2.php`
- AlAdhan API: `https://api.aladhan.com/v1/timingsByCity`

**Prayer Calculation Method (Offline):** 
- this was made to match whatever google uses sine i dont know what calculation method the ministry actuallyuses.
- Fajr: 19° below horizon
- Isha: 17° below horizon
- School: Shafi/Standard madhab
- +5 minute adjustment for Isha


### Widget Features
- ✅ Refresh button for manual update
- ✅ Automatic daily refresh
- ✅ Prayer time highlighting 
- ✅ Customizable colours and transparency
- ✅ Dark mode support

## Permissions

**Required:**
- `INTERNET` - API communication
- `ACCESS_NETWORK_STATE` - Network status check
- `POST_NOTIFICATIONS` - Prayer notifications
- `SCHEDULE_EXACT_ALARM` - Precise prayer time alarms
- `RECEIVE_BOOT_COMPLETED` - Widget refresh after device restart

**Optional:**
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` - Better background task reliability


## Development

### Debug Features
- you can access the debug developer menu by holding the about card, there i put the stuff i used to test featues.

### File Structure
```
lib/
├── main.dart                                    # Main app UI and state management
├── models/
│   └── prayer_times.dart                       # Data models (PrayerTimes class)
├── services/
│   ├── api_service.dart                        # AlAdhan API communication
│   ├── background_tasks.dart                   # WorkManager scheduled tasks
│   ├── daily_prayer_parser.dart                # Ministry API HTML parsing
│   ├── prayer_times_parser.dart                # Prayer time parsing utilities
│   ├── prayer_times_provider.dart              # Unified prayer times provider
│   ├── offline_adhan.dart                      # Offline prayer calculation (19°/17°)
│   ├── translation_transliteration.dart        # Arabic/Latin city translations
│   └── notifications/
│       ├── notifications.dart                  # Core notification handling
│       ├── notification_config.dart            # Notification channel configuration
│       ├── notification_manager.dart           # Notification lifecycle management
│       ├── prayer_notification_scheduler.dart  # Prayer time notification scheduling
│       └── reminder_notification_scheduler.dart # Reminder notification scheduling
├── widgets/
│   ├── index.dart                              # Widget exports
│   ├── widget_info_manager.dart                # Widget cache management (main)
│   ├── widget_cache_service.dart               # Cache persistence (SharedPreferences)
│   ├── widget_cache_updater.dart               # Cache update logic
│   ├── widget_info_manager.dart                # Widget info retrieval
│   ├── widget_cache_example.dart               # Example widget cache implementation
│   └── widget_prayer_times_parser.dart         # Widget-specific prayer parsing
└── utils/
    └── responsive_sizes.dart                   # Responsive UI sizing (%)

android/app/src/main/
├── kotlin/com/example/pray_time/
│   ├── MainActivity.kt                         # Dart↔Android communication bridge
│   ├── PrayerWidgetProvider.kt                 # Vertical/minimal widget provider (3-column)
│   ├── PrayerWidgetProviderHorizontal.kt       # Horizontal widget provider (2x3 grid)
│   ├── WidgetCacheUpdateWorker.kt              # WorkManager background worker
│   ├── BootCompletionReceiver.kt               # Boot completion handler
│   └── WidgetManualRefreshReceiver.kt          # Manual refresh broadcast receiver
└── res/layout/
    ├── prayer_widget_minimal.xml               # Vertical widget layout (3 prayers per column)
    └── prayer_widget_horizontal.xml            # Horizontal widget layout (2x3 grid)
```

## Performance Notes

- **Widget refresh:** is done by the daiy refresh
- **Daily refresh:** Background task (minimal impact)
- **Notifications:** Scheduled at specific prayer times
- **Cache:** Expires daily/monthly. is checked everyday, if its not expired nothing happpens, or at least it should
- **Memory:** ~50MB typical usage

## License

GNU GENERAL PUBLIC LICENSE - See LICENSE file for details

## Contributing

i dont have the skills to manage this so just fork if you are too lazy to make your own proper app


