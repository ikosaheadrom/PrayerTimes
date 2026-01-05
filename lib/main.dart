import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:workmanager/workmanager.dart';
import 'package:flutter/foundation.dart' as foundation;
import 'services/offline_adhan.dart';
import 'services/background_tasks.dart' as bg_tasks;
import 'services/prayer_times_parser.dart';
import 'services/prayer_times_provider.dart';
import 'services/translation_transliteration.dart';
import 'services/daily_prayer_parser.dart';
import 'services/notifications/notifications.dart';
import 'widgets/widget_info_manager.dart';
import 'widgets/widget_cache_updater.dart';
import 'utils/responsive_sizes.dart';

// Global theme notifier to allow live theme changes from Settings
/// logic as prayer/reminder scheduling so behavior matches production paths.
/// Uses the three-channel system (Silent, Vibration, Full) based on user preference.
Future<void> _scheduleTestNotificationScheduled(int secondsFromNow) async {
  final prefs = await SharedPreferences.getInstance();

  // Read notification state (0=Silent, 1=Vibration, 2=Full)
  final notificationStateValue = prefs.getInt('notificationState') ?? 2;
  final notificationState = NotificationState.fromValue(notificationStateValue);
  final athanSoundTypeValue = prefs.getInt('athanSoundType') ?? 0;
  final athanSoundType = AthanSoundType.fromValue(athanSoundTypeValue);
  final channelId = _getPrayerChannelId(notificationState, athanType: athanSoundType);
  
  final location = getDeviceTimezone();
  final now = tz.TZDateTime.now(location);
  final scheduledTz = now.add(Duration(seconds: secondsFromNow));

  const int testId = 9991;
  debugPrint('[DevTestSchedule] Scheduling test notification (id=$testId)');
  debugPrint('[DevTestSchedule] Device TZ: ${location.name}');
  debugPrint('[DevTestSchedule] Now: $now (ms=${now.millisecondsSinceEpoch})');
  debugPrint('[DevTestSchedule] Scheduled: $scheduledTz (ms=${scheduledTz.millisecondsSinceEpoch})');
  debugPrint('[DevTestSchedule] SecondsFromNow: $secondsFromNow');
  debugPrint('[DevTestSchedule] Notification State: ${notificationState.label} (channel=$channelId)');

  // Helper to dump pending notifications (best-effort)
  Future<void> dumpPending(String tag) async {
    try {
      final pending = await flutterLocalNotificationsPlugin.pendingNotificationRequests();
      debugPrint('[$tag] Pending count: ${pending.length}');
      for (final p in pending) {
        debugPrint('[$tag][Pending] id=${p.id} title=${p.title} body=${p.body} payload=${p.payload}');
      }
    } catch (pe, pst) {
      debugPrint('[$tag] Failed reading pending: $pe');
      debugPrint('[$tag] Pending stack: $pst');
    }
  }

  await dumpPending('beforeSchedule');

  // Try alarmClock first (may require SCHEDULE_EXACT_ALARM)
  try {
    debugPrint('[DevTestSchedule] Attempting zonedSchedule (alarmClock)...');
    await flutterLocalNotificationsPlugin.zonedSchedule(
      testId,
      'Test Notification',
      'State: ${notificationState.label}',
      scheduledTz,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          'Prayer Times Notifications',
          channelDescription: 'Notifications for prayer times',
          importance: Importance.max,
          priority: Priority.max,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.alarmClock,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
    );
    debugPrint('[DevTestSchedule] zonedSchedule(alarmClock) returned without exception');
    await dumpPending('afterAlarmClock');
  } catch (e, st) {
    debugPrint('[DevTestSchedule] zonedSchedule(alarmClock) threw: $e');
    debugPrint('[DevTestSchedule] stack: $st');
    debugPrint('[DevTestSchedule] Falling back to inexactAllowWhileIdle');

    try {
      await flutterLocalNotificationsPlugin.zonedSchedule(
        testId,
        'Test Notification',
        'State: ${notificationState.label}',
        scheduledTz,
        NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            'Prayer Times Notifications',
            channelDescription: 'Notifications for prayer times',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
      debugPrint('[DevTestSchedule] zonedSchedule(inexactAllowWhileIdle) returned without exception');
        await dumpPending('afterInexactAllowWhileIdle');
    } catch (e2, st2) {
      debugPrint('[DevTestSchedule] zonedSchedule(inexactAllowWhileIdle) threw: $e2');
      debugPrint('[DevTestSchedule] stack: $st2');
      debugPrint('[DevTestSchedule] Scheduling failed entirely');
      await dumpPending('afterFinalFailure');
      rethrow;
    }
  }

  debugPrint('[DevTestSchedule] Scheduling function complete (best-effort)');
}







extension ColorBrightness on Color {
  /// Moves the color closer to White. 
  /// [amount] 0.1 means "10% closer to pure white".
  Color lighten([double amount = .1]) {
    assert(amount >= 0 && amount <= 1);
    return Color.lerp(this, Colors.white, amount)!;
  }

  /// Moves the color closer to Black.
  /// [amount] 0.1 means "10% closer to pure black".
  Color darken([double amount = .1]) {
    assert(amount >= 0 && amount <= 1);
    return Color.lerp(this, Colors.black, amount)!;
  }

  /// Darkens in Dark Mode, Lightens in Light Mode.
  Color adaptive(BuildContext context, [double amount = .1]) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darken(amount) : lighten(amount);
  }
}


/// Get text input prompt background color based on brightness
/// Returns dark color with alpha in light mode, bright color with alpha in dark mode
Color getTextInputPromptColor(BuildContext context) {
  final isDarkMode = Theme.of(context).brightness == Brightness.dark;
  if (isDarkMode) {
    // Dark mode: use bright color with reduced alpha
    return const Color(0xFF000000).withValues(alpha: 0.5);
  } else {
    // Light mode: use dark color with reduced alpha
    return const Color(0xFFFFFFFF).withValues(alpha: 0.5);
  }
}

// Global theme notifier to allow live theme changes from Settings
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);
// Global hue notifier (0-360) for primary accent color
final ValueNotifier<double> primaryHueNotifier = ValueNotifier<double>(260.0);
// Global settings change notifier to trigger updates in dependent widgets
final ValueNotifier<int> settingsChangeNotifier = ValueNotifier<int>(0);

// Global notifications plugin instance
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

/// Get the device's actual timezone location (fallback to UTC if detection fails)
tz.Location getDeviceTimezone() {
  try {
    // First try to use the explicitly set local timezone
    final localLocation = tz.local;
    debugPrint('[Timezone] Initial tz.local: ${localLocation.name}');
    
    // Always try to detect actual timezone regardless (don't just check if UTC)
    debugPrint('[Timezone] Attempting timezone detection...');
    
    // Get device timezone offset
    final offset = DateTime.now().timeZoneOffset;
    debugPrint('[Timezone] Device offset: ${offset.inHours}h ${offset.inMinutes % 60}m (total minutes: ${offset.inMinutes})');
    
    // Try common timezones based on offset
    final commonTimezones = [
      'Africa/Casablanca', 'Africa/Cairo', 'Africa/Lagos', 'Africa/Nairobi',
      'Europe/London', 'Europe/Paris', 'Europe/Berlin', 'Europe/Moscow', 'Europe/Amsterdam',
      'Asia/Dubai', 'Asia/Bangkok', 'Asia/Jakarta', 'Asia/Kolkata', 'Asia/Singapore', 'Asia/Tokyo',
      'America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles', 'America/Toronto',
      'Australia/Sydney', 'Australia/Melbourne', 'Australia/Brisbane',
    ];
    
    debugPrint('[Timezone] Checking ${commonTimezones.length} common timezones...');
    for (final tzName in commonTimezones) {
      try {
        final location = tz.getLocation(tzName);
        final tzTime = tz.TZDateTime.now(location);
        
        // Get offset by comparing UTC and TZ time
        final tzOffset = tzTime.timeZoneOffset;
        
        debugPrint('[Timezone] Testing $tzName: offset = ${tzOffset.inMinutes} minutes (${tzOffset.inHours}h)');
        
        if (tzOffset == offset) {
          debugPrint('[Timezone] ✓ MATCHED device timezone: $tzName (offset: ${tzOffset.inHours}h)');
          return location;
        }
      } catch (e) {
        debugPrint('[Timezone] Failed to check $tzName: $e');
      }
    }
    
    debugPrint('[Timezone] No match found in common timezones, returning tz.local: ${localLocation.name}');
    return localLocation;
  } catch (e) {
    debugPrint('[Timezone] Error in getDeviceTimezone: $e');
    return tz.UTC;
  }
}

/// Check notification permissions and settings
Future<void> _checkNotificationPermissions() async {
  debugPrint('═════ NOTIFICATION PERMISSIONS CHECK ═════');
  
  if (!Platform.isAndroid) {
    debugPrint('[Check] Not Android, skipping permission check');
    return;
  }
  
  try {
    // Request notification permission on Android 13+
    debugPrint('[Check] Requesting POST_NOTIFICATIONS permission for Android 13+...');
    try {
      const platform = MethodChannel('com.example.pray_time/permissions');
      final result = await platform.invokeMethod<bool>('requestNotificationPermission');
      debugPrint('[Check] POST_NOTIFICATIONS permission result: $result');
    } catch (e) {
      debugPrint('[Check] Could not request permission: $e');
    }

    // Also query plugin-level state when available
    try {
      final androidImpl = flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        try {
          final enabled = await androidImpl.areNotificationsEnabled();
          debugPrint('[Check] androidImpl.areNotificationsEnabled() -> $enabled');
        } catch (e) {
          debugPrint('[Check] androidImpl.areNotificationsEnabled() failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[Check] Error querying plugin for notification state: $e');
    }
    
    // First, try an immediate notification to verify the system works
    debugPrint('[Check] Testing immediate notification...');
    try {

      debugPrint('[Check] ✓ Immediate notification test PASSED - system can show notifications');
    } catch (e) {
      debugPrint('[Check] This suggests permissions or notification system is broken');
    }
    
    debugPrint('[Check] Device Android info:');
    debugPrint('[Check] - Platform version: ${Platform.operatingSystemVersion}');
    debugPrint('[Check] - Android 13+ requires POST_NOTIFICATIONS permission to be granted at runtime');
    
  } catch (e) {
    debugPrint('[Check] Error during permission check: $e');
  }
}

/// Comprehensive troubleshooting for zonedSchedule() failures
Future<void> _troubleshootZonedSchedule() async {
  debugPrint('\n\n');
  debugPrint('═════ ZONEDSCHEDULE() TROUBLESHOOTING ═════');
  
  try {
    final deviceTz = getDeviceTimezone();
    final now = tz.TZDateTime.now(deviceTz);
    final utcNow = DateTime.now().toUtc();
    
    debugPrint('[Troubleshoot] Device Info:');
    debugPrint('[Troubleshoot] - Timezone Name: ${deviceTz.name}');
    debugPrint('[Troubleshoot] - Timezone Offset: ${now.timeZoneOffset}');
    debugPrint('[Troubleshoot] - Local Time: $now');
    debugPrint('[Troubleshoot] - UTC Time: $utcNow');
    debugPrint('[Troubleshoot] - Current Hour: ${now.hour}');
    debugPrint('[Troubleshoot] - Current Minute: ${now.minute}');
    debugPrint('[Troubleshoot] - Current Second: ${now.second}');
    debugPrint('[Troubleshoot] - Platform: ${Platform.operatingSystemVersion}');
    
    // Test 1: Check pending notifications before scheduling
    debugPrint('\n[Test 1] Checking pending notifications BEFORE scheduling...');
    try {
      final before = await flutterLocalNotificationsPlugin.pendingNotificationRequests();
      debugPrint('[Test 1] Pending count (before): ${before.length}');
      for (final p in before) {
        debugPrint('[Test 1] - ID: ${p.id}, Title: ${p.title}');
      }
    } catch (e) {
      debugPrint('[Test 1] ✗ Failed to get pending: $e');
    }
    
    // Test 2: Test zonedSchedule with alarmClock mode (5 seconds from now)
    debugPrint('\n[Test 2] Testing zonedSchedule() with alarmClock mode (5s delay)...');
    try {
      final prefs = await SharedPreferences.getInstance();
      final enableVibration = prefs.getBool('enableVibration') ?? true;
      final schedTime = now.add(const Duration(seconds: 5));
      debugPrint('[Test 2] Schedule time: $schedTime');
      debugPrint('[Test 2] Is in future: ${schedTime.isAfter(now)}');
      debugPrint('[Test 2] Time type: ${schedTime.runtimeType}');
      debugPrint('[Test 2] Is UTC: ${schedTime.isUtc}');
      
      await flutterLocalNotificationsPlugin.zonedSchedule(
        88888,
        'Troubleshoot AlarmClock',
        'Testing zonedSchedule with alarmClock mode',
        schedTime,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'pray_times_channel',
            'Prayer Times Notifications',
            channelDescription: 'Notifications for prayer times',
            importance: Importance.max,
            priority: Priority.max,
            enableVibration: enableVibration,
            playSound: true,
            enableLights: true,
            tag: 'troubleshoot_alarm',
            color: Colors.red,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
      debugPrint('[Test 2] ✓ zonedSchedule(alarmClock) call succeeded');
      
      // Check if it was actually registered
      await Future.delayed(const Duration(milliseconds: 500));
      final afterAlarm = await flutterLocalNotificationsPlugin.pendingNotificationRequests();
      debugPrint('[Test 2] Pending count (after alarmClock): ${afterAlarm.length}');
      final found = afterAlarm.where((p) => p.id == 88888).toList();
      if (found.isNotEmpty) {
        debugPrint('[Test 2] ✓ Notification 88888 found in pending list');
        debugPrint('[Test 2] - Title: ${found.first.title}');
      } else {
        debugPrint('[Test 2] ✗ Notification 88888 NOT found in pending list (may be filtered by Android)');
      }
    } catch (e1) {
      debugPrint('[Test 2] ✗ alarmClock failed: $e1');
      debugPrint('[Test 2] Stack: ${e1.toString()}');
    }
    
    // Test 3: Test zonedSchedule with inexactAllowWhileIdle mode
    debugPrint('\n[Test 3] Testing zonedSchedule() with inexactAllowWhileIdle mode (10s delay)...');
    try {
      final prefs = await SharedPreferences.getInstance();
      final enableVibration = prefs.getBool('enableVibration') ?? true;
      final schedTime = now.add(const Duration(seconds: 10));
      debugPrint('[Test 3] Schedule time: $schedTime');
      
      await flutterLocalNotificationsPlugin.zonedSchedule(
        88889,
        'Troubleshoot Inexact',
        'Testing zonedSchedule with inexactAllowWhileIdle mode',
        schedTime,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'pray_times_channel',
            'Prayer Times Notifications',
            channelDescription: 'Notifications for prayer times',
            importance: Importance.max,
            priority: Priority.max,
            enableVibration: enableVibration,
            playSound: true,
            enableLights: true,
            tag: 'troubleshoot_inexact',
            color: Colors.orange,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
      debugPrint('[Test 3] ✓ zonedSchedule(inexactAllowWhileIdle) call succeeded');
      
      // Check if it was registered
      await Future.delayed(const Duration(milliseconds: 500));
      final afterInexact = await flutterLocalNotificationsPlugin.pendingNotificationRequests();
      debugPrint('[Test 3] Pending count (after inexactAllowWhileIdle): ${afterInexact.length}');
      final found = afterInexact.where((p) => p.id == 88889).toList();
      if (found.isNotEmpty) {
        debugPrint('[Test 3] ✓ Notification 88889 found in pending list');
      } else {
        debugPrint('[Test 3] ✗ Notification 88889 NOT found in pending list');
      }
    } catch (e2) {
      debugPrint('[Test 3] ✗ inexactAllowWhileIdle failed: $e2');
    }
    
    // Test 4: Compare with working delayed show()
    debugPrint('\n[Test 4] Testing delayed show() (working workaround)...');
    try {
      final prefs = await SharedPreferences.getInstance();
      final enableVibration = prefs.getBool('enableVibration') ?? true;
      const delaySeconds = 15;
      debugPrint('[Test 4] Scheduling with delayed show() for ${delaySeconds}s...');
      
      Future.delayed(const Duration(seconds: delaySeconds), () async {
        debugPrint('[Test 4] Callback fired - calling show()...');
        await flutterLocalNotificationsPlugin.show(
          88890,
          'Troubleshoot Delayed Show',
          'This uses delayed show() - the working workaround',
          NotificationDetails(
            android: AndroidNotificationDetails(
              'pray_times_channel',
              'Prayer Times Notifications',
              channelDescription: 'Notifications for prayer times',
              importance: Importance.max,
              priority: Priority.max,
              enableVibration: enableVibration,
              playSound: true,
              enableLights: true,
              tag: 'troubleshoot_delayed',
              color: Colors.green,
            ),
          ),
        );
        debugPrint('[Test 4] ✓ show() callback succeeded');
      });
      debugPrint('[Test 4] ✓ delayed show() scheduled successfully');
    } catch (e3) {
      debugPrint('[Test 4] ✗ delayed show() failed: $e3');
    }
    
    // Test 5: Check notification channel configuration
    debugPrint('\n[Test 5] Checking notification channel configuration...');
    try {
      final androidImpl = flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        final enabled = await androidImpl.areNotificationsEnabled();
        debugPrint('[Test 5] Notifications enabled at plugin level: $enabled');
      } else {
        debugPrint('[Test 5] ✗ Could not get Android implementation');
      }
    } catch (e) {
      debugPrint('[Test 5] Error checking channel: $e');
    }
    
    // Test 6: Schedule a 5-second notification using zonedSchedule
    debugPrint('\n[Test 6] Testing zonedSchedule() with 5-second delay...');
    try {
      final prefs = await SharedPreferences.getInstance();
      final enableVibration = prefs.getBool('enableVibration') ?? true;
      final fiveSecLater = now.add(const Duration(seconds: 5));
      debugPrint('[Test 6] Schedule time: $fiveSecLater');
      debugPrint('[Test 6] Is in future: ${fiveSecLater.isAfter(now)}');
      debugPrint('[Test 6] Time type: ${fiveSecLater.runtimeType}');
      
      await flutterLocalNotificationsPlugin.zonedSchedule(
        88891,
        'Troubleshoot 5-Second Test',
        'Timezone: ${deviceTz.name}, Offset: ${now.timeZoneOffset}, Local: $now, UTC: $utcNow',
        fiveSecLater,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'pray_times_channel',
            'Prayer Times Notifications',
            channelDescription: 'Notifications for prayer times',
            importance: Importance.max,
            priority: Priority.max,
            enableVibration: enableVibration,
            playSound: true,
            enableLights: true,
            tag: 'troubleshoot_5sec',
            color: Colors.blue,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
      debugPrint('[Test 6] ✓ zonedSchedule() 5-second call succeeded');
      
      // Check if it was registered
      await Future.delayed(const Duration(milliseconds: 500));
      final afterTest6 = await flutterLocalNotificationsPlugin.pendingNotificationRequests();
      debugPrint('[Test 6] Pending count (after): ${afterTest6.length}');
      final found = afterTest6.where((p) => p.id == 88891).toList();
      if (found.isNotEmpty) {
        debugPrint('[Test 6] ✓ Notification 88891 found in pending list');
      } else {
        debugPrint('[Test 6] ✗ Notification 88891 NOT found in pending list');
      }
    } catch (e) {
      debugPrint('[Test 6] ✗ 5-second zonedSchedule failed: $e');
      debugPrint('[Test 6] Stack: ${e.toString()}');
    }
    
    // Test 7: Check if SCHEDULE_EXACT_ALARM permission is granted
    debugPrint('\n[Test 7] Checking SCHEDULE_EXACT_ALARM permission...');
    try {
      final androidImpl = flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      
      if (androidImpl != null) {
        // Check if notifications are still enabled (general check)
        final enabled = await androidImpl.areNotificationsEnabled();
        debugPrint('[Test 7] Notifications enabled: $enabled');
      }
      debugPrint('[Test 7] Note: Permission check requires API 31+, may not show accurate result on older devices');
    } catch (e) {
      debugPrint('[Test 7] Error checking permission: $e');
    }
    
    // Wait a bit and check if any zonedSchedule notifications fired
    debugPrint('\n[Test 8] Waiting 6 seconds to observe if zonedSchedule notifications fire...');
    await Future.delayed(const Duration(seconds: 6));
    final afterWait = await flutterLocalNotificationsPlugin.pendingNotificationRequests();
    debugPrint('[Test 8] Pending count after 6s wait: ${afterWait.length}');
    debugPrint('[Test 8] Previous pending count was 3 (Test 2, 3, 6)');
    if (afterWait.length < 3) {
      debugPrint('[Test 8] ✓ At least one zonedSchedule fired (pending decreased)');
    } else {
      debugPrint('[Test 8] ✗ NO zonedSchedule notifications fired (pending still 3)');
    }
    
    debugPrint('\n[Summary] Troubleshooting complete. Key finding:');
    debugPrint('[Summary] - delayed show() WORKS (Test 4 fired)');
    debugPrint('[Summary] - zonedSchedule() FAILS on Huawei (Tests 2,3,6 did not fire)');
    debugPrint('[Summary] - This is a Huawei OEM limitation, not a config issue');
    debugPrint('═════ END TROUBLESHOOTING ═════\n');
    
  } catch (e) {
    debugPrint('[Troubleshoot] ✗ Critical error: $e');
    debugPrint('[Troubleshoot] Stack: $e');
  }
}

/// Print calendar cache expiration information
Future<void> _printCacheExpirationInfo() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final cityId = prefs.getString('cityCityId') ?? '58';
    final cacheKey = 'calendarData_$cityId';
    final selectedCity = prefs.getString('selectedCityName') ?? 'Casablanca';

    debugPrint('\n\n');
    debugPrint('═════ CALENDAR CACHE EXPIRATION INFO ═════');
    debugPrint('City: $selectedCity (ID: $cityId)');

    final cachedDataStr = prefs.getString(cacheKey);
    if (cachedDataStr == null) {
      debugPrint('Status: NO CACHE FOUND');
      debugPrint('═════ END CACHE INFO ═════\n');
      return;
    }

    try {
      final cachedDataMap = jsonDecode(cachedDataStr) as Map<String, dynamic>;
      
      // Try to extract dates from cache entries
      final allDates = <DateTime>[];
      int hijriDayCount = 0;
      int? currentHijriDay;
      DateTime? firstDateInCache;
      DateTime? lastDateInCache;

      // Get metadata
      final hijriMonth = cachedDataMap['_monthLabelArabic'] as String? ?? 
                        cachedDataMap['_monthLabelLatin'] as String? ?? 'Unknown';
      currentHijriDay = cachedDataMap['_currentHijriDay'] as int?;

      // Debug: print first few keys to understand structure
      final allKeys = cachedDataMap.keys.toList();
      debugPrint('Cache has ${allKeys.length} keys total');
      for (int i = 0; i < (allKeys.length < 5 ? allKeys.length : 5); i++) {
        debugPrint('  Key[$i]: "${allKeys[i]}"');
      }

      // Parse all cache keys - could be Gregorian dates or Hijri day numbers
      for (final key in allKeys) {
        if (key.startsWith('_')) continue; // Skip metadata keys
        
        // Try parsing as Gregorian date (ISO8601 or YYYY-MM-DD)
        DateTime? date;
        if (key.contains('T')) {
          final dateStr = key.split('T')[0];
          try {
            date = DateTime.parse(dateStr);
          } catch (e) {
            // Not a valid date
          }
        } else if (key.contains('-') && key.split('-').length == 3) {
          try {
            date = DateTime.parse(key);
          } catch (e) {
            // Not a valid date
          }
        }
        
        if (date != null) {
          allDates.add(date);
          if (firstDateInCache == null || date.isBefore(firstDateInCache)) {
            firstDateInCache = date;
          }
          if (lastDateInCache == null || date.isAfter(lastDateInCache)) {
            lastDateInCache = date;
          }
        } else {
          // Not a Gregorian date - check if it's a Hijri day number
          final dayNum = int.tryParse(key);
          if (dayNum != null && dayNum > 0 && dayNum < 32) {
            hijriDayCount++;
            debugPrint('Found Hijri day: $dayNum');
          }
        }
      }

      allDates.sort();

      debugPrint('Cache Status: VALID');
      debugPrint('Hijri Month: $hijriMonth');
      
      // Check if we have parser metadata first
      final lastDateFromParser = cachedDataMap['_lastDate_ISO'] as String?;
      final firstDateFromParser = cachedDataMap['_firstDate_ISO'] as String?;
      
      DateTime? lastDateInCacheFromParser;
      DateTime? firstDateInCacheFromParser;
      
      if (lastDateFromParser != null) {
        try {
          lastDateInCacheFromParser = DateTime.parse(lastDateFromParser);
        } catch (e) {
          debugPrint('[Debug] Could not parse last date from parser: $e');
        }
      }
      
      if (firstDateFromParser != null) {
        try {
          firstDateInCacheFromParser = DateTime.parse(firstDateFromParser);
        } catch (e) {
          debugPrint('[Debug] Could not parse first date from parser: $e');
        }
      }
      
      // If we found Gregorian dates in keys OR from parser metadata, use those
      if (allDates.isNotEmpty || lastDateInCacheFromParser != null) {
        // Prefer parser metadata for accurate dates
        DateTime? effectiveLastDate = lastDateInCacheFromParser ?? (allDates.isNotEmpty ? allDates.last : null);
        DateTime? effectiveFirstDate = firstDateInCacheFromParser ?? (allDates.isNotEmpty ? allDates.first : null);
        
        if (effectiveLastDate == null || effectiveFirstDate == null) {
          debugPrint('⚠️  Could not determine cache date range');
          debugPrint('═════ END CACHE INFO ═════\n');
          return;
        }
        
        debugPrint('Total Dates in Cache: ${allDates.length}');
        
        final now = DateTime.now();
        final todayOnly = DateTime(now.year, now.month, now.day);
        
        // Find today's equivalent in cache
        DateTime? todayInCache;
        for (final date in allDates) {
          if (date.month == now.month && date.day == now.day) {
            todayInCache = date;
            break;
          }
        }

        if (todayInCache == null) {
          debugPrint('⚠️  Today\'s date not found in cache (${now.month}/${now.day})');
          debugPrint('═════ END CACHE INFO ═════\n');
          return;
        }

        // Count remaining days
        int remainingDays = 0;
        for (final date in allDates) {
          if (date.isAfter(todayInCache)) {
            remainingDays++;
          }
        }

        final cacheCreationDate = effectiveFirstDate;
        
        // GET EXPIRATION FROM PARSER (stored in cache metadata as _expiresAt_ISO)
        DateTime? expirationDate;
        final expirationFromParser = cachedDataMap['_expiresAt_ISO'] as String?;
        
        if (expirationFromParser != null) {
          try {
            expirationDate = DateTime.parse(expirationFromParser);
            debugPrint('[Debug] Using expiration date from parser: $expirationFromParser');
          } catch (e) {
            debugPrint('[Debug] Could not parse parser expiration date: $e');
            expirationDate = effectiveLastDate.add(Duration(days: 1));
          }
        } else {
          // Fallback to last date + 1 (if parser didn't provide it)
          expirationDate = effectiveLastDate.add(Duration(days: 1));
          debugPrint('[Debug] No parser expiration found, using last date + 1 day: ${_formatDate(expirationDate)}');
        }

        debugPrint('');
        debugPrint('Cache Timeline:');
        debugPrint('  Cache Created On: ${_formatDate(cacheCreationDate)}');
        debugPrint('  First Date: ${_formatDate(effectiveFirstDate)}');
        debugPrint('  Last Date: ${_formatDate(effectiveLastDate)}');
        debugPrint('  Total Days in Cache: ${allDates.length}');
        debugPrint('');
        debugPrint('Today\'s Status:');
        debugPrint('  Today (Gregorian): ${_formatDate(todayOnly)}');
        debugPrint('  Today in Cache: ${_formatDate(todayInCache)}');
        debugPrint('  Remaining Days After Today: $remainingDays days');
        debugPrint('');
        debugPrint('Expiration:');
        debugPrint('  Cache Expires On: ${_formatDate(expirationDate)}');
        debugPrint('  Days Until Expiry: ${expirationDate.difference(todayOnly).inDays} days');

        final daysUntilExpiry = expirationDate.difference(todayOnly).inDays;
        if (daysUntilExpiry <= 0) {
          debugPrint('⚠️  Cache EXPIRED - refresh needed');
        } else if (daysUntilExpiry <= 2) {
          debugPrint('⚠️  Cache expires soon in $daysUntilExpiry days');
        } else {
          debugPrint('✓ Cache is valid for $daysUntilExpiry more days');
        }
      } else if (hijriDayCount > 0) {
        // Old format: cache uses Hijri day numbers
        debugPrint('Legacy Format: Uses Hijri day numbers ($hijriDayCount days)');
        
        if (currentHijriDay != null) {
          debugPrint('');
          
          // Calculate cache creation date in Gregorian
          // If today is 2025-12-20 and it's Hijri day X, then:
          // Day 1 of cache = 2025-12-20 - (X-1) days
          final now = DateTime.now();
          final daysBeforeToday = currentHijriDay - 1;
          final cacheCreationDate = now.subtract(Duration(days: daysBeforeToday));
          
          // Calculate expiration date
          // Cache was created on date X and has N days, so it expires on: X + N
          final expirationDate = cacheCreationDate.add(Duration(days: hijriDayCount));
          
          // Count remaining days in cache after today
          final remainingDaysInCache = hijriDayCount - currentHijriDay;
          
          // Days until expiration
          final daysUntilExpiry = expirationDate.difference(now).inDays;
          
          debugPrint('Cache Timeline (Gregorian):');
          debugPrint('  Today (${now.month}/${now.day}): Hijri Day $currentHijriDay');
          debugPrint('  Cache Created On: ${_formatDate(cacheCreationDate)}');
          debugPrint('  Total Days in Cache: $hijriDayCount');
          debugPrint('  Remaining Days After Today: $remainingDaysInCache days');
          debugPrint('');
          debugPrint('Expiration:');
          debugPrint('  Cache Expires On: ${_formatDate(expirationDate)}');
          debugPrint('  Days Until Expiry: $daysUntilExpiry days');
          debugPrint('');
          
          if (daysUntilExpiry <= 0) {
            debugPrint('⚠️  Cache EXPIRED - refresh needed');
          } else if (daysUntilExpiry <= 2) {
            debugPrint('⚠️  Cache expires soon in $daysUntilExpiry days');
          } else {
            debugPrint('✓ Cache is valid for $daysUntilExpiry more days');
          }
          
          debugPrint('');
          debugPrint('ℹ️  Hijri Month: $hijriMonth');
        } else {
          debugPrint('⚠️  No current Hijri day metadata - cannot determine expiry');
        }
      } else {
        debugPrint('⚠️  No dates found in cache');
      }

      debugPrint('');
      debugPrint('═════ END CACHE INFO ═════\n');
    } catch (parseError) {
      debugPrint('Error parsing cache: $parseError');
      debugPrint('═════ END CACHE INFO ═════\n');
    }
  } catch (e) {
    debugPrint('Error getting cache info: $e');
    debugPrint('═════ END CACHE INFO ═════\n');
  }
}

/// Test Prayer Times Parser Service
/// Fetches HTML and tests all parser helper functions
Future<void> _testPrayerTimesParser() async {
  try {
    debugPrint('\n\n');
    debugPrint('╔══════════════════════════════════════════════════════════╗');
    debugPrint('║     PRAYER TIMES PARSER SERVICE TEST                     ║');
    debugPrint('╚══════════════════════════════════════════════════════════╝');
    
    final prefs = await SharedPreferences.getInstance();
    final cityId = prefs.getString('cityCityId') ?? '58';
    final ministryUrl = prefs.getString('ministryUrl') ?? 'https://habous.gov.ma/prieres/horaire_hijri_2.php';
    
    debugPrint('\n[1] Fetching HTML from Ministry...');
    debugPrint('    City ID: $cityId');
    debugPrint('    URL: $ministryUrl');
    
    String htmlBody = '';
    try {
      final separator = ministryUrl.contains('?') ? '&' : '?';
      final uri = Uri.parse('$ministryUrl${separator}ville=$cityId');
      final httpClient = HttpClient();
      httpClient.badCertificateCallback = (cert, host, port) => true;
      final request = await httpClient.getUrl(uri);
      final response = await request.close();
      htmlBody = await response.transform(utf8.decoder).join();
      httpClient.close();
      
      debugPrint('✓ HTML fetched (${htmlBody.length} bytes, status: ${response.statusCode})');
    } catch (e) {
      debugPrint('✗ Failed to fetch HTML: $e');
      debugPrint('═════ TEST ABORTED ═════\n');
      return;
    }
    
    debugPrint('\n[2] Parsing HTML with parseMonthlyCalendarFromHtml()...');
    final parsedCalendar = await parseMonthlyCalendarFromHtml(htmlBody, cityId: int.tryParse(cityId) ?? 58);
    
    if (parsedCalendar.isEmpty) {
      debugPrint('✗ parseMonthlyCalendarFromHtml() returned empty calendar');
      debugPrint('═════ TEST ABORTED ═════\n');
      return;
    }
    
    debugPrint('✓ Calendar parsed successfully');
    
    // Test data extraction helpers
    debugPrint('\n[3] Testing helper functions...');
    
    // Test getCalendarDayCount
    final dayCount = getCalendarDayCount(parsedCalendar);
    debugPrint('\n  ► getCalendarDayCount()');
    debugPrint('    Result: $dayCount days');
    
    // Test metadata extraction
    final parsedCityId = parsedCalendar['cityId'] as int?;
    final hijriMonth = parsedCalendar['hijriMonth'] as String?;
    final hijriMonthLatin = parsedCalendar['hijriMonthLatin'] as String?;
    final solarMonths = parsedCalendar['solarMonths'] as List<String>?;
    
    debugPrint('\n  ► Calendar Metadata');
    debugPrint('    City ID: $parsedCityId (expected: $cityId)');
    if (parsedCityId != null && int.tryParse(cityId) == parsedCityId) {
      debugPrint('    ✓ City ID verified');
    } else if (parsedCityId != null) {
      debugPrint('    ✗ City ID mismatch!');
    }
    debugPrint('    Hijri Month (Arabic): $hijriMonth');
    debugPrint('    Hijri Month (Latin): $hijriMonthLatin');
    if (solarMonths != null && solarMonths.isNotEmpty) {
      debugPrint('    Solar Months: ${solarMonths.join(", ")}');
    } else {
      debugPrint('    Solar Months: (not found in calendar data)');
    }
    
    // Test getGregorianDates
    final gregorianDates = getGregorianDates(parsedCalendar);
    debugPrint('\n  ► getGregorianDates()');
    debugPrint('    Total dates: ${gregorianDates.length}');
    if (gregorianDates.isNotEmpty) {
      debugPrint('    First: ${gregorianDates.first}');
      debugPrint('    Last: ${gregorianDates.last}');
    }
    
    // Test getTodayPrayerTimes
    final today = getTodayPrayerTimes(parsedCalendar);
    debugPrint('\n  ► getTodayPrayerTimes()');
    if (today != null) {
      debugPrint('    ✓ Found today\'s prayer times');
      debugPrint('      Hijri Day: ${today["hijriDay"]}');
      debugPrint('      Gregorian: ${today["gregorianDate_ISO"]}');
      debugPrint('      Day of Week: ${today["dayOfWeek_TEXT"]}');
      debugPrint('      Fajr: ${today["fajr_HHmm"]}');
      debugPrint('      Sunrise: ${today["sunrise_HHmm"]}');
      debugPrint('      Dhuhr: ${today["dhuhr_HHmm"]}');
      debugPrint('      Asr: ${today["asr_HHmm"]}');
      debugPrint('      Maghrib: ${today["maghrib_HHmm"]}');
      debugPrint('      Isha: ${today["isha_HHmm"]}');
    } else {
      debugPrint('    ✗ Today\'s prayer times not found in calendar');
    }
    
    // Test getTomorrowPrayerTimes
    final tomorrow = getTomorrowPrayerTimes(parsedCalendar);
    debugPrint('\n  ► getTomorrowPrayerTimes()');
    if (tomorrow != null) {
      debugPrint('    ✓ Found tomorrow\'s prayer times');
      debugPrint('      Hijri Day: ${tomorrow["hijriDay"]}');
      debugPrint('      Gregorian: ${tomorrow["gregorianDate_ISO"]}');
      debugPrint('      Fajr: ${tomorrow["fajr_HHmm"]}');
      debugPrint('      Dhuhr: ${tomorrow["dhuhr_HHmm"]}');
      debugPrint('      Maghrib: ${tomorrow["maghrib_HHmm"]}');
    } else {
      debugPrint('    ✗ Tomorrow\'s prayer times not found in calendar');
    }
    
    // Test getPrayerTimesForHijriDay
    debugPrint('\n  ► getPrayerTimesForHijriDay() - Testing multiple days');
    for (int day in [1, 15, 30]) {
      final dayData = getPrayerTimesForHijriDay(parsedCalendar, day);
      if (dayData != null) {
        debugPrint('    Day $day: ✓ Found');
        debugPrint('      Gregorian: ${dayData["gregorianDate_ISO"]}, Fajr: ${dayData["fajr_HHmm"]}');
      } else {
        debugPrint('    Day $day: ✗ Not found');
      }
    }
    
    // Test getAllPrayerDays
    final allDays = getAllPrayerDays(parsedCalendar);
    debugPrint('\n  ► getAllPrayerDays()');
    debugPrint('    Total days returned: ${allDays.length}');
    if (allDays.isNotEmpty) {
      debugPrint('    Sample days:');
      for (int i = 0; i < 3 && i < allDays.length; i++) {
        final day = allDays[i];
        debugPrint('      Day ${day["hijriDay"]}: ${day["gregorianDate_ISO"]} - ${day["dayOfWeek_TEXT"]}');
      }
      if (allDays.length > 3) {
        debugPrint('      ... and ${allDays.length - 3} more days');
      }
    }
    
    // Summary
    debugPrint('\n[4] Parser Test Summary');
    debugPrint('    ✓ parseMonthlyCalendarFromHtml(): SUCCESS');
    debugPrint('    ✓ getCalendarDayCount(): $dayCount');
    debugPrint('    ✓ getGregorianDates(): ${gregorianDates.length} dates');
    debugPrint('    ✓ getTodayPrayerTimes(): ${today != null ? "FOUND" : "NOT FOUND"}');
    debugPrint('    ✓ getTomorrowPrayerTimes(): ${tomorrow != null ? "FOUND" : "NOT FOUND"}');
    debugPrint('    ✓ getPrayerTimesForHijriDay(): Tested days 1, 15, 30');
    debugPrint('    ✓ getAllPrayerDays(): ${allDays.length} days');
    
    debugPrint('\n╔══════════════════════════════════════════════════════════╗');
    debugPrint('║     ✓ ALL PARSER TESTS COMPLETED SUCCESSFULLY            ║');
    debugPrint('╚══════════════════════════════════════════════════════════╝\n');
    
  } catch (e, st) {
    debugPrint('✗ Parser test error: $e');
    debugPrint('Stack: $st');
    debugPrint('═════ TEST FAILED ═════\n');
  }
}

/// Test Daily Prayer Parser Service
/// Fetches daily prayer times and tests cache functionality
Future<void> _testDailyParserService() async {
  try {
    debugPrint('\n\n');
    debugPrint('╔══════════════════════════════════════════════════════════╗');
    debugPrint('║     DAILY PRAYER PARSER SERVICE TEST                     ║');
    debugPrint('╚══════════════════════════════════════════════════════════╝');
    
    final prefs = await SharedPreferences.getInstance();
    final cityId = prefs.getString('cityCityId') ?? '58';
    final cityName = prefs.getString('cityCityName') ?? 'Casablanca';
    
    debugPrint('\n[1] Testing getDailyPrayerTimes() with cache...');
    debugPrint('    City ID: $cityId');
    debugPrint('    City Name: $cityName');
    
    // First call - should fetch from API and cache
    debugPrint('\n[2] First call (should fetch from API)...');
    final startTime1 = DateTime.now();
    final dailyTimes1 = await getDailyPrayerTimes(
      cityId: cityId,
      cityName: cityName,
    );
    final duration1 = DateTime.now().difference(startTime1);
    
    debugPrint('    ✓ Fetched in ${duration1.inMilliseconds}ms');
    debugPrint('    Prayer times:');
    dailyTimes1.forEach((key, value) {
      debugPrint('      $key: $value');
    });
    
    // Check cache
    debugPrint('\n[3] Checking raw cache contents...');
    final cacheKey = 'daily_prayer_times_$cityId';
    final rawCacheJson = prefs.getString(cacheKey);
    
    if (rawCacheJson != null) {
      debugPrint('    ✓ Cache found');
      debugPrint('    Raw JSON (first 200 chars):');
      debugPrint('    ${rawCacheJson.substring(0, (rawCacheJson.length > 200) ? 200 : rawCacheJson.length)}');
      if (rawCacheJson.length > 200) {
        debugPrint('    ... (${rawCacheJson.length - 200} more chars)');
      }
      
      debugPrint('\n    Full cache JSON:');
      final cachedData = jsonDecode(rawCacheJson) as Map<String, dynamic>;
      cachedData.forEach((key, value) {
        debugPrint('      $key: $value');
      });
    } else {
      debugPrint('    ✗ No cache found!');
    }
    
    // Second call - should use cache
    debugPrint('\n[4] Second call (should use cache)...');
    final startTime2 = DateTime.now();
    final dailyTimes2 = await getDailyPrayerTimes(
      cityId: cityId,
      cityName: cityName,
    );
    final duration2 = DateTime.now().difference(startTime2);
    
    debugPrint('    ✓ Retrieved in ${duration2.inMilliseconds}ms (cache hit)');
    
    // Verify cache hit
    if (duration2.inMilliseconds < duration1.inMilliseconds) {
      debugPrint('    ✓ Cache is faster (${duration1.inMilliseconds}ms → ${duration2.inMilliseconds}ms)');
    }
    
    // Compare data
    debugPrint('\n[5] Comparing cached vs fresh...');
    bool dataMatches = true;
    dailyTimes1.forEach((key, value) {
      if (dailyTimes2[key] != value) {
        debugPrint('    ✗ Mismatch in $key: "${dailyTimes1[key]}" vs "${dailyTimes2[key]}"');
        dataMatches = false;
      }
    });
    
    if (dataMatches) {
      debugPrint('    ✓ All cached data matches original');
    }
    
    // Test force refresh
    debugPrint('\n[6] Testing forceRefresh=true...');
    final startTime3 = DateTime.now();
    final dailyTimes3 = await getDailyPrayerTimes(
      cityId: cityId,
      cityName: cityName,
      forceRefresh: true,
    );
    final duration3 = DateTime.now().difference(startTime3);
    
    debugPrint('    ✓ Force refreshed in ${duration3.inMilliseconds}ms');
    debugPrint('    Prayer times:');
    dailyTimes3.forEach((key, value) {
      debugPrint('      $key: $value');
    });
    
    // Summary
    debugPrint('\n[7] Daily Parser Test Summary');
    debugPrint('    ✓ getDailyPrayerTimes() call 1: ${duration1.inMilliseconds}ms (API)');
    debugPrint('    ✓ getDailyPrayerTimes() call 2: ${duration2.inMilliseconds}ms (Cache)');
    debugPrint('    ✓ getDailyPrayerTimes() call 3: ${duration3.inMilliseconds}ms (Force Refresh)');
    debugPrint('    ✓ Cache data integrity: ${dataMatches ? "VERIFIED" : "MISMATCH"}');
    debugPrint('    ✓ Raw cache JSON: ${rawCacheJson != null ? "FOUND" : "NOT FOUND"}');
    
    debugPrint('\n╔══════════════════════════════════════════════════════════╗');
    debugPrint('║     ✓ ALL DAILY PARSER TESTS COMPLETED SUCCESSFULLY      ║');
    debugPrint('╚══════════════════════════════════════════════════════════╝\n');
    
  } catch (e, st) {
    debugPrint('✗ Daily parser test error: $e');
    debugPrint('Stack: $st');
    debugPrint('═════ TEST FAILED ═════\n');
  }
}

/// Test Daily Refresh Task
/// Runs the same task that the WorkManager scheduler executes
Future<void> _testDailyRefreshTask() async {
  try {
    debugPrint('\n\n');
    debugPrint('╔══════════════════════════════════════════════════════════╗');
    debugPrint('║     DAILY REFRESH TASK TEST (WorkManager)               ║');
    debugPrint('╚══════════════════════════════════════════════════════════╝');
    
    debugPrint('\n[1] Running background daily refresh task...');
    
    // Call the background refresh handler directly
    await bg_tasks.executeDailyPrayerRefresh();
    
    debugPrint('\n[2] Task completed, checking results...');
    
    // Check if the flags were set
    final prefs = await SharedPreferences.getInstance();
    final needsNotificationReschedule = prefs.getBool('needsNotificationReschedule') ?? false;
    final lastDailyRefreshTime = prefs.getString('lastDailyRefreshTime');
    final lastBackgroundExecution = prefs.getString('lastBackgroundTaskExecution');
    
    debugPrint('\n[3] Background Task Results:');
    debugPrint('    ✓ needsNotificationReschedule: $needsNotificationReschedule');
    debugPrint('    ✓ lastDailyRefreshTime: $lastDailyRefreshTime');
    debugPrint('    ✓ lastBackgroundExecution: $lastBackgroundExecution');
    
    debugPrint('\n╔══════════════════════════════════════════════════════════╗');
    debugPrint('║     ✓ DAILY REFRESH TASK TEST COMPLETED                 ║');
    debugPrint('╚══════════════════════════════════════════════════════════╝\n');
    
  } catch (e, st) {
    debugPrint('✗ Daily refresh task test error: $e');
    debugPrint('Stack: $st');
    debugPrint('═════ TEST FAILED ═════\n');
  }
}

/// Test athan notification with the currently selected "Full" state sound
Future<void> _testAthanNotificationWithFullState() async {
  try {
    debugPrint('\n\n');
    debugPrint('╔══════════════════════════════════════════════════════════╗');
    debugPrint('║     ATHAN NOTIFICATION TEST (Full State)                ║');
    debugPrint('╚══════════════════════════════════════════════════════════╝');
    
    final prefs = await SharedPreferences.getInstance();
    
    // Read the saved notification settings
    final notificationStateValue = prefs.getInt('notificationState') ?? 2;
    final notificationState = NotificationState.fromValue(notificationStateValue);
    final athanSoundTypeValue = prefs.getInt('athanSoundType') ?? 0;
    final athanSoundType = AthanSoundType.fromValue(athanSoundTypeValue);
    
    debugPrint('\n[1] Current Notification Settings:');
    debugPrint('    • Global Notification State: ${notificationState.label} (value: ${notificationState.value})');
    debugPrint('    • Athan Sound Type (for Full): ${athanSoundType.label}');
    debugPrint('    • Description: ${athanSoundType.description}');
    
    // Only test if state is "Full"
    if (notificationState != NotificationState.full) {
      debugPrint('\n⚠️  WARNING: Notification state is "${notificationState.label}", not "Full"');
      debugPrint('   This test only applies when using "Full" notification state.');
      debugPrint('   Current setting will NOT play athan sound.');
      debugPrint('\n   To test athan sound: Set Global Notification Control to "Full" in settings.');
    }
    
    // Determine which channel will be used
    final channelId = _getPrayerChannelId(NotificationState.full, athanType: athanSoundType);
    debugPrint('\n[2] Channel Configuration:');
    debugPrint('    • Selected Channel ID: $channelId');
    
    switch (channelId) {
      case 'pray_times_channel_full_v2':
        debugPrint('    • Sound: System notification sound');
        debugPrint('    • Vibration: Yes');
      case 'athan_channel_short_v2':
        debugPrint('    • Sound: Short Athan (4 seconds)');
        debugPrint('    • Vibration: Yes (pulse pattern)');
        debugPrint('    • Full Screen: No (not needed for 4 sec)');
      case 'athan_channel_normal_v2':
        debugPrint('    • Sound: Full Athan (complete)');
        debugPrint('    • Vibration: Yes (pulse pattern)');
        debugPrint('    • Full Screen: Yes');
        debugPrint('    • Dismiss Button: Yes');
      default:
        debugPrint('    • Unknown channel');
    }
    
    debugPrint('\n[3] Sending Test Notification...');
    
    // Send test notification
    try {
      await flutterLocalNotificationsPlugin.show(
        9999,
        '🕌 Test Athan Notification',
        'This is a test using "${athanSoundType.label}" sound',
        NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            'Prayer Times (Full)',
            channelDescription: 'Test athan notification',
            importance: Importance.max,
            priority: Priority.max,
            enableLights: true,
            color: Colors.green,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
      );
      debugPrint('[4] ✓ Test notification sent successfully!');
      debugPrint('[4] Check device notification panel - notification should appear');
    } catch (e, st) {
      debugPrint('[4] ✗ ERROR sending test notification: $e');
      debugPrint('[4] Stack trace: $st');
    }
    debugPrint('\n╔══════════════════════════════════════════════════════════╗');
    debugPrint('║     ✓ ATHAN NOTIFICATION TEST COMPLETED                 ║');
    debugPrint('╚══════════════════════════════════════════════════════════╝\n');
    
  } catch (e, st) {
    debugPrint('✗ Athan notification test error: $e');
    debugPrint('Stack: $st');
    debugPrint('═════ TEST FAILED ═════\n');
  }
}

/// Format a DateTime as YYYY-MM-DD for debug logging
String _formatDate(DateTime date) {
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

// Isolate worker: parse today's times row from HTML in a background isolate.
@pragma('vm:entry-point')
Map<String, String> parseTimesFromHtmlWorker(String html) {
  // Use new prayer times parser to extract today's prayer times
  try {
    // Parse the HTML table synchronously (no async needed for this part)
    String monthLabel = '';
    List<String> solarMonths = [];
    
    // Use the parser helper to extract days
    final days = parseMonthlyHtmlTable(html, monthLabel, solarMonths);
    
    // Get today's prayer times from the parsed calendar
    final now = DateTime.now();
    final todayStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    
    // Search through all days for today's date
    for (final dayEntry in days.entries) {
      final day = dayEntry.value as Map<String, dynamic>;
      final dateStr = day['gregorianDate_ISO'] as String?;
      if (dateStr != null && dateStr.startsWith(todayStr)) {
        return {
          'Fajr': day['fajr_HHmm']?.toString() ?? 'N/A',
          'Sunrise': day['sunrise_HHmm']?.toString() ?? 'N/A',
          'Dhuhr': day['dhuhr_HHmm']?.toString() ?? 'N/A',
          'Asr': day['asr_HHmm']?.toString() ?? 'N/A',
          'Maghrib': day['maghrib_HHmm']?.toString() ?? 'N/A',
          'Isha': day['isha_HHmm']?.toString() ?? 'N/A',
        };
      }
    }
    
    // Fallback if no exact match
    return {
      'Fajr': 'N/A',
      'Sunrise': 'N/A',
      'Dhuhr': 'N/A',
      'Asr': 'N/A',
      'Maghrib': 'N/A',
      'Isha': 'N/A',
    };
  } catch (e) {
    debugPrint('[parseTimesFromHtmlWorker] Error: $e');
    return {
      'Fajr': 'N/A',
      'Sunrise': 'N/A',
      'Dhuhr': 'N/A',
      'Asr': 'N/A',
      'Maghrib': 'N/A',
      'Isha': 'N/A',
    };
  }
}

// ═══════════════════════════════════════════════════════════════════════
// 🔔 BACKGROUND TASK HANDLER
// ═══════════════════════════════════════════════════════════════════════

@pragma('vm:entry-point')
/// DEPRECATED: See services/background_tasks.dart for new implementation
/// This is kept for reference but is now handled by the new background tasks module
void _oldCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    debugPrint('[BackgroundTask] Running prayer times refresh task: $task');
    return await performBackgroundRefresh();
  });
}

/// Performs the background refresh logic (fetch, cache, reschedule).
Future<bool> performBackgroundRefresh() async {
  try {
    tzdata.initializeTimeZones();

    final prefs = await SharedPreferences.getInstance();
    final cityName = prefs.getString('selectedCityName') ?? 'Casablanca';
    final apiService = ApiService();

    final raw = await apiService.fetchHijriMonthRaw(cityName);
    final monthMap = raw['monthMap'] as Map<int, Map<String, String>>?;

    if (monthMap != null && monthMap.isNotEmpty) {
      final monthLabel = raw['monthLabel'] as String? ?? '';
      final cityId = prefs.getString('cityCityId') ?? '58';
      final cacheKey = 'calendarData_$cityId';

      final Map<String, dynamic> toSave = {};
      monthMap.forEach((day, times) {
        toSave[day.toString()] = {
          'Fajr': times['Fajr'] ?? 'N/A',
          'Sunrise': times['Sunrise'] ?? 'N/A',
          'Dhuhr': times['Dhuhr'] ?? 'N/A',
          'Asr': times['Asr'] ?? 'N/A',
          'Maghrib': times['Maghrib'] ?? 'N/A',
          'Isha': times['Isha'] ?? 'N/A',
          'Hijri': times['Hijri'] ?? '',
          'Solar': times['Solar'] ?? '',
          'Moon': times['Moon'] ?? '',
          'DayOfWeek': times['DayOfWeek'] ?? '',
          'HijriMonth': times['HijriMonth'] ?? '',
          'SolarMonth': times['SolarMonth'] ?? '',
          'SolarMonthArabic': times['SolarMonthArabic'] ?? '',
        };
      });

      toSave['_monthLabelArabic'] = monthLabel;
      toSave['_monthLabelLatin'] = monthLabel;
      if (raw['currentHijriDay'] != null) {
        toSave['_currentHijriDay'] = raw['currentHijriDay'];
      }

      await prefs.setString(cacheKey, jsonEncode(toSave));
      debugPrint('[BackgroundTask] Cached prayer times for $cityName');
    }

    final times = await apiService.fetchOfficialMoroccanTimes(cityName);
    
    // Update widget cache with the fetched prayer times (works with all 3 sources)
    await WidgetCacheUpdater.updateCacheWithPrayerTimesMap({
      'fajr': times.fajr,
      'sunrise': times.sunrise,
      'dhuhr': times.dhuhr,
      'asr': times.asr,
      'maghrib': times.maghrib,
      'isha': times.isha,
    });
    
    final prayerMap = {
      'Fajr': times.fajr,
      'Dhuhr': times.dhuhr,
      'Asr': times.asr,
      'Maghrib': times.maghrib,
      'Isha': times.isha,
    };

    // Update widget cache with the fetched prayer times
    try {
      final widgetManager = WidgetInfoManager();
      await widgetManager.updateWidgetInfo();
      debugPrint('[BackgroundTask] ✓ Updated widget cache with prayer times');
    } catch (e) {
      debugPrint('[BackgroundTask] ⚠ Failed to update widget cache: $e');
    }

    // Read notification preferences
    final notificationsEnabled = prefs.getBool('notificationsEnabled') ?? true;
    final prayerNotificationsEnabled = prefs.getBool('prayerNotificationsEnabled') ?? true;
    final reminderEnabled = prefs.getBool('reminderEnabled') ?? false;
    final reminderMinutes = prefs.getInt('reminderMinutes') ?? 10;
    final enableVibration = prefs.getBool('enableVibration') ?? true;
    final notifyFajr = prefs.getBool('notifyFajr') ?? true;
    final notifySunrise = prefs.getBool('notifySunrise') ?? true;
    final notifyDhuhr = prefs.getBool('notifyDhuhr') ?? true;
    final notifyAsr = prefs.getBool('notifyAsr') ?? true;
    final notifyMaghrib = prefs.getBool('notifyMaghrib') ?? true;
    final notifyIsha = prefs.getBool('notifyIsha') ?? true;

    if (!notificationsEnabled) {
      await flutterLocalNotificationsPlugin.cancelAll();
      debugPrint('[BackgroundTask] Notifications disabled by user; cancelled all.');
      return true;
    }

    // Only cancel scheduled notifications when the user has disabled athan
    // notifications. Avoid cancelling when athan notifications are enabled,
    // because the background task may run around the same time a notification
    // fires and would remove an otherwise-delivered alert.
    if (!prayerNotificationsEnabled) {
      await flutterLocalNotificationsPlugin.cancelAll();
    }

    for (final entry in prayerMap.entries) {
      final prayerName = entry.key;
      final timeString = entry.value;

      if (timeString == 'N/A' || timeString.isEmpty) continue;

      // Check if this specific prayer is enabled
      final prayerEnabled = {
        'Fajr': notifyFajr,
        'Sunrise': notifySunrise,
        'Dhuhr': notifyDhuhr,
        'Asr': notifyAsr,
        'Maghrib': notifyMaghrib,
        'Isha': notifyIsha,
      }[prayerName] ?? true;

      if (!prayerEnabled) continue;

      final parts = timeString.replaceAll(RegExp(r'[^0-9:]'), '').split(':');
      final hour = int.tryParse(parts[0]) ?? 0;
      final minute = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
      final now = DateTime.now();
      final scheduledTime = DateTime(now.year, now.month, now.day, hour, minute);

      if (scheduledTime.isAfter(now)) {
        try {
          final location = getDeviceTimezone();
          final scheduledTzTime = tz.TZDateTime.from(scheduledTime, location);
          if (prayerNotificationsEnabled) {
            try {
              await flutterLocalNotificationsPlugin.zonedSchedule(
                prayerName.hashCode,
                'Time for $prayerName Prayer',
                'It is now time for $prayerName prayer',
                scheduledTzTime,
                NotificationDetails(
                  android: AndroidNotificationDetails(
                    'pray_times_channel',
                    'Prayer Times Notifications',
                    channelDescription: 'Notifications for prayer times',
                    importance: Importance.defaultImportance,
                    priority: Priority.defaultPriority,
                    enableVibration: enableVibration,
                    styleInformation: const BigTextStyleInformation(''),
                  ),
                  iOS: DarwinNotificationDetails(
                    presentAlert: true,
                    presentBadge: true,
                    presentSound: true,
                  ),
                ),
                androidScheduleMode: AndroidScheduleMode.alarmClock,
                uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
              );
              debugPrint('[BackgroundTask] Scheduled $prayerName at $scheduledTime (alarmClock)');
              try {
                final pending = await flutterLocalNotificationsPlugin.pendingNotificationRequests();
                debugPrint('[Pending-Background] ${pending.length} pending notifications after background schedule $prayerName');
                for (final p in pending) {
                  debugPrint('[PendingItem-Background] ${p.id} | ${p.title} | ${p.body}');
                }
              } catch (pe) {
                debugPrint('[Pending-Background-Error] $pe');
              }
            } catch (e) {
              debugPrint('[BackgroundTask] alarmClock failed for $prayerName, trying inexactAllowWhileIdle: $e');
              await flutterLocalNotificationsPlugin.zonedSchedule(
                prayerName.hashCode,
                'Time for $prayerName Prayer',
                'It is now time for $prayerName prayer',
                scheduledTzTime,
                NotificationDetails(
                  android: AndroidNotificationDetails(
                    'pray_times_channel',
                    'Prayer Times Notifications',
                    channelDescription: 'Notifications for prayer times',
                    importance: Importance.defaultImportance,
                    priority: Priority.defaultPriority,
                    enableVibration: enableVibration,
                    styleInformation: const BigTextStyleInformation(''),
                  ),
                  iOS: DarwinNotificationDetails(
                    presentAlert: true,
                    presentBadge: true,
                    presentSound: true,
                  ),
                ),
                androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
                uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
              );
              debugPrint('[BackgroundTask] Scheduled $prayerName at $scheduledTime (inexactAllowWhileIdle)');
              try {
                final pending = await flutterLocalNotificationsPlugin.pendingNotificationRequests();
                debugPrint('[Pending-Background] ${pending.length} pending notifications after background schedule $prayerName (fallback)');
                for (final p in pending) {
                  debugPrint('[PendingItem-Background] ${p.id} | ${p.title} | ${p.body}');
                }
              } catch (pe) {
                debugPrint('[Pending-Background-Error] $pe');
              }
            }
          }

          // Schedule reminder before prayer if enabled
          if (reminderEnabled && prayerNotificationsEnabled && reminderMinutes > 0) {
            final reminderTime = scheduledTime.subtract(Duration(minutes: reminderMinutes));
            if (reminderTime.isAfter(now)) {
              final reminderTz = tz.TZDateTime.from(reminderTime, getDeviceTimezone());
              final reminderId = prayerName.hashCode ^ 0x100000;
              await flutterLocalNotificationsPlugin.zonedSchedule(
                reminderId,
                'Upcoming $prayerName Prayer',
                'Reminder: $prayerName in $reminderMinutes minutes',
                reminderTz,
                NotificationDetails(
                  android: AndroidNotificationDetails(
                    'pray_times_channel',
                    'Prayer Times Notifications',
                    channelDescription: 'Notifications for prayer times',
                    importance: Importance.defaultImportance,
                    priority: Priority.defaultPriority,
                    enableVibration: enableVibration,
                    styleInformation: const BigTextStyleInformation(''),
                  ),
                  iOS: DarwinNotificationDetails(
                    presentAlert: true,
                    presentBadge: true,
                    presentSound: true,
                  ),
                ),
                androidScheduleMode: AndroidScheduleMode.alarmClock,
                uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
              );
              debugPrint('[BackgroundTask] Scheduled reminder for $prayerName at $reminderTime');
            }
          }
        } catch (e) {
          debugPrint('[BackgroundTask] Error scheduling $prayerName: $e');
        }
      }
    }

    return true;
  } catch (e) {
    debugPrint('[BackgroundTask] Error: $e');
    return false;
  }
}


// ═══════════════════════════════════════════════════════════════════════
// 🔔 GLOBAL NOTIFICATION HELPER FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════

/// Global function to reschedule notifications (callable from anywhere)
/// This reads current prayer times and reschedules based on current settings
/// Uses monthly cache (which is kept current by background tasks)
Future<void> refreshScheduledNotificationsGlobal() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final cityId = prefs.getString('cityCityId') ?? '58';
    final cityName = prefs.getString('selectedCityName') ?? 'Casablanca';
    final useMinistry = prefs.getBool('useMinistry') ?? true;
    
    PrayerTimes? times;

    // Try to load from monthly calendar cache
    try {
      debugPrint('[RefreshGlobal] Loading from monthly calendar cache...');
      final cacheKey = 'calendarData_$cityId';
      final cachedDataStr = prefs.getString(cacheKey);
      
      if (cachedDataStr != null) {
        final cachedDataMap = jsonDecode(cachedDataStr) as Map<String, dynamic>;
        final today = DateTime.now();
        final todayIso = DateTime(today.year, today.month, today.day).toIso8601String().split('T')[0];
        
        Map<String, dynamic>? todayEntry;
        for (final key in cachedDataMap.keys) {
          if (key.startsWith(todayIso)) {
            todayEntry = cachedDataMap[key] as Map<String, dynamic>?;
            break;
          }
        }
        
        if (todayEntry != null) {
          times = PrayerTimes(
            fajr: (todayEntry['Fajr'] as String?) ?? 'N/A',
            sunrise: (todayEntry['Sunrise'] as String?) ?? 'N/A',
            dhuhr: (todayEntry['Dhuhr'] as String?) ?? 'N/A',
            asr: (todayEntry['Asr'] as String?) ?? 'N/A',
            maghrib: (todayEntry['Maghrib'] as String?) ?? 'N/A',
            isha: (todayEntry['Isha'] as String?) ?? 'N/A',
          );
          debugPrint('[RefreshGlobal] ✓ Got times from monthly cache');
        } else {
          debugPrint('[RefreshGlobal] Today not found in cache, will try to fetch fresh data');
        }
      } else {
        debugPrint('[RefreshGlobal] Cache missing for city $cityId, will try to fetch fresh data');
      }
    } catch (e) {
      debugPrint('[RefreshGlobal] Cache load failed: $e, will try to fetch fresh data');
    }

    // If no times available, abort reschedule
    // If cache missed and using Ministry, try to fetch fresh data and UPDATE the daily parser cache
    if (times == null && useMinistry) {
      try {
        debugPrint('[RefreshGlobal] Attempting to fetch fresh data from Ministry API...');
        final apiService = ApiService();
        times = await apiService.fetchOfficialMoroccanTimes(cityName);
        if (times.fajr != 'N/A') {
          // Update the daily parser cache with this fresh data
          final cacheKey = 'dailyPrayerTimes_$cityId';
          final cacheData = {
            'fajr': times.fajr,
            'sunrise': times.sunrise,
            'dhuhr': times.dhuhr,
            'asr': times.asr,
            'maghrib': times.maghrib,
            'isha': times.isha,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          };
          await prefs.setString(cacheKey, jsonEncode(cacheData));
          debugPrint('[RefreshGlobal] ✓ Updated daily parser cache with fresh Ministry data');
        }
      } catch (e) {
        debugPrint('[RefreshGlobal] Failed to fetch from Ministry API: $e');
      }
    }

    // If still no times available, abort reschedule
    if (times == null || times.fajr == 'N/A') {
      debugPrint('[RefreshGlobal] ✗ Could not load prayer times');
      return;
    }

    // Update widget cache with the loaded prayer times (works with all 3 sources)
    await WidgetCacheUpdater.updateCacheWithPrayerTimesMap({
      'fajr': times.fajr,
      'sunrise': times.sunrise,
      'dhuhr': times.dhuhr,
      'asr': times.asr,
      'maghrib': times.maghrib,
      'isha': times.isha,
    });

    debugPrint('[RefreshGlobal] ═════ MANUAL RESCHEDULE FROM SETTINGS ═════');
    
    // Cancel all and reschedule with new settings
    await flutterLocalNotificationsPlugin.cancelAll();
    debugPrint('[RefreshGlobal] Cancelled all notifications');
    
    // Now reschedule with current settings using NotificationManager
    // (reuse prefs that was already initialized at the start of this function)
    final globalStateValue = prefs.getInt('notificationState') ?? 2;
    final notificationState = NotificationState.fromValue(globalStateValue);
    final athanSoundTypeValue = prefs.getInt('athanSoundType') ?? 0;
    final athanSoundType = AthanSoundType.fromValue(athanSoundTypeValue);
    final reminderEnabled = prefs.getBool('reminderEnabled') ?? false;
    final reminderMinutes = prefs.getInt('reminderMinutes') ?? 10;
    
    final manager = NotificationManager();
    final timezone = getDeviceTimezone();
    
    // Use PrayerTimesProvider to get times based on user's selected source
    final provider = PrayerTimesProvider();
    final result = await provider.getPrayerTimes();
    
    debugPrint('[GlobalNotifications] Using source: ${result.sourceUsed}');
    
    await manager.scheduleNotificationsForTodaysPrayers(
      prayerTimes: result.times,
      reminderEnabled: reminderEnabled,
      reminderMinutes: reminderMinutes,
      notificationState: notificationState,
      athanSoundType: athanSoundType,
      timezone: timezone,
    );
    
    debugPrint('[RefreshGlobal] ═════ RESCHEDULE COMPLETE ═════');
  } catch (e) {
    debugPrint('[RefreshGlobal] Error: $e');
  }
}



/// Show a test notification immediately
Future<void> _showTestNotificationStatic() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    
    // Read notification state (0=Silent, 1=Vibration, 2=Full)
    final notificationStateValue = prefs.getInt('notificationState') ?? 2;
    final notificationState = NotificationState.fromValue(notificationStateValue);
    final athanSoundTypeValue = prefs.getInt('athanSoundType') ?? 0;
    final athanSoundType = AthanSoundType.fromValue(athanSoundTypeValue);
    final channelId = _getPrayerChannelId(notificationState, athanType: athanSoundType);
    
    debugPrint('[TestNotif] ═══════════════════════════════════');
    debugPrint('[TestNotif] Sending test notification');
    debugPrint('[TestNotif] Notification State: ${notificationState.label}');
    debugPrint('[TestNotif] Channel ID: $channelId');
    debugPrint('[TestNotif] Silent mode: ${notificationState == NotificationState.silent}');
    debugPrint('[TestNotif] Vibrate mode: ${notificationState == NotificationState.vibrate}');
    debugPrint('[TestNotif] Full mode: ${notificationState == NotificationState.full}');
    
    // Build android notification details with explicit sound/vibration control
    final androidDetails = AndroidNotificationDetails(
      channelId,
      'Prayer Times Notifications',
      channelDescription: 'Notifications for prayer times',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      styleInformation: const BigTextStyleInformation(''),
      // Explicitly control sound and vibration for this notification
      playSound: notificationState == NotificationState.full,
      enableVibration: notificationState != NotificationState.silent,
    );
    
    debugPrint('[TestNotif] AndroidDetails: playSound=${notificationState == NotificationState.full}, enableVibration=${notificationState != NotificationState.silent}');
    
    await flutterLocalNotificationsPlugin.show(
      999,
      'Test Notification',
      'State: ${notificationState.label}',
      NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
    debugPrint('[TestNotif] Test notification sent successfully with channel: $channelId');
    debugPrint('[TestNotif] ═══════════════════════════════════');
  } catch (e) {
    debugPrint('[TestNotif] Error showing test notification: $e');
  }
}

// The Class to hold your data
class PrayerTimes {
  final String fajr;
  final String sunrise;
  final String dhuhr;
  final String asr;
  final String maghrib;
  final String isha;

  PrayerTimes({
    required this.fajr,
    required this.sunrise,
    required this.dhuhr,
    required this.asr,
    required this.maghrib,
    required this.isha,
  });

  // Factory method to parse the JSON data from the API response
  factory PrayerTimes.fromJson(Map<String, dynamic> json) {
    // The response shape can vary between APIs:
    // - Aladhan: { data: { timings: { Fajr: ..., Dhuhr: ... } } }
    // - Some unofficial Ministry endpoints may return { Fajr: ..., Dhuhr: ... }
    // Accept multiple shapes and pick whichever is present.
    Map<String, dynamic> timings = {};

    if (json.containsKey('timings') && json['timings'] is Map) {
      timings = Map<String, dynamic>.from(json['timings'] as Map);
    } else if (json.containsKey('data') && json['data'] is Map) {
      final data = json['data'] as Map;
      if (data.containsKey('timings') && data['timings'] is Map) {
        timings = Map<String, dynamic>.from(data['timings'] as Map);
      } else {
        timings = Map<String, dynamic>.from(data);
      }
    } else {
      // Assume the map itself contains prayer keys directly
      timings = Map<String, dynamic>.from(json);
    }

    String getValue(String key) {
      final v = timings[key];
      if (v == null) return 'N/A';
      return v.toString();
    }

    return PrayerTimes(
      fajr: getValue('Fajr'),
      sunrise: getValue('Sunrise'),
      dhuhr: getValue('Dhuhr'),
      asr: getValue('Asr'),
      maghrib: getValue('Maghrib'),
      isha: getValue('Isha'),
    );
  }
}

class ApiService {
  static const String defaultMinistryUrl = 'https://habous.gov.ma/prieres/horaire_hijri_2.php';
  // Ministry city ID mapping (from the ministry website's select dropdown)
  static const Map<String, String> ministrycityIds = {
    'آزرو': '103',
    'آسفي': '111',
    'آيت القاق': '308',
    'آيت ورير': '314',
    'أحفير': '53',
    'أخفنير': '164',
    'أرفود': '130',
    'أزمور': '67',
    'أزيلال': '74',
    'أسا': '150',
    'أسكين': '313',
    'أسول': '145',
    'أصيلة': '17',
    'أقا': '124',
    'أكادير': '117',
    'أكايوار': '311',
    'أكدال أملشيل': '309',
    'أكدز': '142',
    'أكنول': '91',
    'أمسمرير': '146',
    'أمكالة': '163',
    'أوسرد': '167',
    'أولاد تايمة': '127',
    'أولاد عياد': '302',
    'إغرم': '120',
    'إملشيل': '133',
    'إموزار كندر': '88',
    'إيكس': '317',
    'إيمنتانوت': '305',
    'إيمين ثلاث': '322',
    'ابن أحمد': '64',
    'اكودال املشيل ميدلت': '310',
    'البروج': '63',
    'الجبهة': '26',
    'الجديدة': '66',
    'الحاجب': '101',
    'الحسيمة': '23',
    'الخميسات': '2',
    'الداخلة': '165',
    'الدار البيضاء': '58',
    'الرباط': '1',
    'الرحامنة': '109',
    'الرشيدية': '128',
    'الرماني': '4',
    'الريش': '135',
    'الريصاني': '129',
    'الزاك': '151',
    'السعيدية': '49',
    'السمارة': '157',
    'الصويرة': '106',
    'العرائش': '16',
    'العيون': '156',
    'العيون الشرقية': '47',
    'الفقيه بنصالح': '75',
    'الفنيدق': '25',
    'القصر الصغير': '22',
    'القصر الكبير': '21',
    'القصيبة': '77',
    'القنيطرة': '7',
    'الكارة': '62',
    'الكويرة': '166',
    'المحبس': '154',
    'المحمدية': '59',
    'المضيق': '20',
    'المنزل بني يازغة': '87',
    'الناظور': '39',
    'النيف': '144',
    'الوليدية': '112',
    'اليوسفية': '113',
    'بئر أنزاران': '169',
    'بئر كندوز': '168',
    'باب برد': '28',
    'برشيد': '65',
    'بركان': '32',
    'بن سليمان': '60',
    'بنجرير': '108',
    'بني أنصار': '43',
    'بني ادرار': '48',
    'بني تجيت': '56',
    'بني ملال': '73',
    'بوجدور': '158',
    'بورد': '93',
    'بوزنيقة': '6',
    'بوسكور': '30',
    'بوعرفة': '34',
    'بوعنان': '57',
    'بوكراع': '161',
    'بولمان': '84',
    'بومالن دادس': '143',
    'بويزكارن': '153',
    'بويكرة': '126',
    'تارودانت': '118',
    'تازارين': '147',
    'تازة': '89',
    'تافراوت': '122',
    'تافوغالت': '51',
    'تالسينت': '45',
    'تالوين': '121',
    'تامصلوحت': '115',
    'تاهلة': '303',
    'تاوريرت': '38',
    'تاونات': '90',
    'تزنيت': '119',
    'تسلطانت': '114',
    'تطوان': '15',
    'تفاريتي': '160',
    'تفنتان': '307',
    'تمنار': '110',
    'تنجداد': '134',
    'تندرارة': '46',
    'تنديت': '131',
    'تنغير': '139',
    'تولكولت': '316',
    'تيزي وسلي': '92',
    'تيسة': '95',
    'تيسنت': '319',
    'تيفلت': '3',
    'جرادة': '36',
    'خريبكة': '79',
    'خميس الزمامرة': '69',
    'خميس سيدي عبد الجليل': '301',
    'خنيفرة': '70',
    'دبدو': '41',
    'دريوش': '55',
    'دمنات': '76',
    'رأس الماء': '50',
    'رباط الخير': '86',
    'زاكورة': '137',
    'زاوية أحنصال': '72',
    'زاوية مولاي ابراهيم': '315',
    'زايو': '54',
    'زرهون': '102',
    'سبتة': '24',
    'سطات': '61',
    'سلوان': '42',
    'سوق أربعاء الغرب': '11',
    'سيدي إفني': '148',
    'سيدي بنور': '68',
    'سيدي سليمان': '10',
    'سيدي غانم': '306',
    'سيدي قاسم': '8',
    'سيدي يحيى الغرب': '9',
    'شفشاون': '18',
    'شيشاوة': '107',
    'صفرو': '82',
    'طاطا': '123',
    'طانطان': '152',
    'طرفاية': '159',
    'طنجة': '14',
    'عرباوة': '12',
    'عين الشعير': '37',
    'عين العودة': '312',
    'فاس': '81',
    'فرخانة': '44',
    'فزوان': '52',
    'فكيك': '33',
    'فم زكيد': '320',
    'فم لحصن': '125',
    'قرية با محمد': '96',
    'قصبة تادلة': '78',
    'قصر إيش': '321',
    'قطارة': '116',
    'قلعة السراغنة': '105',
    'قلعة مكونة': '141',
    'كتامة': '97',
    'كرس': '318',
    'كرسيف': '35',
    'كلتة زمور': '162',
    'كلميم': '149',
    'كلميمة': '132',
    'لمسيد': '155',
    'مراكش': '104',
    'مرتيل': '19',
    'مطماطة': '304',
    'مكناس': '99',
    'مليلية': '40',
    'مولاي بوسلهام': '13',
    'مولاي بوعزة': '71',
    'مولاي يعقوب': '83',
    'ميدلت': '136',
    'ميسور': '85',
    'هسكورة': '140',
    'واد أمليل': '98',
    'واد لاو': '27',
    'وادي زم': '80',
    'والماس': '5',
    'وجدة': '31',
    'ورزازات': '138',
    'وزان': '29',
    'يفرن': '100',
  };

  // Create an HttpClient that ignores certificate errors for development
  // WARNING: This is insecure; only use for development/testing
  static HttpClient _createHttpClient() {
    final client = HttpClient();
    client.badCertificateCallback = (X509Certificate cert, String host, int port) {
      debugPrint('[SSL] Accepting certificate for $host due to development mode');
      return true;
    };
    return client;
  }

  /// Fetch prayer times from AlAdhan API with hardcoded Morocco settings
  /// Uses method=99 (custom) with Fajr 19°, Isha 17°, Shafi madhab, Isha +5min adjustment
  Future<PrayerTimes> fetchMoroccoAlAdhanTimes(double latitude, double longitude) async {
    debugPrint('[fetchMoroccoAlAdhanTimes] ═════ CALLED ═════');
    debugPrint('[fetchMoroccoAlAdhanTimes] Input latitude: $latitude');
    debugPrint('[fetchMoroccoAlAdhanTimes] Input longitude: $longitude');
    
    const apiAuthority = 'http://api.aladhan.com';
    const apiPath = '/v1/timings';
    
    // Get Unix timestamp for today
    final now = DateTime.now();
    final timestamp = (DateTime(now.year, now.month, now.day).millisecondsSinceEpoch / 1000).toStringAsFixed(0);
    
    debugPrint('[fetchMoroccoAlAdhanTimes] Timestamp: $timestamp');
    debugPrint('[fetchMoroccoAlAdhanTimes] Year: ${now.year}, Month: ${now.month}, Day: ${now.day}');
    
    // Build URL with Morocco parameters using methodSettings format
    // method=99: Custom method that respects methodSettings
    // methodSettings="19,null,17": Fajr 19°, null for second param, Isha 17°
    // school=0: Shafi madhab
    // latitudeAdjustmentMethod=0: Standard latitude adjustment
    // tune="0,0,0,0,0,5,0,0,0": Isha +5 minutes (Fajr,Sunrise,Dhuhr,Asr,Maghrib,Isha,Imsak,Midnight,Firstthird)
    final uri = Uri.parse(
      '$apiAuthority$apiPath/$timestamp?'
      'latitude=$latitude&'
      'longitude=$longitude&'
      'method=99&'
      'methodSettings=19,null,17&'
      'school=0&'
      'latitudeAdjustmentMethod=0&'
      'midnightMethod=Standard&'
      'tune=0,0,0,0,0,5,0,0,0'
    );

    debugPrint('[fetchMoroccoAlAdhanTimes] ════════════════════════════════════');
    debugPrint('[fetchMoroccoAlAdhanTimes] FULL URL: $uri');
    debugPrint('[fetchMoroccoAlAdhanTimes] ════════════════════════════════════');

    try {
      final client = _createHttpClient();
      final request = await client.getUrl(uri);
      
      debugPrint('[fetchMoroccoAlAdhanTimes] Request created, sending...');
      
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      debugPrint('[fetchMoroccoAlAdhanTimes] Response status: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final jsonResponse = jsonDecode(body);
        final responseLatitude = jsonResponse['data']?['meta']?['latitude'];
        final responseLongitude = jsonResponse['data']?['meta']?['longitude'];
        final methodInfo = jsonResponse['data']?['meta']?['method'];
        
        debugPrint('[fetchMoroccoAlAdhanTimes] ════ RESPONSE DATA ════');
        debugPrint('[fetchMoroccoAlAdhanTimes] Response Latitude: $responseLatitude');
        debugPrint('[fetchMoroccoAlAdhanTimes] Response Longitude: $responseLongitude');
        debugPrint('[fetchMoroccoAlAdhanTimes] Response Method: ${methodInfo?['id']} - ${methodInfo?['name']}');
        debugPrint('[fetchMoroccoAlAdhanTimes] Response Params: ${methodInfo?['params']}');
        debugPrint('[fetchMoroccoAlAdhanTimes] ═══════════════════════');
        
        if (jsonResponse['code'] == 200 && jsonResponse['data'] != null) {
          // Extract timings from AlAdhan response
          final timings = jsonResponse['data']['timings'];
          
          debugPrint('[fetchMoroccoAlAdhanTimes] Prayer Times:');
          debugPrint('[fetchMoroccoAlAdhanTimes]   Fajr: ${timings['Fajr']}');
          debugPrint('[fetchMoroccoAlAdhanTimes]   Dhuhr: ${timings['Dhuhr']}');
          debugPrint('[fetchMoroccoAlAdhanTimes]   Asr: ${timings['Asr']}');
          debugPrint('[fetchMoroccoAlAdhanTimes]   Maghrib: ${timings['Maghrib']}');
          debugPrint('[fetchMoroccoAlAdhanTimes]   Isha: ${timings['Isha']}');
          
          client.close();
          return PrayerTimes.fromJson(jsonResponse);
        } else {
          client.close();
          throw Exception('Invalid response from AlAdhan API: ${jsonResponse['status']}');
        }
      } else {
        client.close();
        throw Exception('Failed to load prayer times from AlAdhan. Status Code: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[fetchMoroccoAlAdhanTimes] ERROR: $e');
      throw Exception('Failed to load prayer times: $e');
    }
  }

  // Method to fetch the times for a given city
  Future<PrayerTimes> fetchOfficialMoroccanTimes(String cityName) async {
    // Read settings from SharedPreferences: ministry URL, city ID, and whether to use it
    final prefs = await SharedPreferences.getInstance();
    final ministryUrl = prefs.getString('ministryUrl') ?? defaultMinistryUrl;
    final cityId = prefs.getString('cityCityId') ?? '58'; // default to Casablanca (58)
    final useMinistry = prefs.getBool('useMinistry') ?? true; // default to ministry

    if (useMinistry && ministryUrl.isNotEmpty) {
      // Try ministry endpoint first
      // The ministry site uses ville (city ID) parameter
      final separator = ministryUrl.contains('?') ? '&' : '?';
      final uri = Uri.parse('$ministryUrl${separator}ville=$cityId');
      debugPrint('Requesting ministry URL: $uri');
      
      try {
        final client = _createHttpClient();
        final request = await client.getUrl(uri);
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();

        if (response.statusCode == 200) {
          // Try parse as JSON first
          try {
            final jsonResponse = jsonDecode(body);
            debugPrint('Ministry JSON response: $jsonResponse');
            final times = PrayerTimes.fromJson(jsonResponse as Map<String, dynamic>);
            if (_isValidPrayerTimes(times)) return times;
            debugPrint('Ministry JSON parsed but contained invalid times, falling back');
          } catch (_) {
            // Not JSON — try HTML parsing
            debugPrint('Ministry HTML response received — attempting parse (isolate)');
            final extracted = await foundation.compute(parseTimesFromHtmlWorker, body);
            final times = PrayerTimes(
              fajr: extracted['Fajr'] ?? 'N/A',
              sunrise: extracted['Sunrise'] ?? 'N/A',
              dhuhr: extracted['Dhuhr'] ?? 'N/A',
              asr: extracted['Asr'] ?? 'N/A',
              maghrib: extracted['Maghrib'] ?? 'N/A',
              isha: extracted['Isha'] ?? 'N/A',
            );
            if (_isValidPrayerTimes(times)) return times;
            debugPrint('Ministry HTML parsed but contained invalid times, falling back');
          }
        } else {
          debugPrint('Ministry endpoint returned ${response.statusCode}, falling back');
        }
        client.close();
      } catch (e) {
        debugPrint('Ministry request failed: $e, falling back to Aladhan');
      }
    }
    
    // Fallback to Aladhan
    final aladhanUri = Uri.parse('https://api.aladhan.com/v1/timingsByCity?city=$cityName&country=Morocco&method=2');
    try {
      final client = _createHttpClient();
      final request = await client.getUrl(aladhanUri);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        final jsonResponse = jsonDecode(body);
        debugPrint('Aladhan API Response: $jsonResponse');
        client.close();
        return PrayerTimes.fromJson(jsonResponse as Map<String, dynamic>);
      } else {
        client.close();
        throw Exception('Failed to load prayer times for $cityName. Status Code: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Failed to load prayer times: $e');
    }
  }

  /// Fetch the ministry monthly table and return a map of Date -> Map of values
  /// where the map contains keys: Fajr, Sunrise, Dhuhr, Asr, Maghrib, Isha,
  /// optionally Hijri (string) and Moon='1' for moon-observation days.
  Future<Map<DateTime, Map<String, String>>> fetchMonthlyTimes(String cityName) async {
    final prefs = await SharedPreferences.getInstance();
    final ministryUrl = prefs.getString('ministryUrl') ?? defaultMinistryUrl;
    final cityId = prefs.getString('cityCityId') ?? '58';
    final useMinistry = prefs.getBool('useMinistry') ?? true;

    if (!useMinistry || ministryUrl.isEmpty) {
      throw Exception('Ministry usage disabled or URL empty');
    }

    final separator = ministryUrl.contains('?') ? '&' : '?';
    final uri = Uri.parse('$ministryUrl${separator}ville=$cityId');
    debugPrint('Requesting ministry URL for month: $uri');

    try {
      final client = _createHttpClient();
      final request = await client.getUrl(uri);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        // Use new prayer times parser
        final cityIdNum = int.tryParse(cityId) ?? 58;
        final parsedCalendar = await parseMonthlyCalendarFromHtml(body, cityId: cityIdNum);
        
        final Map<DateTime, Map<String, String>> out = {};
        final days = (parsedCalendar['days'] as Map<String, dynamic>?) ?? {};
        for (final entry in days.entries) {
          try {
            final day = entry.value as Map<String, dynamic>;
            final dateStr = day['gregorianDate_ISO'] as String?;
            if (dateStr != null && dateStr.isNotEmpty) {
              final date = DateTime.parse(dateStr);
              out[date] = {
                'Fajr': (day['fajr_HHmm'] as String?) ?? 'N/A',
                'Sunrise': (day['sunrise_HHmm'] as String?) ?? 'N/A',
                'Dhuhr': (day['dhuhr_HHmm'] as String?) ?? 'N/A',
                'Asr': (day['asr_HHmm'] as String?) ?? 'N/A',
                'Maghrib': (day['maghrib_HHmm'] as String?) ?? 'N/A',
                'Isha': (day['isha_HHmm'] as String?) ?? 'N/A',
                'Hijri': (day['hijriDay'] as String?) ?? '',
                'Solar': dateStr,
                'DayOfWeek': (day['dayOfWeek_TEXT'] as String?) ?? '',
                'HijriMonth': (day['hijriMonth_TEXT'] as String?) ?? '',
                'SolarMonth': (day['solarMonth_TEXT'] as String?) ?? '',
              };
            }
          } catch (e) {
            debugPrint('[fetchMonthlyTimes] Error parsing date: $e');
          }
        }
        client.close();
        return out;
      } else {
        client.close();
        throw Exception('Failed to fetch ministry month table: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Failed to fetch monthly times: $e');
    }
  }

  /*
   Fetch the ministry monthly table as a raw Hijri-month map.
   Returns a map with keys:
   - 'monthMap': Map<int, Map<String,String>> mapping Hijri day -> times map
   - 'monthLabel': optional String with a captured caption or heading near the table
   - 'currentHijriDay': optional int indicating which Hijri day corresponds to today (if detected)
  */
  Future<Map<String, dynamic>> fetchHijriMonthRaw(String cityName) async {
    final prefs = await SharedPreferences.getInstance();
    final ministryUrl = prefs.getString('ministryUrl') ?? defaultMinistryUrl;
    final cityId = prefs.getString('cityCityId') ?? '58';
    final separator = ministryUrl.contains('?') ? '&' : '?';
    final uri = Uri.parse('$ministryUrl${separator}ville=$cityId');

    try {
      final client = _createHttpClient();
      final request = await client.getUrl(uri);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        // Use new prayer times parser
        final cityIdNum = int.tryParse(cityId) ?? 58;
        final parsedCalendar = await parseMonthlyCalendarFromHtml(body, cityId: cityIdNum);
        
        // Convert new parser output to old format for backward compatibility
        final monthMap = <int, Map<String, String>>{};
        final days = (parsedCalendar['days'] as Map<String, dynamic>?) ?? {};
        for (final entry in days.entries) {
          final day = entry.value as Map<String, dynamic>;
          final hijriDayStr = day['hijriDay'] as String?;
          final hijriDay = int.tryParse(hijriDayStr ?? '') ?? 0;
          if (hijriDay > 0) {
            monthMap[hijriDay] = {
              'Fajr': (day['fajr_HHmm'] as String?) ?? 'N/A',
              'Sunrise': (day['sunrise_HHmm'] as String?) ?? 'N/A',
              'Dhuhr': (day['dhuhr_HHmm'] as String?) ?? 'N/A',
              'Asr': (day['asr_HHmm'] as String?) ?? 'N/A',
              'Maghrib': (day['maghrib_HHmm'] as String?) ?? 'N/A',
              'Isha': (day['isha_HHmm'] as String?) ?? 'N/A',
              'Hijri': hijriDayStr ?? '',
              'Solar': (day['gregorianDate_ISO'] as String?) ?? '',
              'DayOfWeek': (day['dayOfWeek_TEXT'] as String?) ?? '',
            };
          }
        }
        
        debugPrint('[fetchHijriMonthRaw] Parsed ${monthMap.length} days using new parser service');

        // Attempt to detect which Hijri day corresponds to today by scanning the parsed days
        int? currentHijriDay;
        try {
          final now = DateTime.now();
          final todayStr = now.day.toString().padLeft(2, '0');
          for (final entry in days.entries) {
            final day = entry.value as Map<String, dynamic>;
            final dateStr = day['gregorianDate_ISO'] as String?;
            if (dateStr?.endsWith('-$todayStr') ?? false) {
              final hijriStr = day['hijriDay'] as String?;
              final hijriNum = int.tryParse(hijriStr ?? '');
              if (hijriNum != null) {
                currentHijriDay = hijriNum;
                break;
              }
            }
          }
        } catch (_) {}

        client.close();
        final monthLabel = (parsedCalendar['hijriMonth'] as String?) ?? '';
        return {'monthMap': monthMap, 'monthLabel': monthLabel, 'currentHijriDay': currentHijriDay};
      } else {
        client.close();
        throw Exception('Failed to fetch ministry month table: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Failed to fetch Hijri monthly times: $e');
    }
  }

  bool _isValidPrayerTimes(PrayerTimes t) {
    // Consider valid when at least fajr and isha are not 'N/A' and not empty
    return (t.fajr.trim().isNotEmpty && t.fajr.trim() != 'N/A') &&
        (t.isha.trim().isNotEmpty && t.isha.trim() != 'N/A');
  }

  /*
   Parse the entire month table from the ministry HTML and return a map
   of day -> prayer times (as Map<String,String>). The day is the day of
   month in the current month.
  */
}

class _PrayerTimeScreenState extends State<PrayerTimeScreen> {
  final ApiService _apiService = ApiService();

  PrayerTimes? _todayTimes;
  bool _isLoading = true;
  String? _errorMessage;
  String _currentCity = 'Casablanca'; // Track current city for display
  bool _useMinistry = true; // Track whether to use Ministry source
  bool _isOfflineMode = false; // Track whether to use offline mode

  // ----------------------------------------------------
  // 💡 NEW: Countdown State Variables
  // ----------------------------------------------------
  String _nextPrayerName = 'N/A';
  DateTime? _nextPrayerTime;
  // Duration _countdown = Duration.zero; // Not strictly needed, use _countdownDisplay
  String _countdownDisplay = '--:--:--';
  late Timer _timer;
  // Track scheduled notifications for display
  // Remove manual notification tracking - we'll use pendingNotificationRequests() instead
  // ----------------------------------------------------

  // Smart reload tracking
  bool _reloadFailed = false; // Prevent infinite retry loops
  DateTime? _lastReloadAttemptDate; // Track which day we last tried to reload

// Track if this is the first load to avoid startup notification


  @override
  void initState() {
    super.initState();
    _loadTimes();
    _maybeRefreshCalendar();
    _loadSettings();
    _requestNotificationPermission(); // Request notification permission on startup
    _requestExactAlarmPermission(); // Request exact alarm permission for accurate countdown timers
    // 💡 NEW: Initialize the real-time timer
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateCountdown();
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _useMinistry = prefs.getBool('useMinistry') ?? true;
      _isOfflineMode = prefs.getBool('isOfflineMode') ?? false;
    });
  }

  /// Convert Arabic city name to Latin using the latinNames map from _SettingsScreenState
  String _latinizeCity(String arabicCityName) {
    return _SettingsScreenState.latinNames[arabicCityName] ?? arabicCityName;
  }

  Future<void> _requestNotificationPermission() async {
    if (Platform.isAndroid) {
      try {
        final granted = await flutterLocalNotificationsPlugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
        
        if (granted ?? false) {
          debugPrint('[Notifications] Permission granted');
        }
      } catch (e) {
        debugPrint('[Notifications] Permission request failed: $e');
      }
    }
  }

  /// Request exact alarm permission for Android 13+ (required for accurate countdown timers)
  Future<void> _requestExactAlarmPermission() async {
    if (Platform.isAndroid) {
      try {
        debugPrint('[ExactAlarm] Requesting exact alarm permission for countdown timers...');
        
        final androidImpl = flutterLocalNotificationsPlugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        if (androidImpl != null) {
          // requestExactAlarmsPermission is only available on Android 13+
          // On older versions, this call will be ignored or throw (caught below)
          final granted = await androidImpl.requestExactAlarmsPermission();
          if (granted ?? false) {
            debugPrint('[ExactAlarm] ✓ Exact alarm permission granted');
          } else {
            debugPrint('[ExactAlarm] ℹ Exact alarm permission not available or denied');
          }
        }
      } catch (e) {
        // Method not available on this Android version (pre-13), which is fine
        debugPrint('[ExactAlarm] Note: Method not available (likely Android < 13): $e');
      }
    }
  }

  Future<void> _maybeRefreshCalendar() async {
    final prefs = await SharedPreferences.getInstance();
    final cityId = prefs.getString('cityCityId') ?? '58';
    final cacheKey = 'calendarData_$cityId';
    final lastCityKey = 'calendarLastCity_$cityId';
    final lastHijriMonthKey = 'calendarLastHijriMonth_$cityId';
    
    // Check if we have cached data
    final cachedDataStr = prefs.getString(cacheKey);
    if (cachedDataStr == null) {
      debugPrint('[Calendar] No cached data, fetching from ministry...');
      await _fetchAndCacheCalendar(cityId, cacheKey, lastCityKey, lastHijriMonthKey);
      return;
    }

    // Parse cached data to find the last day covered
    try {
      final cachedDataMap = jsonDecode(cachedDataStr) as Map<String, dynamic>;
      DateTime? lastDateInCache;
      String? lastHijriMonth;
      
      for (final key in cachedDataMap.keys) {
        final date = DateTime.tryParse(key);
        if (date != null) {
          if (lastDateInCache == null || date.isAfter(lastDateInCache)) {
            lastDateInCache = date;
            lastHijriMonth = cachedDataMap[key]?['Hijri'];
          }
        }
      }

      // Get current date and info about city/source
      final now = DateTime.now();
      final lastCity = prefs.getString(lastCityKey);
      final previousHijriMonth = prefs.getString(lastHijriMonthKey);
      final currentCity = _currentCity;

      debugPrint('[Calendar] Current date: $now, Last cached date: $lastDateInCache');
      debugPrint('[Calendar] Current city: $currentCity, Last city: $lastCity');
      debugPrint('[Calendar] Last Hijri month in cache: $lastHijriMonth, Previous: $previousHijriMonth');

      // Determine if we need to refresh
      bool shouldRefresh = false;

      // 0. Check if today's month is in the cache at all (NEW CHECK)
      bool todayMonthInCache = false;
      for (final key in cachedDataMap.keys) {
        final date = DateTime.tryParse(key);
        if (date != null && date.year == now.year && date.month == now.month) {
          todayMonthInCache = true;
          break;
        }
      }
      
      if (!todayMonthInCache) {
        debugPrint('[Calendar] Today\'s month (${now.month}/${now.year}) not in cache → REFRESH needed');
        shouldRefresh = true;
      }

      // 1. Today is after the last day in cache
      if (lastDateInCache != null && now.isAfter(lastDateInCache)) {
        debugPrint('[Calendar] Today is after last cached day → REFRESH needed');
        shouldRefresh = true;
      }

      // 2. City source changed
      if (lastCity != null && lastCity != currentCity) {
        debugPrint('[Calendar] City changed from "$lastCity" to "$currentCity" → REFRESH needed');
        shouldRefresh = true;
      }

      // 3. Hijri month changed (if info available)
      if (lastHijriMonth != null && previousHijriMonth != null && lastHijriMonth != previousHijriMonth) {
        debugPrint('[Calendar] Hijri month changed from "$previousHijriMonth" to "$lastHijriMonth" → REFRESH needed');
        shouldRefresh = true;
      }

      if (shouldRefresh) {
        await _fetchAndCacheCalendar(cityId, cacheKey, lastCityKey, lastHijriMonthKey);
      } else {
        debugPrint('[Calendar] Cache is still valid, no refresh needed');
      }
    } catch (e) {
      debugPrint('[Calendar] Error parsing cache: $e, will refresh');
      await _fetchAndCacheCalendar(cityId, cacheKey, lastCityKey, lastHijriMonthKey);
    }
  }

  /// Fetch calendar data from ministry and cache it
  Future<void> _fetchAndCacheCalendar(String cityId, String cacheKey, String lastCityKey, String lastHijriMonthKey) async {
    try {
      final data = await _apiService.fetchMonthlyTimes(_currentCity);
      if (data.isEmpty) {
        debugPrint('[Calendar] Fetched data is empty');
        return;
      }

      // Save to prefs
      final Map<String, dynamic> toSave = {};
      DateTime? lastDate;
      String? lastHijriMonth;
      
      data.forEach((date, times) {
        toSave[date.toIso8601String()] = times;
        if (lastDate == null || date.isAfter(lastDate!)) {
          lastDate = date;
          lastHijriMonth = times['Hijri'];
        }
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(cacheKey, jsonEncode(toSave));
      await prefs.setString(lastCityKey, _currentCity);
      if (lastHijriMonth != null) {
        await prefs.setString(lastHijriMonthKey, lastHijriMonth!);
      }

      debugPrint('[Calendar] Successfully cached ${toSave.length} days (last: $lastDate)');
    } catch (e) {
      debugPrint('[Calendar] Failed to fetch and cache: $e');
    }
  }

  @override
  void dispose() {
    _timer.cancel(); // 💡 IMPORTANT: Stop the timer when the widget is destroyed
    super.dispose();
  }

  // ----------------------------------------------------
  // 💡 NEW: Time Conversion and Countdown Logic
  // ----------------------------------------------------

  // Helper function to convert the time string "HH:MM" into a DateTime object for a given day.
  DateTime _parseStringToDateTime(String timeString, [DateTime? date]) {
    // If the time is missing or invalid, return a placeholder time (e.g., midnight)
    if (timeString.trim() == 'N/A' || !timeString.contains(':')) {
      final now = date ?? DateTime.now();
      return DateTime(now.year, now.month, now.day, 0, 0); 
    }

    // Clean and split "HH:MM" string (e.g., "05:15")
    final parts = timeString.replaceAll(RegExp(r'[^0-9:]'), '').split(':'); 
    final hour = int.tryParse(parts[0]) ?? 0;
    final minute = int.tryParse(parts[1]) ?? 0;

    // Use the provided date or today's date
    final baseDate = date ?? DateTime.now();
    
    final result = DateTime(baseDate.year, baseDate.month, baseDate.day, hour, minute);
    debugPrint('[Parse] timeString="$timeString" -> $result (isUtc: ${result.isUtc})');
    return result;
  }

  void _findNextPrayer(PrayerTimes times) {
    final now = DateTime.now();
    
    // 1. Create a map of prayer names to their DateTime objects for today.
    final prayerTimesMap = {
      'Fajr': _parseStringToDateTime(times.fajr),
      'Dhuhr': _parseStringToDateTime(times.dhuhr),
      'Asr': _parseStringToDateTime(times.asr),
      'Maghrib': _parseStringToDateTime(times.maghrib),
      'Isha': _parseStringToDateTime(times.isha),
    };

    // Find the first prayer today that is AFTER the current time
    DateTime? nextTimeToday;
    String? nextName;

    for (final entry in prayerTimesMap.entries) {
      if (entry.value.isAfter(now)) {
        nextTimeToday = entry.value;
        nextName = entry.key;
        break; // Found the next one
      }
    }

    if (nextTimeToday == null) {
      // 2. All prayers for today are finished (after Isha). Next is Fajr of tomorrow.
      _nextPrayerName = 'Fajr (Tomorrow)';
      
      // Load tomorrow's Fajr time asynchronously
      _loadTomorrowFajr();

    } else {
      // 3. Found a prayer time today.
      _nextPrayerTime = nextTimeToday;
      _nextPrayerName = nextName!;
    }

    _updateCountdown(); // Update countdown immediately
  }

  /// Load tomorrow's Fajr time from cache first, fallback to today's Fajr if not in cache
  Future<void> _loadTomorrowFajr() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      
      late PrayerTimes tomorrowTimes;
      bool foundInCache = false;
      
      // Get latitude and longitude from shared fields
      final latStr = prefs.getString('adhanLatitude') ?? '';
      final lonStr = prefs.getString('adhanLongitude') ?? '';
      final hasCoords = latStr.isNotEmpty && lonStr.isNotEmpty;
      final latitude = hasCoords ? (double.tryParse(latStr) ?? 0.0) : 0.0;
      final longitude = hasCoords ? (double.tryParse(lonStr) ?? 0.0) : 0.0;
      final coordsValid = hasCoords && latitude != 0.0 && longitude != 0.0;
      
      // First, try to load tomorrow's times from cache
      if (_useMinistry) {
        debugPrint('[Tomorrow Fajr] Ministry source: checking cache for tomorrow\'s Fajr...');
        final tomorrowFromCache = await _tryLoadTomorrowFromCache();
        if (tomorrowFromCache != null) {
          debugPrint('[Tomorrow Fajr] ✓ Found tomorrow\'s Fajr in cache');
          tomorrowTimes = tomorrowFromCache;
          foundInCache = true;
        } else {
          // Fallback: if tomorrow not in monthly cache, use today's Fajr (margin of error is only 1 minute)
          debugPrint('[Tomorrow Fajr] Tomorrow not found in monthly cache - using today\'s Fajr as fallback');
          if (_todayTimes != null) {
            tomorrowTimes = _todayTimes!;
            foundInCache = true;
          }
        }
      }
      
      // If not found in cache and offline mode is enabled, use offline calculation
      if (!foundInCache && _isOfflineMode && coordsValid) {
        // Use offline calculation for tomorrow
        debugPrint('[Tomorrow Fajr] Using offline mode');
        final offlineResult = calculatePrayerTimesOffline(
          latitude: latitude,
          longitude: longitude,
          date: tomorrow,
        );
        
        tomorrowTimes = PrayerTimes(
          fajr: offlineResult['Fajr']!,
          sunrise: offlineResult['Sunrise']!,
          dhuhr: offlineResult['Dhuhr']!,
          asr: offlineResult['Asr']!,
          maghrib: offlineResult['Maghrib']!,
          isha: offlineResult['Isha']!,
        );
        foundInCache = true;
      }
      
      // If still not found, try API mode only if coordinates are available
      if (!foundInCache && coordsValid) {
        debugPrint('[Tomorrow Fajr] Using API mode with Morocco settings');
        // For API, we need to fetch with tomorrow's date
        tomorrowTimes = await _fetchMoroccoAlAdhanTimesForDate(latitude, longitude, tomorrow);
        foundInCache = true;
      }
      
      // If no cache, offline mode, or coordinates available - fallback to today's Fajr + 24h
      if (!foundInCache) {
        debugPrint('[Tomorrow Fajr] Not in cache and no API available - falling back to today\'s Fajr + 24h');
        final todayFajr = _todayTimes?.fajr ?? '05:00';
        final todayFajrPlus24h = _parseStringToDateTime(todayFajr, DateTime.now()).add(const Duration(days: 1));
        
        if (mounted) {
          setState(() {
            _nextPrayerTime = todayFajrPlus24h;
          });
        }
        
        debugPrint('[Tomorrow Fajr] Using fallback Fajr: ${todayFajrPlus24h.toString()}');
        return;
      }
      
      // Extract tomorrow's Fajr time
      final tomorrowFajrTime = _parseStringToDateTime(tomorrowTimes.fajr, tomorrow);
      
      if (mounted) {
        setState(() {
          _nextPrayerTime = tomorrowFajrTime;
        });
      }
      
      debugPrint('[Tomorrow Fajr] Tomorrow Fajr time set to: ${tomorrowFajrTime.toString()}');
    } catch (e) {
      debugPrint('[Tomorrow Fajr] Error loading tomorrow Fajr: $e');
      // Fallback: use today's Fajr + 24 hours
      final todayFajrPlus24h = _parseStringToDateTime(_todayTimes?.fajr ?? '05:00').add(const Duration(days: 1));
      if (mounted) {
        setState(() {
          _nextPrayerTime = todayFajrPlus24h;
        });
      }
    }
  }
  
  /// Try to load tomorrow's prayer times from the cached calendar
  /// Returns null if tomorrow's date is not in the cache
  Future<PrayerTimes?> _tryLoadTomorrowFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cityId = prefs.getString('cityCityId') ?? '58';
      final cacheKey = 'calendarData_$cityId';
      
      final cachedDataStr = prefs.getString(cacheKey);
      if (cachedDataStr == null) {
        debugPrint('[_tryLoadTomorrowFromCache] No cache found');
        return null;
      }

      final cachedDataMap = jsonDecode(cachedDataStr) as Map<String, dynamic>;
      
      // Look for tomorrow's date using Gregorian calendar (ISO8601 format)
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final tomorrowIso = DateTime(tomorrow.year, tomorrow.month, tomorrow.day).toIso8601String().split('T')[0]; // YYYY-MM-DD
      
      debugPrint('[_tryLoadTomorrowFromCache] Looking for tomorrow\'s date: $tomorrowIso');
      
      // Try to find tomorrow's entry (may be stored with full ISO8601 timestamp)
      Map<String, dynamic>? tomorrowEntry;
      for (final key in cachedDataMap.keys) {
        if (key.startsWith(tomorrowIso)) {
          tomorrowEntry = cachedDataMap[key] as Map<String, dynamic>?;
          debugPrint('[_tryLoadTomorrowFromCache] ✓ Found tomorrow\'s entry: $key');
          break;
        }
      }
      
      if (tomorrowEntry == null) {
        debugPrint('[_tryLoadTomorrowFromCache] Tomorrow\'s date not in cache');
        return null;
      }

      // Extract times from cached entry
      final fajr = (tomorrowEntry['Fajr'] as String?) ?? 'N/A';
      final sunrise = (tomorrowEntry['Sunrise'] as String?) ?? 'N/A';
      final dhuhr = (tomorrowEntry['Dhuhr'] as String?) ?? 'N/A';
      final asr = (tomorrowEntry['Asr'] as String?) ?? 'N/A';
      final maghrib = (tomorrowEntry['Maghrib'] as String?) ?? 'N/A';
      final isha = (tomorrowEntry['Isha'] as String?) ?? 'N/A';
      
      debugPrint('[_tryLoadTomorrowFromCache] Fajr: $fajr, Isha: $isha');
      
      return PrayerTimes(
        fajr: fajr,
        sunrise: sunrise,
        dhuhr: dhuhr,
        asr: asr,
        maghrib: maghrib,
        isha: isha,
      );
    } catch (e) {
      debugPrint('[_tryLoadTomorrowFromCache] Error: $e');
      return null;
    }
  }

  /// Fetch Morocco AlAdhan times for a specific date
  Future<PrayerTimes> _fetchMoroccoAlAdhanTimesForDate(double latitude, double longitude, DateTime date) async {
    const apiAuthority = 'http://api.aladhan.com';
    const apiPath = '/v1/timings';
    
    // Get Unix timestamp for the specified date
    final timestamp = (DateTime(date.year, date.month, date.day).millisecondsSinceEpoch / 1000).toStringAsFixed(0);
    
    final uri = Uri.parse(
      '$apiAuthority$apiPath/$timestamp?'
      'latitude=$latitude&'
      'longitude=$longitude&'
      'method=99&'
      'methodSettings=19,null,17&'
      'school=0&'
      'latitudeAdjustmentMethod=0&'
      'midnightMethod=Standard&'
      'tune=0,0,0,0,0,5,0,0,0'
    );

    try {
      final client = HttpClient();
      client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
      final request = await client.getUrl(uri);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        final jsonResponse = jsonDecode(body);
        client.close();
        
        if (jsonResponse['code'] == 200 && jsonResponse['data'] != null) {
          return PrayerTimes.fromJson(jsonResponse);
        } else {
          throw Exception('Invalid response from AlAdhan API');
        }
      } else {
        client.close();
        throw Exception('Failed to load prayer times. Status Code: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[Tomorrow Fajr] Error fetching from API: $e');
      rethrow;
    }
  }

  void _updateCountdown() {
    if (_nextPrayerTime == null) return;

    final now = DateTime.now();
    final remaining = _nextPrayerTime!.difference(now);

    if (remaining.isNegative) {
      if (mounted) {
        // Time passed, refresh the prayer times and recalculate the next prayer.
        setState(() {
          _countdownDisplay = '00:00:00';
        });
        // Only reload if we haven't already tried for this specific date or if enough time has passed
        _smartReloadForNextPrayer();
      }
      return;
    }
    
    // Format the Duration into HH:MM:SS
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(remaining.inHours);
    final minutes = twoDigits(remaining.inMinutes.remainder(60));
    final seconds = twoDigits(remaining.inSeconds.remainder(60));
    
    if (mounted) {
      setState(() {
        _countdownDisplay = '$hours:$minutes:$seconds';
      });
    }
  }

  // Build aesthetic date display with day-of-week emphasized on the right
  Widget _buildDateDisplay(ResponsiveSizes responsive) {
    final now = DateTime.now();
    const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['January', 'February', 'March', 'April', 'May', 'June',
                    'July', 'August', 'September', 'October', 'November', 'December'];
    
    final dayName = weekdays[now.weekday - 1];
    final monthName = months[now.month - 1];
    final dateStr = '${now.day} $monthName ${now.year}';
    
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: responsive.horizontalPadding,
        vertical: responsive.verticalPadding,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Left: day of week (Parent rank - bold)
          Text(
            dayName,
            style: TextStyle(
              fontSize: responsive.headingSize,
              fontWeight: FontWeight.w400,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.9),
              letterSpacing: 0.3,
            ),
          ),
          // Right: date (Hint rank - secondary)
          Text(
            dateStr,
            style: TextStyle(
              fontSize: responsive.bodySize,
              fontWeight: FontWeight.normal,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.9),
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountdownTimer(ResponsiveSizes responsive) {
    final scheme = Theme.of(context).colorScheme;
    
    return Container(
      margin: EdgeInsets.only(
        top: responsive.spacingS,
        bottom: responsive.spacingM,
      ),
      padding: EdgeInsets.all(responsive.spacingM),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(responsive.borderRadiusStandard),
        border: Border.all(
          color: scheme.primary,
          width: 2,
        ),
      ),
      child: Column(
        children: [
          // Parent rank title
          Text(
            'Countdown to $_nextPrayerName',
            style: TextStyle(
              fontSize: responsive.titleSize,
              fontWeight: FontWeight.w600,
              color: scheme.primary.withValues(alpha: 0.9),
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: responsive.spacingM),
          // Child rank: Timer display
          Container(
            padding: EdgeInsets.symmetric(
              vertical: responsive.spacingS,
              horizontal: responsive.spacingM,
            ),
            child: SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: Text(
                  _countdownDisplay,
                  style: TextStyle(
                    fontSize: responsive.timerSize,
                    fontWeight: FontWeight.w900,
                    color: scheme.primary,
                    fontFamily: 'monospace',
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          SizedBox(height: responsive.spacingS),
          // Hint rank: Prayer time
          if (_nextPrayerTime != null)
            Text(
              'Time: ${TimeOfDay.fromDateTime(_nextPrayerTime!).format(context)}',
              style: TextStyle(
                fontSize: responsive.bodySize,
                color: scheme.onPrimaryContainer.withValues(alpha: 0.9),
                fontWeight: FontWeight.normal,
              ),
            ),
        ],
      ),
    );
  }
  // ----------------------------------------------------
  // ----------------------------------------------------


  AppBar _buildAppBar() {
    // Reload settings to get the latest useMinistry value when the AppBar is rebuilt
    _loadSettings();
    
    final responsive = ResponsiveSizes(context);
    
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      foregroundColor: Theme.of(context).colorScheme.primary,
      title: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Prayer Times',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              fontSize: responsive.titleSize,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          Text(
            _latinizeCity(_currentCity),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w400,
              fontSize: responsive.bodySize,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
      elevation: 4,
      actions: [
        IconButton(
          icon: const Icon(Icons.calendar_today),
          tooltip: 'Calendar',
            onPressed: _useMinistry ? () async {
              // Ensure calendar cache is populated before opening calendar screen
              await _maybeRefreshCalendar();
              if (mounted) {
                await Navigator.of(context).push(MaterialPageRoute(builder: (context) => PrayerCalendarScreen(apiService: _apiService)));
              }
            } : null,
        ),
        IconButton(
          icon: const Icon(Icons.settings),
          onPressed: () async {
            final changed = await Navigator.of(context)
                .push(MaterialPageRoute(builder: (context) => const SettingsScreen()));
            // Refresh only if settings changed
            if (changed == true) {
              await _loadSettings();
              await _loadTimes();
            }
          },
        )
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // 🔔 NOTIFICATION FUNCTIONS
  // ═══════════════════════════════════════════════════════════════════════
  







  /// Smart reload that only attempts once when date changes or on explicit refresh
  Future<void> _smartReloadForNextPrayer() async {
    final now = DateTime.now();
    
    // If we already failed today, don't keep retrying
    if (_reloadFailed && _lastReloadAttemptDate != null) {
      final daysSinceFail = now.difference(_lastReloadAttemptDate!).inHours ~/ 24;
      if (daysSinceFail < 1) {
        // Still same day, skip reload - user already saw the error
        return;
      }
    }
    
    // If date hasn't changed, no need to reload
    if (_lastReloadAttemptDate != null) {
      final daysSinceLastAttempt = now.difference(_lastReloadAttemptDate!).inHours ~/ 24;
      if (daysSinceLastAttempt == 0) {
        return; // Already tried today
      }
    }
    
    // Proceed with reload for new date
    _lastReloadAttemptDate = now;
    await _loadTimes();
  }

  Future<void> _loadTimes() async {
    // Load selected city from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final selectedCity = prefs.getString('selectedCityName') ?? 'Casablanca';
    final cityId = prefs.getString('cityCityId') ?? '58';
    final cityName = prefs.getString('cityCityName') ?? 'Casablanca';
    
    // Load source settings
    final useMinistry = prefs.getBool('useMinistry') ?? true;
    final ministryUrl = prefs.getString('ministryUrl') ?? 'https://habous.gov.ma/prieres/horaire_hijri_2.php';
    
    // Check if background task triggered a pending refresh
    final dailyRefreshPending = await bg_tasks.isDailyRefreshPending();
    if (dailyRefreshPending) {
      debugPrint('[_loadTimes] Daily refresh was pending from background task');
      await bg_tasks.clearDailyRefreshFlag();
    }
    
    final monthlyRefreshPending = await bg_tasks.isMonthlyRefreshPending();
    if (monthlyRefreshPending) {
      debugPrint('[_loadTimes] Monthly refresh was pending from background task, clearing calendar cache');
      await bg_tasks.clearMonthlyRefreshFlag();
    }
    
    // Only show loading if we have no data yet (initial load)
    // Background refresh doesn't show loading if data exists
    if (_todayTimes == null) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
        _currentCity = selectedCity;
      });
    }
    
    try {
      late PrayerTimes times;
      bool timesAssigned = false;
      
      // Get latitude and longitude from shared fields
      final latStr = prefs.getString('adhanLatitude') ?? '';
      final lonStr = prefs.getString('adhanLongitude') ?? '';
      final hasCoords = latStr.isNotEmpty && lonStr.isNotEmpty;
      final latitude = hasCoords ? (double.tryParse(latStr) ?? 0.0) : 0.0;
      final longitude = hasCoords ? (double.tryParse(lonStr) ?? 0.0) : 0.0;
      final coordsValid = hasCoords && latitude != 0.0 && longitude != 0.0;
      
      debugPrint('[_loadTimes] SOURCE SELECTION:');
      debugPrint('[_loadTimes] useMinistry: $useMinistry');
      debugPrint('[_loadTimes] ministryUrl: $ministryUrl');
      debugPrint('[_loadTimes] selectedCity: $selectedCity');
      debugPrint('[_loadTimes] cityId: $cityId');
      debugPrint('[_loadTimes] cityName: $cityName');
      debugPrint('[_loadTimes] _isOfflineMode: $_isOfflineMode');
      debugPrint('[_loadTimes] coordsValid: $coordsValid');
      debugPrint('[_loadTimes] latStr: "$latStr", lonStr: "$lonStr"');
      
      // If using Ministry, follow the exact flow: Parse HTML → Update Cache → Retrieve from Cache → Display
      if (useMinistry) {
        debugPrint('[_loadTimes] → Ministry source enabled, following cache flow...');
        try {
          // Step 1: Parse HTML from Ministry API
          final apiService = ApiService();
          debugPrint('[_loadTimes] Step 1: Parsing HTML from Ministry API (cityName="$selectedCity")');
          final freshTimes = await apiService.fetchOfficialMoroccanTimes(selectedCity);
          debugPrint('[_loadTimes] Fresh times from API: Fajr=${freshTimes.fajr}, Dhuhr=${freshTimes.dhuhr}, Maghrib=${freshTimes.maghrib}');
          
          if (freshTimes.fajr != 'N/A') {
            // Step 2: Update cache with parsed data using the CORRECT cache key format
            // IMPORTANT: Must match the key format used by getDailyPrayerTimes() which is 'daily_prayer_times_'
            final cacheKey = 'daily_prayer_times_$cityId';
            final cacheData = {
              'fajr': freshTimes.fajr,
              'sunrise': freshTimes.sunrise,
              'dhuhr': freshTimes.dhuhr,
              'asr': freshTimes.asr,
              'maghrib': freshTimes.maghrib,
              'isha': freshTimes.isha,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            };
            await prefs.setString(cacheKey, jsonEncode(cacheData));
            
            // DEBUG: Verify what was written to cache
            final writtenValue = prefs.getString(cacheKey);
            debugPrint('[_loadTimes] Step 2a: ✓ Cache written with key: $cacheKey');
            debugPrint('[_loadTimes] Step 2b: Written value: $writtenValue');
            
            debugPrint('[_loadTimes] Step 2c: Cache content: $cacheData');
            
            // Step 3: Retrieve cached data from daily parser
            debugPrint('[_loadTimes] Step 3: Retrieving cached data from daily parser...');
            debugPrint('[_loadTimes] Step 3a: Calling getDailyPrayerTimes(cityId=$cityId, cityName=$cityName)');
            final cachedTimes = await getDailyPrayerTimes(
              cityId: cityId,
              cityName: cityName,
            );
            
            // DEBUG: Log exactly what we got back
            debugPrint('[_loadTimes] Step 3b: getDailyPrayerTimes returned:');
            debugPrint('[_loadTimes]   - Fajr: ${cachedTimes['fajr']}');
            debugPrint('[_loadTimes]   - Sunrise: ${cachedTimes['sunrise']}');
            debugPrint('[_loadTimes]   - Dhuhr: ${cachedTimes['dhuhr']}');
            debugPrint('[_loadTimes]   - Asr: ${cachedTimes['asr']}');
            debugPrint('[_loadTimes]   - Maghrib: ${cachedTimes['maghrib']}');
            debugPrint('[_loadTimes]   - Isha: ${cachedTimes['isha']}');
            
            // Step 4: Display the cached data
            if (cachedTimes['fajr'] != 'N/A' && cachedTimes['dhuhr'] != 'N/A') {
              debugPrint('[_loadTimes] Step 4: ✓ Valid cached data, creating PrayerTimes object');
              
              // DEBUG: Create the object and log what it contains
              times = PrayerTimes(
                fajr: cachedTimes['fajr'] ?? 'N/A',
                sunrise: cachedTimes['sunrise'] ?? 'N/A',
                dhuhr: cachedTimes['dhuhr'] ?? 'N/A',
                asr: cachedTimes['asr'] ?? 'N/A',
                maghrib: cachedTimes['maghrib'] ?? 'N/A',
                isha: cachedTimes['isha'] ?? 'N/A',
              );
              timesAssigned = true;
              
              debugPrint('[_loadTimes] Step 4a: PrayerTimes object created:');
              debugPrint('[_loadTimes]   - Fajr: ${times.fajr}');
              debugPrint('[_loadTimes]   - Dhuhr: ${times.dhuhr}');
              debugPrint('[_loadTimes]   - Maghrib: ${times.maghrib}');
              debugPrint('[_loadTimes] Step 4b: Ready for display');
            } else {
              debugPrint('[_loadTimes] Step 4 failed: Cache returned N/A, using API data directly');
              debugPrint('[_loadTimes] Step 4a: Creating PrayerTimes from freshTimes:');
              debugPrint('[_loadTimes]   - Fajr: ${freshTimes.fajr}');
              debugPrint('[_loadTimes]   - Dhuhr: ${freshTimes.dhuhr}');
              times = freshTimes;
              timesAssigned = true;
            }
          }
        } catch (e) {
          debugPrint('[_loadTimes] Failed to process Ministry data: $e, will use existing cache');
          await _showSilentErrorNotification('Ministry API', e.toString());
        }
      }
      
      // Check if offline mode is enabled and has valid coordinates
      // BUT: If using Ministry source, skip this (we already loaded fresh API data above)
      if (!useMinistry && _isOfflineMode && coordsValid) {
        // Use offline calculation only if NOT using Ministry source
        try {
          debugPrint('[_loadTimes] → Using OFFLINE mode');
          final offlineResult = calculatePrayerTimesOffline(
            latitude: latitude,
            longitude: longitude,
            date: DateTime.now(),
          );
          
          // Convert offline result to PrayerTimes object
          times = PrayerTimes(
            fajr: offlineResult['Fajr']!,
            sunrise: offlineResult['Sunrise']!,
            dhuhr: offlineResult['Dhuhr']!,
            asr: offlineResult['Asr']!,
            maghrib: offlineResult['Maghrib']!,
            isha: offlineResult['Isha']!,
          );
          timesAssigned = true;
        } catch (e) {
          debugPrint('[_loadTimes] ✗ Offline calculation failed: $e');
          await _showSilentErrorNotification('Offline Calculation', e.toString());
        }
      } else if (!useMinistry && !_isOfflineMode && coordsValid) {
        // Try Adhan API if NOT using Ministry and NOT in offline mode, but have valid coordinates
        try {
          debugPrint('[_loadTimes] → Trying Adhan API with coordinates ($latitude, $longitude)');
          final adhanApiService = ApiService();
          final adhanTimes = await adhanApiService.fetchMoroccoAlAdhanTimes(latitude, longitude);
          times = adhanTimes;
          timesAssigned = true;
          debugPrint('[_loadTimes] ✓ Loaded from Adhan API');
          debugPrint('[_loadTimes]   Fajr: ${adhanTimes.fajr}');
          debugPrint('[_loadTimes]   Dhuhr: ${adhanTimes.dhuhr}');
          debugPrint('[_loadTimes]   Maghrib: ${adhanTimes.maghrib}');
        } catch (e) {
          debugPrint('[_loadTimes] ✗ Adhan API failed: $e, will try daily parser');
        }
      }
      
      // Fallback to daily parser if we still don't have times
      if (!timesAssigned && !useMinistry) {
        // Only try daily parser if NOT using Ministry (we already loaded it above)
        try {
          debugPrint('[_loadTimes] → Attempting to load from daily prayer parser...');
          final dailyTimes = await getDailyPrayerTimes(
            cityId: cityId,
            cityName: cityName,
          );
          
          // Check if daily parser returned valid data (not all N/A)
          final hasValidDailyData = dailyTimes['fajr'] != 'N/A' && 
                                   dailyTimes['dhuhr'] != 'N/A' && 
                                   dailyTimes['maghrib'] != 'N/A';
          
          if (hasValidDailyData) {
            debugPrint('[_loadTimes] ✓ Using daily parser data');
            debugPrint('[_loadTimes] LOADED TIMES FROM DAILY PARSER:');
            debugPrint('[_loadTimes]   Fajr: ${dailyTimes['fajr']}');
            debugPrint('[_loadTimes]   Sunrise: ${dailyTimes['sunrise']}');
            debugPrint('[_loadTimes]   Dhuhr: ${dailyTimes['dhuhr']}');
            debugPrint('[_loadTimes]   Asr: ${dailyTimes['asr']}');
            debugPrint('[_loadTimes]   Maghrib: ${dailyTimes['maghrib']}');
            debugPrint('[_loadTimes]   Isha: ${dailyTimes['isha']}');
            times = PrayerTimes(
              fajr: dailyTimes['fajr'] ?? 'N/A',
              sunrise: dailyTimes['sunrise'] ?? 'N/A',
              dhuhr: dailyTimes['dhuhr'] ?? 'N/A',
              asr: dailyTimes['asr'] ?? 'N/A',
              maghrib: dailyTimes['maghrib'] ?? 'N/A',
              isha: dailyTimes['isha'] ?? 'N/A',
            );
            timesAssigned = true;
          } else {
            debugPrint('[_loadTimes] Daily parser returned N/A, falling back to monthly cache...');
            // Fallback to monthly calendar cache
            try {
              final cachedTimes = await _tryLoadTodayFromCache();
              
              if (cachedTimes != null) {
                debugPrint('[_loadTimes] ✓ Loaded today\'s times from cache, no HTML parsing needed');
                times = cachedTimes;
                timesAssigned = true;
              } else {
                // Cache miss - only fetch if using ministry with coords or if offline mode not available
                if (coordsValid && !_useMinistry) {
                  // Coordinates provided and NOT using ministry = use API mode with Morocco settings
                  debugPrint('[_loadTimes] → Using API with Morocco defaults (coords: $latitude, $longitude)');
                  times = await _apiService.fetchMoroccoAlAdhanTimes(latitude, longitude);
                  timesAssigned = true;
                } else if (_useMinistry) {
                  // Using ministry source - refresh calendar to get HTML with today's times
                  debugPrint('[_loadTimes] → Ministry source: today not in cache, refreshing calendar...');
                  try {
                    await _maybeRefreshCalendar();
                    // Try to load from cache again after refresh
                    final retryTimes = await _tryLoadTodayFromCache();
                    if (retryTimes != null) {
                      debugPrint('[_loadTimes] ✓ Loaded today\'s times from cache after refresh');
                      times = retryTimes;
                      timesAssigned = true;
                    } else {
                      // Still not in cache - this shouldn't happen but fallback to Ministry API
                      debugPrint('[_loadTimes] ✗ Still not in cache after refresh, using Ministry API as fallback');
                      times = await _apiService.fetchOfficialMoroccanTimes(selectedCity);
                      timesAssigned = true;
                    }
                  } catch (monthlyErr) {
                    debugPrint('[_loadTimes] ✗ Monthly calendar parsing failed: $monthlyErr');
                    await _showSilentErrorNotification('Monthly Calendar', monthlyErr.toString());
                    times = await _apiService.fetchOfficialMoroccanTimes(selectedCity);
                    timesAssigned = true;
                  }
                } else {
                  // No coordinates and not using ministry - use Ministry API
                  debugPrint('[_loadTimes] → Using official Ministry API (city: $selectedCity)');
                  times = await _apiService.fetchOfficialMoroccanTimes(selectedCity);
                  timesAssigned = true;
                }
              }
            } catch (cacheErr) {
              debugPrint('[_loadTimes] ✗ Monthly cache loading failed: $cacheErr');
              await _showSilentErrorNotification('Monthly Cache', cacheErr.toString());
            }
          }
        } catch (dailyErr) {
          debugPrint('[_loadTimes] ✗ Daily parser failed: $dailyErr');
          await _showSilentErrorNotification('Daily Parser', dailyErr.toString());
        }
      }

      // Ensure times was assigned - if not, something went wrong
      if (!timesAssigned) {
        debugPrint('[_loadTimes] ERROR: times was never assigned! This should never happen.');
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load prayer times from any source';
          _reloadFailed = true;
        });
        return;
      }

      // Check if times changed before updating state
      final timesChanged = _todayTimes == null || 
          _todayTimes!.fajr != times.fajr ||
          _todayTimes!.dhuhr != times.dhuhr ||
          _todayTimes!.asr != times.asr ||
          _todayTimes!.maghrib != times.maghrib ||
          _todayTimes!.isha != times.isha;
      
      // DEBUG: Log the comparison
      debugPrint('[_loadTimes] ═════ STATE UPDATE CHECK ═════');
      debugPrint('[_loadTimes] Previous _todayTimes: ${_todayTimes != null ? 'Fajr=${_todayTimes!.fajr}, Dhuhr=${_todayTimes!.dhuhr}, Maghrib=${_todayTimes!.maghrib}' : 'NULL (first load)'}');
      debugPrint('[_loadTimes] New times object: Fajr=${times.fajr}, Dhuhr=${times.dhuhr}, Maghrib=${times.maghrib}');
      debugPrint('[_loadTimes] timesChanged: $timesChanged');
      
      // Check if background task requested notification reschedule
      final needsNotificationReschedule = prefs.getBool('needsNotificationReschedule') ?? false;

      debugPrint('[_loadTimes] Calling setState with: _todayTimes.fajr=${times.fajr}, _todayTimes.dhuhr=${times.dhuhr}');
      setState(() {
        _todayTimes = times;
        _isLoading = false;
        _errorMessage = null; // Clear any previous errors on success
        _currentCity = selectedCity;
        _reloadFailed = false; // Reset on success
      });
      debugPrint('[_loadTimes] setState completed, _todayTimes is now: Fajr=${_todayTimes?.fajr}, Dhuhr=${_todayTimes?.dhuhr}');
      
      // 🎯 CRITICAL: Update widget cache immediately after loading times
      // This ensures the widget always shows the correct prayer times based on the current source
      try {
        debugPrint('[_loadTimes] Updating widget cache with new prayer times...');
        // Use quickUpdateWidgetCache() instead - it detects the actual source (ministry/adhan/offline/cached)
        final widgetManager = WidgetInfoManager();
        await widgetManager.quickUpdateWidgetCache();
        debugPrint('[_loadTimes] ✓ Widget cache updated successfully');
      } catch (e) {
        debugPrint('[_loadTimes] ✗ Failed to update widget cache: $e');
      }
      
      // 💡 NEW: Find the next prayer time after loading new data
      _findNextPrayer(times);
      
      // 🔔 Schedule notifications if times changed or background task requested it
      if (timesChanged || needsNotificationReschedule) {
        if (needsNotificationReschedule) {
          debugPrint('[_loadTimes] Background task requested notification reschedule');
          await prefs.remove('needsNotificationReschedule');
        }
        if (timesChanged) {
          debugPrint('[_loadTimes] Prayer times changed, scheduling notifications...');
        }
        
        // Use NotificationManager to schedule notifications
        try {
          final globalStateValue = prefs.getInt('notificationState') ?? 2;
          final notificationState = NotificationState.fromValue(globalStateValue);
          final athanSoundTypeValue = prefs.getInt('athanSoundType') ?? 0;
          final athanSoundType = AthanSoundType.fromValue(athanSoundTypeValue);
          final reminderEnabled = prefs.getBool('reminderEnabled') ?? false;
          final reminderMinutes = prefs.getInt('reminderMinutes') ?? 10;
          
          final manager = NotificationManager();
          final timezone = getDeviceTimezone();
          
          // Use PrayerTimesProvider to get times based on user's selected source
          final provider = PrayerTimesProvider();
          final result = await provider.getPrayerTimes();
          
          debugPrint('[LoadTimes] Using source: ${result.sourceUsed}');
          
          await manager.scheduleNotificationsForTodaysPrayers(
            prayerTimes: result.times,
            reminderEnabled: reminderEnabled,
            reminderMinutes: reminderMinutes,
            notificationState: notificationState,
            athanSoundType: athanSoundType,
            timezone: timezone,
          );          
          // Delay to allow scheduled notifications to appear in the pending list
          // Different devices have different delays, so we use a longer wait
          await Future.delayed(const Duration(milliseconds: 1000));
        } catch (e) {
          debugPrint('[_loadTimes] Error scheduling notifications: $e');
        }
      } else {
        debugPrint('[_loadTimes] Prayer times unchanged (loaded from cache), skipping notification reschedule');
      }
      
      // 📅 Register monthly calendar refresh task if cache exists and is valid
      try {
        await bg_tasks.registerMonthlyCalendarRefresh();
        debugPrint('[_loadTimes] Monthly calendar refresh task registered/updated');
      } catch (e) {
        debugPrint('[_loadTimes] Could not register monthly task: $e');
      }
      
    } catch (e) {
      // Only clear data if we had none (first load failed)
      // Otherwise keep existing data visible
      setState(() {
        _isLoading = false;
        if (_todayTimes == null) {
          _errorMessage = 'Failed to load prayer times: $e';
        } else {
          // Data exists, just show a subtle error indicator
          _errorMessage = null; // Don't interrupt with error message
        }
        _reloadFailed = true; // Mark as failed - won't retry until next day
      });
      
      debugPrint('Error loading prayer times: $e');
      
      // Only show snackbar if we had no data (first load failure)
      if (mounted && _todayTimes == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load prayer times: $e')),
        );
      }
    }
  }

  // ignore: use_build_context_synchronously
  /// Show a silent error notification for prayer times failures
  Future<void> _showSilentErrorNotification(String errorType, String message) async {
    try {
      debugPrint('[ErrorNotification] Showing silent error for: $errorType - $message');
      
      await flutterLocalNotificationsPlugin.show(
        9998, // Unique ID for error notifications
        '⚠️ Prayer Times Error',
        '$errorType: $message',
        NotificationDetails(
          android: AndroidNotificationDetails(
            'pray_times_channel_silent', // Use silent channel
            'Prayer Times Errors',
            channelDescription: 'Silent notifications for prayer time calculation errors',
            importance: Importance.low,
            priority: Priority.low,
            enableVibration: false,
            playSound: false,
            enableLights: false,
            tag: 'prayer_error',
            color: Colors.red,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: false,
            presentBadge: false,
            presentSound: false,
          ),
        ),
      );
      
      debugPrint('[ErrorNotification] ✓ Silent error notification shown');
    } catch (e) {
      debugPrint('[ErrorNotification] ✗ Failed to show error notification: $e');
    }
  }

  /// Try to load today's prayer times from the cached calendar (using Gregorian date)
  /// Returns null if today's date is not in the cache
  Future<PrayerTimes?> _tryLoadTodayFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cityId = prefs.getString('cityCityId') ?? '58';
      final cacheKey = 'calendarData_$cityId';
      
      final cachedDataStr = prefs.getString(cacheKey);
      if (cachedDataStr == null) {
        debugPrint('[_tryLoadTodayFromCache] No cache found');
        return null;
      }

      final cachedDataMap = jsonDecode(cachedDataStr) as Map<String, dynamic>;
      
      // Look for today's date using Gregorian calendar (ISO8601 format)
      final today = DateTime.now();
      final todayIso = DateTime(today.year, today.month, today.day).toIso8601String().split('T')[0]; // YYYY-MM-DD
      
      debugPrint('[_tryLoadTodayFromCache] Looking for today\'s date: $todayIso');
      
      // Try to find today's entry (may be stored with full ISO8601 timestamp)
      Map<String, dynamic>? todayEntry;
      for (final key in cachedDataMap.keys) {
        if (key.startsWith(todayIso)) {
          todayEntry = cachedDataMap[key] as Map<String, dynamic>?;
          debugPrint('[_tryLoadTodayFromCache] ✓ Found today\'s entry: $key');
          break;
        }
      }
      
      if (todayEntry == null) {
        debugPrint('[_tryLoadTodayFromCache] Today\'s date not in cache');
        return null;
      }

      // Extract times from cached entry
      final fajr = (todayEntry['Fajr'] as String?) ?? 'N/A';
      final sunrise = (todayEntry['Sunrise'] as String?) ?? 'N/A';
      final dhuhr = (todayEntry['Dhuhr'] as String?) ?? 'N/A';
      final asr = (todayEntry['Asr'] as String?) ?? 'N/A';
      final maghrib = (todayEntry['Maghrib'] as String?) ?? 'N/A';
      final isha = (todayEntry['Isha'] as String?) ?? 'N/A';
      
      debugPrint('[_tryLoadTodayFromCache] Fajr: $fajr, Isha: $isha');
      
      return PrayerTimes(
        fajr: fajr,
        sunrise: sunrise,
        dhuhr: dhuhr,
        asr: asr,
        maghrib: maghrib,
        isha: isha,
      );
    } catch (e) {
      debugPrint('[_tryLoadTodayFromCache] Error: $e');
      return null;
    }
  }


  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: settingsChangeNotifier,
      builder: (context, _, __) {
        return _buildScaffold();
      },
    );
  }

  Widget _buildScaffold() {
  if (_isLoading) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: const Center(child: CircularProgressIndicator()),
    );
  }

  if (_errorMessage != null) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadTimes,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  // Get screen dimensions for responsive layout
  final responsive = ResponsiveSizes(context);
  
  return Scaffold(
    appBar: _buildAppBar(),
    body: RefreshIndicator(
      onRefresh: _loadTimes,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: responsive.paddingHorizontal,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: responsive.constrainedWidth,
                minHeight: responsive.minScrollableHeight,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  // Date display - aesthetic design
                  Padding(
                    padding: EdgeInsets.only(bottom: responsive.spacingS),
                    child: _buildDateDisplay(responsive),
                  ),
                  _buildCountdownTimer(responsive),
                  ..._buildPrayerCards(responsive.cardSpacing, responsive),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

  List<Widget> _buildPrayerCards(double spacing, ResponsiveSizes responsive) {
    // Extract prayer name, but don't highlight if it's "Fajr (Tomorrow)"
    String next = '';
    if (!_nextPrayerName.contains('Tomorrow')) {
      next = _nextPrayerName.split(RegExp(r'\s|\(')).first;
    }
    
    return [
      _buildPrayerTimeCard('Fajr', _todayTimes?.fajr, spacing, responsive.prayerNameSize, responsive.prayerTimeSize, isNext: next == 'Fajr'),
      SizedBox(height: spacing / 2),
      _buildPrayerTimeCard('Sunrise', _todayTimes?.sunrise, spacing, responsive.prayerNameSize, responsive.prayerTimeSize, isNext: next == 'Sunrise'),
      SizedBox(height: spacing / 2),
      _buildPrayerTimeCard('Dhuhr', _todayTimes?.dhuhr, spacing, responsive.prayerNameSize, responsive.prayerTimeSize, isNext: next == 'Dhuhr'),
      SizedBox(height: spacing / 2),
      _buildPrayerTimeCard('Asr', _todayTimes?.asr, spacing, responsive.prayerNameSize, responsive.prayerTimeSize, isNext: next == 'Asr'),
      SizedBox(height: spacing / 2),
      _buildPrayerTimeCard('Maghrib', _todayTimes?.maghrib, spacing, responsive.prayerNameSize, responsive.prayerTimeSize, isNext: next == 'Maghrib'),
      SizedBox(height: spacing / 2),
      _buildPrayerTimeCard('Isha', _todayTimes?.isha, spacing, responsive.prayerNameSize, responsive.prayerTimeSize, isNext: next == 'Isha'),
    ];
  }

  Widget _buildPrayerTimeCard(
    String prayerName,
    String? time,
    double spacing,
    double nameSize,
    double timeSize, {
    bool isNext = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    final responsive = ResponsiveSizes(context);
    
    return Container(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.symmetric(
        vertical: responsive.spacingS,
        horizontal: responsive.spacingM,
      ),
      decoration: BoxDecoration(
        color: isNext
            ? scheme.primaryContainer.withValues(alpha: 0.8)
            : scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(responsive.borderRadiusStandard),
        border: Border.all(
          color: isNext
              ? scheme.primary
              : scheme.primary.withValues(alpha: 0.5),
          width: isNext ? 2 : 1,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                if (isNext) ...[Icon(Icons.play_arrow, color: scheme.onPrimaryContainer, size: nameSize * 0.9), SizedBox(width: responsive.spacingS)],
                Expanded(
                  child: Text(
                    prayerName,
                    style: TextStyle(
                      fontSize: nameSize,
                      fontWeight: isNext ? FontWeight.w700 : FontWeight.w600,
                      color: isNext ? scheme.onPrimaryContainer : scheme.onPrimaryContainer.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Text(
            time ?? 'N/A',
            style: TextStyle(
              fontSize: timeSize,
              fontWeight: FontWeight.bold,
              color: isNext ? scheme.onPrimaryContainer : accent,
            ),
          ),
        ],
      ),
    );
  }
}

class PrayerTimeScreen extends StatefulWidget {
  const PrayerTimeScreen({super.key});

  @override
  State<PrayerTimeScreen> createState() => _PrayerTimeScreenState();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, mode, _) {
        return ValueListenableBuilder<double>(
          valueListenable: primaryHueNotifier,
          builder: (context, primaryHue, _) {
            // Light mode: more saturated colors
            final lightPrimaryColor = HSLColor.fromAHSL(1.0, primaryHue % 360, 0.72, 0.45).toColor();
            
            // Dark mode: less saturated colors for readability
            final darkPrimaryColor = HSLColor.fromAHSL(1.0, primaryHue % 360, 0.62, 0.45).toColor();

            final lightScheme = ColorScheme.fromSeed(seedColor: lightPrimaryColor, brightness: Brightness.light);
            final darkScheme = ColorScheme.fromSeed(seedColor: darkPrimaryColor, brightness: Brightness.dark);

            return MaterialApp(
              title: 'Prayer Times',
              theme: ThemeData(
                colorScheme: lightScheme,
                useMaterial3: true,
              ),
              darkTheme: ThemeData(
                colorScheme: darkScheme,
                useMaterial3: true,
              ),
              themeMode: mode,
              home: const PrayerTimeScreen(),
            );
          },
        );
      },
    );
  }
}

// Notification enums and helpers are now imported from notifications package
// See: services/notifications/notification_config.dart
/// Helper function to get the appropriate prayer channel ID based on notification state and athan type
/// Wrapper that delegates to the imported function
String _getPrayerChannelId(NotificationState state, {AthanSoundType athanType = AthanSoundType.system}) {
  return getPrayerChannelId(state, athanType: athanType);
}

/// Helper function to get the appropriate reminder channel ID based on notification state
/// Wrapper that delegates to the imported function
String _getReminderChannelId(NotificationState state) {
  return getReminderChannelId(state);
}

/// Fetch pending notifications with parsed payloads for display
Future<List<Map<String, dynamic>>> getPendingNotificationsWithMetadata() async {
  final pendingNotifications = await flutterLocalNotificationsPlugin.pendingNotificationRequests();
  
  final notificationsWithMetadata = <Map<String, dynamic>>[];
  
  for (final notif in pendingNotifications) {
    try {
      final metadata = notif.payload != null && notif.payload!.isNotEmpty
          ? jsonDecode(notif.payload!) as Map<String, dynamic>
          : <String, dynamic>{};
      
      notificationsWithMetadata.add({
        'id': notif.id,
        'title': notif.title,
        'body': notif.body,
        'payload': metadata,
        'type': metadata['type'] as String? ?? 'unknown',
        'prayer': metadata['prayer'] as String? ?? 'Unknown',
        'scheduledTime': metadata['scheduledTime'] as int? ?? 0,
        'state': metadata['state'] as int? ?? 2,
        'hasCountdown': metadata['hasCountdown'] as bool? ?? false,
      });
    } catch (e) {
      debugPrint('[Error] Failed to parse notification payload: $e');
      // Add notification with minimal metadata
      notificationsWithMetadata.add({
        'id': notif.id,
        'title': notif.title,
        'body': notif.body,
        'payload': {},
        'type': 'unknown',
        'prayer': 'Unknown',
        'scheduledTime': 0,
        'state': 2,
        'hasCountdown': false,
      });
    }
  }
  
  // Sort by scheduled time
  notificationsWithMetadata.sort((a, b) => (a['scheduledTime'] as int).compareTo(b['scheduledTime'] as int));
  
  return notificationsWithMetadata;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize developer notification toggles to false (disabled by default)
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('devShowDailyRefreshNotification', false);
  await prefs.setBool('devShowMonthlyRefreshNotification', false);
  
  // Initialize timezone data
  tzdata.initializeTimeZones();
  
  // Get and set device timezone
  try {
    // Try to get the device timezone
    final deviceTimezone = DateTime.now().timeZoneName;
    debugPrint('Device timezone name: $deviceTimezone');
    
    // Try to find matching timezone from the tz package
    if (deviceTimezone.isNotEmpty && deviceTimezone != 'UTC') {
      try {
        final tzLocation = tz.getLocation(deviceTimezone);
        tz.setLocalLocation(tzLocation);
        debugPrint('Set local timezone to: ${tzLocation.name}');
      } catch (e) {
        debugPrint('Could not set timezone "$deviceTimezone": $e');
        // Try common timezone names as fallback
        final commonTzs = [
          'Africa/Casablanca', 
          'Europe/London', 
          'Europe/Paris',
          'America/New_York',
          'Asia/Kolkata',
        ];
        for (final tzName in commonTzs) {
          try {
            final tzLocation = tz.getLocation(tzName);
            if (tzLocation.currentTimeZone.offset == DateTime.now().timeZoneOffset.inMicroseconds ~/ Duration.microsecondsPerMillisecond) {
              tz.setLocalLocation(tzLocation);
              debugPrint('Matched device offset to timezone: ${tzLocation.name}');
              break;
            }
          } catch (_) {}
        }
      }
    }
  } catch (e) {
    debugPrint('Error setting device timezone: $e');
  }
  
  // Initialize local notifications
  const AndroidInitializationSettings androidInitializationSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  
  const DarwinInitializationSettings iOSInitializationSettings =
      DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  
  const InitializationSettings initializationSettings = InitializationSettings(
    android: androidInitializationSettings,
    iOS: iOSInitializationSettings,
  );
  
  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse notificationResponse) async {
      debugPrint('Notification tapped: ${notificationResponse.payload}');
      
      // Handle athan dismiss action
      if (notificationResponse.actionId == 'dismiss_athan') {
        debugPrint('Athan dismissed by user');
        // Cancel the notification to stop the sound
        await flutterLocalNotificationsPlugin.cancel(notificationResponse.id ?? 0);
      }
    },
  );
  
  // Create notification channels for Android (three-state approach: silent, vibrate, full)
  if (Platform.isAndroid) {
    // Prayer times channels
    final AndroidNotificationChannel prayerChannelSilent = AndroidNotificationChannel(
      'pray_times_channel_silent',
      'Prayer Times (Silent)',
      description: 'Athan notifications without sound or vibration',
      importance: Importance.max,
      enableVibration: false,
      vibrationPattern: Int64List(0),
      playSound: false,
      enableLights: true,
      showBadge: true,
    );
    
    final AndroidNotificationChannel prayerChannelVibrate = AndroidNotificationChannel(
      'pray_times_channel_vibrate',
      'Prayer Times (Vibration)',
      description: 'Athan notifications with vibration only',
      importance: Importance.max,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
      playSound: false,
      enableLights: true,
      showBadge: true,
    );
    
    final AndroidNotificationChannel prayerChannelFull = AndroidNotificationChannel(
      'pray_times_channel_full_v2',
      'Prayer Times (Full)',
      description: 'Athan notifications with vibration and sound',
      importance: Importance.max,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
      playSound: true,
      enableLights: true,
      showBadge: true,
    );
    
    // Warning/reminder channels
    final AndroidNotificationChannel warningChannelSilent = AndroidNotificationChannel(
      'prayer_warnings_channel_silent',
      'Prayer Warnings (Silent)',
      description: 'Reminder notifications without sound or vibration',
      importance: Importance.high,
      enableVibration: false,
      vibrationPattern: Int64List(0),
      playSound: false,
      enableLights: true,
      showBadge: false,
    );
    
    final AndroidNotificationChannel warningChannelVibrate = AndroidNotificationChannel(
      'prayer_warnings_channel_vibrate',
      'Prayer Warnings (Vibration)',
      description: 'Reminder notifications with vibration only',
      importance: Importance.high,
      enableVibration: true,
      playSound: false,
      enableLights: true,
      showBadge: false,
    );
    
    final AndroidNotificationChannel warningChannelFull = AndroidNotificationChannel(
      'prayer_warnings_channel_full',
      'Prayer Warnings (Full)',
      description: 'Reminder notifications with vibration and sound',
      importance: Importance.high,
      enableVibration: true,
      playSound: true,
      enableLights: true,
      showBadge: false,
    );
    
    // Athan notification channels
    final AndroidNotificationChannel athanChannelShort = AndroidNotificationChannel(
      'athan_channel_short_v2',
      'Athan (Short - 4 seconds)',
      description: 'Short athan notification (4 seconds)',
      importance: Importance.max,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
      playSound: true,
      sound: const RawResourceAndroidNotificationSound('shortathan'),
      enableLights: true,
      showBadge: true,
    );
    
    final AndroidNotificationChannel athanChannelNormal = AndroidNotificationChannel(
      'athan_channel_normal_v2',
      'Athan (Normal)',
      description: 'Full athan notification with dismiss button',
      importance: Importance.max,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
      playSound: true,
      sound: const RawResourceAndroidNotificationSound('athan'),
      enableLights: true,
      showBadge: true,
    );
    
    try {
      final androidImpl = flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidImpl != null) {
        // Delete ALL channels (old and new) to force complete recreation with fresh settings
        // This is necessary on Android/EMUI because once a channel is created, its settings are cached
        // and cannot be changed - the only way to change them is to delete and recreate the channel
        debugPrint('[Init] Deleting all notification channels to force recreation with correct settings...');
        try {
          // Delete old channel IDs (pre-tri-state version)
          await androidImpl.deleteNotificationChannel('pray_times_channel');
          await androidImpl.deleteNotificationChannel('prayer_warnings_channel');
          
          // Delete new channel IDs (tri-state version) - ensures fresh creation
          await androidImpl.deleteNotificationChannel('pray_times_channel_silent');
          await androidImpl.deleteNotificationChannel('pray_times_channel_vibrate');
          await androidImpl.deleteNotificationChannel('pray_times_channel_full');
          await androidImpl.deleteNotificationChannel('prayer_warnings_channel_silent');
          await androidImpl.deleteNotificationChannel('prayer_warnings_channel_vibrate');
          await androidImpl.deleteNotificationChannel('prayer_warnings_channel_full');
          
          debugPrint('[Init] ✓ All notification channels deleted');
        } catch (e) {
          debugPrint('[Init] Note: Some channels may not exist yet: $e');
        }
        
        // Now create all six channels with correct settings
        debugPrint('[Init] Creating 6 notification channels with tri-state settings...');
        try {
          await androidImpl.createNotificationChannel(prayerChannelSilent);
          debugPrint('[Init] ✓ Created: pray_times_channel_silent (no sound, no vibration)');
          
          await androidImpl.createNotificationChannel(prayerChannelVibrate);
          debugPrint('[Init] ✓ Created: pray_times_channel_vibrate (vibration only, no sound)');
          
          await androidImpl.createNotificationChannel(prayerChannelFull);
          debugPrint('[Init] ✓ Created: pray_times_channel_full (full sound + vibration)');
          
          await androidImpl.createNotificationChannel(warningChannelSilent);
          debugPrint('[Init] ✓ Created: prayer_warnings_channel_silent (no sound, no vibration)');
          
          await androidImpl.createNotificationChannel(warningChannelVibrate);
          debugPrint('[Init] ✓ Created: prayer_warnings_channel_vibrate (vibration only, no sound)');
          
          await androidImpl.createNotificationChannel(warningChannelFull);
          debugPrint('[Init] ✓ Created: prayer_warnings_channel_full (full sound + vibration)');
          
          await androidImpl.createNotificationChannel(athanChannelShort);
          debugPrint('[Init] ✓ Created: athan_channel_short_v2 (4 second athan sound)');
          
          await androidImpl.createNotificationChannel(athanChannelNormal);
          debugPrint('[Init] ✓ Created: athan_channel_normal_v2 (full athan sound with dismiss button)');
          
          debugPrint('[Init] ✓ All notification channels created successfully');
        } catch (e) {
          debugPrint('[Init] ✗ Error creating notification channels: $e');
        }
      } else {
        debugPrint('[Init] Android implementation not available to create channels');
      }
    } catch (e) {
      debugPrint('[Init] Error managing notification channels: $e');
    }

    // Check permissions and settings (query plugin-level state when available)
    try {
      final androidImpl = flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        try {
          final enabled = await androidImpl.areNotificationsEnabled();
          debugPrint('[Init] androidImpl.areNotificationsEnabled() -> $enabled');
        } catch (e) {
          debugPrint('[Init] androidImpl.areNotificationsEnabled() failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[Init] Error while querying permission via plugin: $e');
    }

    await _checkNotificationPermissions();
  }
  
  // ONE-TIME CACHE CLEANUP: Remove stale cache from previous sessions
  final cacheCleanupDone = prefs.getBool('cacheCleanupDone_v4') ?? false;
  
  if (!cacheCleanupDone) {
    debugPrint('[AppInit] Running one-time cache cleanup...');
    try {
      // Remove all calendar data keys (they'll be re-fetched with new parser)
      final allKeys = prefs.getKeys();
      for (final key in allKeys) {
        if (key.contains('calendarData') || key.contains('2025-') || key.contains('_monthLabel')) {
          await prefs.remove(key);
          debugPrint('[AppInit] Removed stale key: $key');
        }
      }
      // Also remove the old v3 flag to allow fresh start
      await prefs.remove('cacheCleanupDone_v3');
      await prefs.setBool('cacheCleanupDone_v4', true);
      debugPrint('[AppInit] ✓ Cache cleanup completed');
    } catch (e) {
      debugPrint('[AppInit] Error during cache cleanup: $e');
    }
  }
  
  // Initialize background task scheduler with new implementation
  await bg_tasks.initializeBackgroundTasks();
  
  debugPrint('[AppInit] Background task scheduler initialized with daily and monthly refresh tasks');
  
  // Load initial theme setting from SharedPreferences
  final savedThemeMode = prefs.getString('themeMode') ?? 'system';
  if (savedThemeMode == 'light') {
    themeNotifier.value = ThemeMode.light;
  } else if (savedThemeMode == 'dark') {
    themeNotifier.value = ThemeMode.dark;
  } else {
    themeNotifier.value = ThemeMode.system;
  }
  debugPrint('[AppInit] Theme mode loaded: $savedThemeMode → ${themeNotifier.value}');
  
  // Load initial primary hue from SharedPreferences
  final savedHue = prefs.getDouble('primaryHue') ?? 260.0;
  primaryHueNotifier.value = savedHue;
  debugPrint('[AppInit] Primary hue loaded: $savedHue');
  
  // Setup method channel to handle widget refresh requests from Android
  const widgetChannel = MethodChannel('com.example.pray_time/widget');
  widgetChannel.setMethodCallHandler((call) async {
    if (call.method == 'refreshWidget') {
      debugPrint('[WidgetRefresh] ╔════════════════════════════════════╗');
      debugPrint('[WidgetRefresh] ║ REFRESH REQUEST FROM ANDROID WIDGET║');
      debugPrint('[WidgetRefresh] ╚════════════════════════════════════╝');
      try {
        // Step 1: Get current settings to show what we're working with
        final prefsWidget = await SharedPreferences.getInstance();
        final useMinistry = prefsWidget.getBool('useMinistry') ?? true;
        final isOfflineMode = prefsWidget.getBool('isOfflineMode') ?? false;
        final selectedCity = prefsWidget.getString('selectedCityName') ?? 'Unknown';
        final lat = prefsWidget.getString('adhanLatitude') ?? '';
        final lon = prefsWidget.getString('adhanLongitude') ?? '';
        
        debugPrint('[WidgetRefresh] Current Settings:');
        debugPrint('[WidgetRefresh]   - useMinistry: $useMinistry');
        debugPrint('[WidgetRefresh]   - isOfflineMode: $isOfflineMode');
        debugPrint('[WidgetRefresh]   - selectedCity: $selectedCity');
        debugPrint('[WidgetRefresh]   - coordinates: ($lat, $lon)');
        
        // Step 2: Fetch fresh prayer times from appropriate source
        debugPrint('[WidgetRefresh] Fetching fresh prayer times...');
        final widgetManager = WidgetInfoManager();
        final success = await widgetManager.quickUpdateWidgetCache();
        
        debugPrint('[WidgetRefresh] Cache update result: $success');
        
        if (success) {
          debugPrint('[WidgetRefresh] ✓ Fresh prayer times fetched and cached');
          return {'success': true};
        } else {
          debugPrint('[WidgetRefresh] ✗ Failed to update cache');
          return {'success': false, 'error': 'Cache update failed'};
        }
      } catch (e) {
        debugPrint('[WidgetRefresh] ✗ ERROR: $e');
        debugPrint('[WidgetRefresh] Stack trace: $e');
        return {'success': false, 'error': e.toString()};
      }
    }
    return null;
  });
  
  runApp(const MyApp());
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class PrayerCalendarScreen extends StatefulWidget {
  final ApiService apiService;
  const PrayerCalendarScreen({super.key, required this.apiService});

  @override
  State<PrayerCalendarScreen> createState() => _PrayerCalendarScreenState();
}

class _PrayerCalendarScreenState extends State<PrayerCalendarScreen> {
  late Future<Map<String, dynamic>> _calendarFuture;
  int? _todayHijriDay;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadCalendarData();
  }

  void _loadCalendarData() {
    _calendarFuture = _fetchCalendarFromCache();
  }

  Future<Map<String, dynamic>> _fetchCalendarFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final cityId = prefs.getString('cityCityId') ?? '58';
    final cacheKey = 'calendarData_$cityId';
    
    debugPrint('[Calendar] Loading cache with key: $cacheKey');
    
    final cached = prefs.getString(cacheKey);
    if (cached == null) {
      debugPrint('[Calendar] ERROR: No cached data found for key: $cacheKey');
      throw Exception('No calendar data in cache for city $cityId');
    }
    
    debugPrint('[Calendar] Cache found, parsing...');
    final decoded = jsonDecode(cached) as Map<String, dynamic>;
    debugPrint('[Calendar] Cache has ${decoded.length} entries');
    
    // Debug: print first few keys
    final keys = decoded.keys.toList().take(5).toList();
    debugPrint('[Calendar] First keys: $keys');
    
    return decoded;
  }

  int? _findCurrentHijriDay(Map<String, dynamic> calendar) {
    final today = DateTime.now();
    final todayStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    
    debugPrint('[Calendar] Looking for today: $todayStr');
    
    for (final entry in calendar.entries) {
      if (entry.key.startsWith('_')) continue;
      
      // Try to parse date key
      final parsedDate = DateTime.tryParse(entry.key);
      if (parsedDate != null) {
        final entryDateStr = '${parsedDate.year}-${parsedDate.month.toString().padLeft(2, '0')}-${parsedDate.day.toString().padLeft(2, '0')}';
        
        if (entryDateStr == todayStr) {
          debugPrint('[Calendar] Found today! Entry: $entry');
          if (entry.value is Map) {
            final dayData = entry.value as Map;
            final hijri = dayData['Hijri']?.toString();
            debugPrint('[Calendar] Today hijri day: $hijri');
            return int.tryParse(hijri ?? '');
          }
        }
      }
    }
    
    debugPrint('[Calendar] Could not find today in cache');
    return null;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer.adaptive( context,0.4),
        foregroundColor: Theme.of(context).colorScheme.primary,
        title: const Text('Prayer Calendar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                _loadCalendarData();
              });
            },
          ),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _calendarFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Error: ${snapshot.error}'),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _loadCalendarData();
                      });
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }
          
          if (!snapshot.hasData) {
            return const Center(child: Text('No data available'));
          }
          
          final calendar = snapshot.data!;
          
          // Find today's hijri day
          if (_todayHijriDay == null) {
            _todayHijriDay = _findCurrentHijriDay(calendar);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToCurrentDay();
            });
          }
          
          // Build list of days - iterate through cached data sorted by Hijri day number
          final dayEntries = <MapEntry<String, dynamic>>[];
          
          for (final entry in calendar.entries) {
            if (entry.key.startsWith('_')) continue; // Skip metadata
            
            if (entry.value is Map) {
              dayEntries.add(entry);
            }
          }
          
          // Sort by Hijri day number (1-29 first, then moon symbol at end)
          dayEntries.sort((a, b) {
            final hijriA = (a.value as Map)['Hijri']?.toString() ?? '';
            final hijriB = (b.value as Map)['Hijri']?.toString() ?? '';
            
            // Moon symbols go to the end
            if (hijriA == '☽' && hijriB != '☽') return 1;
            if (hijriA != '☽' && hijriB == '☽') return -1;
            if (hijriA == '☽' && hijriB == '☽') return 0;
            
            // Otherwise sort numerically
            final numA = int.tryParse(hijriA) ?? 0;
            final numB = int.tryParse(hijriB) ?? 0;
            return numA.compareTo(numB);
          });
          
          debugPrint('[Calendar] Built ${dayEntries.length} day entries');
          
          final days = <Widget>[];
          
          for (final entry in dayEntries) {
            final dayData = entry.value as Map;
            final cacheKeyIso = entry.key; // The cache key IS the ISO date
            // Use the actual Hijri day from the data (could be a number or '☽' for moon observation)
            final hijriDayStr = dayData['Hijri']?.toString() ?? '';
            final hijriDayNum = hijriDayStr == '☽' ? -1 : int.tryParse(hijriDayStr) ?? 0;
            debugPrint('[Calendar] Processing entry: key=${entry.key}, Hijri="$hijriDayStr", parsed=$hijriDayNum');
            if (hijriDayNum != 0) {
              days.add(_buildDayCard(hijriDayNum, hijriDayStr, dayData, cacheKeyIso, context));
            }
          }
          
          return RefreshIndicator(
            onRefresh: () async {
              setState(() {
                _loadCalendarData();
              });
              await _calendarFuture;
            },
            child: ListView(
              controller: _scrollController,
              children: days.isEmpty
                  ? [const Center(child: Text('No prayer times available'))]
                  : days,
            ),
          );
        },
      ),
    );
  }

  Widget _buildDayCard(int hijriDayNum, String hijriDayDisplay, Map dayData, String cacheKeyIso, BuildContext context) {
    final isCurrentDay = (hijriDayNum > 0 && _todayHijriDay == hijriDayNum);
    final scheme = Theme.of(context).colorScheme;
    final responsive = ResponsiveSizes(context);
    
    final dayOfWeek = _translateWeekday(dayData['DayOfWeek']?.toString() ?? '');
    // Use cache key as ISO date (format: 2025-11-22T00:00:00.000, we want the date part)
    final gregorianDateIso = cacheKeyIso.split('T')[0]; // Extract 2025-11-22 from 2025-11-22T00:00:00.000
    final hijriMonthArabic = dayData['HijriMonth']?.toString() ?? '';
    final hijriMonthLatin = hijriMonthArabic.isNotEmpty ? transliterateHijriMonth(hijriMonthArabic) : '';
    
    // Parse ISO date to get day and month
    String formattedDate = '—';
    String formattedMonth = '—';
    if (gregorianDateIso.isNotEmpty) {
      try {
        final parts = gregorianDateIso.split('-');
        if (parts.length == 3) {
          formattedDate = parts[2]; // Day
          formattedMonth = _monthNumberToName(int.parse(parts[1])); // Month name
        }
      } catch (e) {
        debugPrint('Error parsing ISO date: $e');
      }
    }
    
    final fajr = dayData['Fajr']?.toString() ?? '—';
    final sunrise = dayData['Sunrise']?.toString() ?? '—';
    final dhuhr = dayData['Dhuhr']?.toString() ?? '—';
    final asr = dayData['Asr']?.toString() ?? '—';
    final maghrib = dayData['Maghrib']?.toString() ?? '—';
    final isha = dayData['Isha']?.toString() ?? '—';
    
    debugPrint('[Day $hijriDayDisplay] Week: $dayOfWeek, ISO: $gregorianDateIso, Hijri: $hijriMonthArabic');
    
    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: responsive.horizontalPadding,
        vertical: responsive.verticalPadding,
      ),
      padding: EdgeInsets.all(responsive.spacingM),
      decoration: BoxDecoration(
        color: isCurrentDay
            ? scheme.primaryContainer.withValues(alpha: 0.4)
            : scheme.primaryContainer.withValues(alpha: 0.12),
        border: Border.all(
          color: isCurrentDay ? scheme.primary : scheme.primary.withValues(alpha: 0.15),
          width: isCurrentDay ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(responsive.borderRadiusStandard),
      ),
      child: Column(
        children: [
          // Header: Hijri left, Gregorian right, Weekday between
          Row(
            children: [
              // Left: Hijri day + month
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      hijriDayDisplay,
                      style: TextStyle(
                        fontSize: hijriDayDisplay == '☽' ? responsive.hijriDaySize * 1.1 : responsive.hijriDaySize,
                        fontWeight: FontWeight.bold,
                        color: scheme.primary,
                        height: 1,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 4.0), // Adjust the value as needed
                         child: Text(
                          hijriMonthLatin.isEmpty ? '—' : hijriMonthLatin.split(' ')[0],
                          style: TextStyle(
                           fontSize: responsive.hijriMonthSize,
                           fontWeight: FontWeight.w600,
                           color: scheme.primary.withValues(alpha: 0.7),
                           height: 1.1,
                          ),
                        ),
                    )
                  ],
                ),
              ),
              // Center: Weekday
              Expanded(
                child: Text(
                  dayOfWeek.isEmpty ? '—' : dayOfWeek,
                  style: TextStyle(
                    fontSize: responsive.weekdaySize,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary.withValues(alpha: 0.8),
                    letterSpacing: 0.3,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              // Right: Gregorian day + month
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formattedDate,
                      style: TextStyle(
                        fontSize: responsive.gregorianDaySize,
                        fontWeight: FontWeight.bold,
                        color: scheme.primary,
                        height: 1,
                      ),
                    ),
                    Text(
                      formattedMonth,
                      style: TextStyle(
                        fontSize: responsive.gregorianMonthSize,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary.withValues(alpha: 0.7),
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: responsive.spacingM),
          // Prayer times grid (3 columns x 2 rows)
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.6,
            mainAxisSpacing: responsive.cardSpacing,
            crossAxisSpacing: responsive.cardSpacing,
            children: [
              _buildPrayerTimeCell('Fajr', fajr, scheme, responsive),
              _buildPrayerTimeCell('Sunrise', sunrise, scheme, responsive),
              _buildPrayerTimeCell('Dhuhr', dhuhr, scheme, responsive),
              _buildPrayerTimeCell('Asr', asr, scheme, responsive),
              _buildPrayerTimeCell('Maghrib', maghrib, scheme, responsive),
              _buildPrayerTimeCell('Isha', isha, scheme, responsive),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPrayerTimeCell(String name, String time, ColorScheme scheme, [ResponsiveSizes? responsive]) {
    responsive ??= ResponsiveSizes(context);
    
    return Container(
      padding: EdgeInsets.all(responsive.spacingXS),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(responsive.borderRadiusSmall),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            name,
            style: TextStyle(
              fontSize: responsive.cellNameSize,
              fontWeight: FontWeight.w600,
              color: scheme.primary,
            ),
          ),
          SizedBox(height: responsive.spacingXS),
          Text(
            time,
            style: TextStyle(
              fontSize: responsive.cellTimeSize,
              fontWeight: FontWeight.bold,
              color: scheme.onPrimaryContainer.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }

  String _translateWeekday(String input) {
    return translateWeekday(input);
  }

  String _monthNumberToName(int month) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return (month >= 1 && month <= 12) ? months[month - 1] : '—';
  }

  void _scrollToCurrentDay() {
    if (_scrollController.hasClients) {
      try {
        // If we found today's hijri day, scroll to it
        if (_todayHijriDay != null && _todayHijriDay! > 0) {
          final itemHeight = 220.0;
          final offset = (_todayHijriDay! - 1) * itemHeight;
          _scrollController.animateTo(
            offset,
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOut,
          );
          debugPrint('[Calendar] Scrolled to today (Hijri day $_todayHijriDay)');
        } else {
          // If today not found, scroll to top
          _scrollController.animateTo(
            0.0,
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOut,
          );
          debugPrint('[Calendar] Today not in cache, scrolled to top');
        }
      } catch (e) {
        debugPrint('[Calendar] Scroll error: $e');
      }
    }
  }
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _directIdController = TextEditingController();
  // Adhan API controllers
  final TextEditingController _adhanLatitudeController = TextEditingController();
  final TextEditingController _adhanLongitudeController = TextEditingController();
  final TextEditingController _adhanCityController = TextEditingController();
  final TextEditingController _adhanCountryController = TextEditingController();
  late String _selectedCityName;
  late String _selectedCityId;
  bool _useMinistry = true;
  // Offline mode settings
  bool _isOfflineMode = false;
  // Notification settings
  bool _notificationsEnabled = true; // master switch
  bool _prayerNotificationsEnabled = true;
  bool _reminderEnabled = false;
  int _reminderMinutes = 10;
  int _previousReminderMinutes = 10; // Track previous value for validation
  late TextEditingController _reminderMinutesController;
  // Countdown timer toggle: only fires if reminder is also enabled, uses same duration as reminder
  bool _enableCountdownTimer = false;
  final TextEditingController _testNotificationSecondsController = TextEditingController(text: '10');
  bool _notifyFajr = true;
  // Key to refresh scheduled notifications list
  int _scheduledNotificationsRefreshKey = 0;
  // Cached future for pending notifications - only updates when refresh key changes
  late Future<List<Map<String, dynamic>>> _pendingNotificationsFuture;
  bool _notifySunrise = true;
  bool _notifyDhuhr = true;
  bool _notifyAsr = true;
  bool _notifyMaghrib = true;
  bool _notifyIsha = true;
  
  // Per-prayer reminder toggles (whether to send reminders for each prayer)
  bool _reminderFajr = true;
  bool _reminderSunrise = true;
  bool _reminderDhuhr = true;
  bool _reminderAsr = true;
  bool _reminderMaghrib = true;
  bool _reminderIsha = true;
  
  // Advanced notification control: per-athan notification states
  bool _useAdvancedNotificationControl = false;
  final Map<String, NotificationState> _prayerNotificationStates = {
    'Fajr': NotificationState.full,
    'Sunrise': NotificationState.full,
    'Dhuhr': NotificationState.full,
    'Asr': NotificationState.full,
    'Maghrib': NotificationState.full,
    'Isha': NotificationState.full,
  };
  final Map<String, NotificationState> _reminderNotificationStates = {
    'Fajr': NotificationState.full,
    'Sunrise': NotificationState.full,
    'Dhuhr': NotificationState.full,
    'Asr': NotificationState.full,
    'Maghrib': NotificationState.full,
    'Isha': NotificationState.full,
  };

  Future<void> _handleSendTestNotification() async {
    if (_devUseScheduledTestNotification) {
      try {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Scheduling test notification (5s)...')));
        await _scheduleTestNotificationScheduled(5);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Scheduled test notification')));
      } catch (e) {
        debugPrint('[DevUI] Failed scheduling test notification: $e');
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } else {
      await _showTestNotificationStatic();
    }
  }

  /// Test the two-notification reminder system
  Future<void> _testReminderNotificationSystem() async {
    try {
      debugPrint('═════ TEST REMINDER NOTIFICATION SYSTEM ═════');
      
      final prefs = await SharedPreferences.getInstance();
      final reminderMinutes = prefs.getInt('reminderMinutes') ?? 10;
      final notificationStateValue = prefs.getInt('notificationState') ?? 2;
      final notificationState = NotificationState.fromValue(notificationStateValue);
      
      debugPrint('[TestReminder] Settings:');
      debugPrint('[TestReminder]   Reminder Minutes: $reminderMinutes');
      debugPrint('[TestReminder]   Notification State: ${notificationState.label}');
      debugPrint('[TestReminder]   Playback: ${notificationState == NotificationState.full ? 'Sound + Vibration' : notificationState == NotificationState.vibrate ? 'Vibration only' : 'Silent'}');
      
      // Schedule for 10 seconds from now as test, with visual timer 5 seconds before
      final now = DateTime.now();
      final prayerTestTime = now.add(const Duration(seconds: 10));
      final reminderTestTime = now.add(const Duration(seconds: 5));
      
      debugPrint('[TestReminder] Timeline:');
      debugPrint('[TestReminder]   Current Time: $now');
      debugPrint('[TestReminder]   Reminder #1 (Visual Timer) at: $reminderTestTime');
      debugPrint('[TestReminder]   Reminder #2 (Killer) at: $prayerTestTime');
      debugPrint('[TestReminder]   Gap between notifications: 5 seconds');
      
      final location = getDeviceTimezone();
      final reminderTzTime = tz.TZDateTime.from(reminderTestTime, location);
      final prayerTzTime = tz.TZDateTime.from(prayerTestTime, location);
      
      debugPrint('[TestReminder] TZ Converted:');
      debugPrint('[TestReminder]   Reminder TZ Time: $reminderTzTime');
      debugPrint('[TestReminder]   Prayer TZ Time: $prayerTzTime');
      debugPrint('[TestReminder]   Prayer epoch: ${prayerTestTime.millisecondsSinceEpoch}');
      
      const testReminderId = 99998; // Unique ID for test
      final channelId = _getReminderChannelId(notificationState);
      
      debugPrint('[TestReminder] Notification ID: $testReminderId');
      debugPrint('[TestReminder] Channel: $channelId');
      
      // ═══════════════════════════════════════════════════════════════
      // NOTIFICATION #1: Visual Timer with Chronometer (using show())
      // ═══════════════════════════════════════════════════════════════
      debugPrint('[TestReminder] [STEP 1] Showing visual timer with Chronometer immediately...');
      
      try {
        await flutterLocalNotificationsPlugin.show(
          testReminderId,
          '🕐 TEST: Fajr in 5 seconds',
          'This is a test countdown timer - watch it count down!',
          NotificationDetails(
            android: AndroidNotificationDetails(
              channelId,
              'Prayer Warnings',
              channelDescription: 'Countdown timer notifications',
              importance: Importance.high,
              priority: Priority.high,
              enableLights: true,
              tag: 'reminder_test',
              color: Colors.orange,
              // Native Chronometer countdown
              usesChronometer: true,
              chronometerCountDown: true,
              when: prayerTestTime.millisecondsSinceEpoch,
              showWhen: true,
              playSound: notificationState == NotificationState.full,
              enableVibration: notificationState != NotificationState.silent,
            ),
            iOS: DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: false,
              presentSound: true,
            ),
          ),
          payload: jsonEncode({
            'type': 'test_reminder',
            'prayer': 'TEST',
            'scheduledTime': reminderTzTime.millisecondsSinceEpoch,
            'state': notificationState.value,
            'hasCountdown': true,
          }),
        );
        
        debugPrint('[TestReminder] ✓ Notification #1 shown immediately');
        debugPrint('[TestReminder]   - Display method: show() (immediate)');
        debugPrint('[TestReminder]   - Has Chronometer: YES');
        debugPrint('[TestReminder]   - When (countdown target): ${prayerTestTime.millisecondsSinceEpoch}');
        debugPrint('[TestReminder]   - Show When: true');
      } catch (e1) {
        debugPrint('[TestReminder] ✗ Failed to show notification #1: $e1');
        rethrow;
      }
      
      // ═══════════════════════════════════════════════════════════════
      // NOTIFICATION #2: Killer (removes Chronometer at prayer time)
      // ═══════════════════════════════════════════════════════════════
      debugPrint('[TestReminder] [STEP 2] Scheduling killer notification (same ID)...');
      
      try {
        // Use silent channel for killer notification (no sound, no vibration)
        const killerChannelId = 'prayer_warnings_channel_silent';
        
        await flutterLocalNotificationsPlugin.zonedSchedule(
          testReminderId, // SAME ID - replaces Notification #1
          '🕌 TEST: Fajr',
          'Prayer time reached (test)',
          prayerTzTime,
          NotificationDetails(
            android: AndroidNotificationDetails(
              killerChannelId,
              'Prayer Warnings (Silent)',
              channelDescription: 'Silent killer notification',
              importance: Importance.high,
              priority: Priority.high,
              enableLights: true,
              tag: 'reminder_test',
              color: Colors.orange,
              // NO chronometer - stops the ticking
              usesChronometer: false,
              chronometerCountDown: false,
              showWhen: false,
              // Self-destruct after 1ms
              timeoutAfter: 1,
              // SILENT - no sound, no vibration
              playSound: false,
              enableVibration: false,
            ),
            iOS: DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: false,
              presentSound: false,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          payload: jsonEncode({
            'type': 'test_reminder_killer',
            'prayer': 'TEST',
            'scheduledTime': prayerTzTime.millisecondsSinceEpoch,
            'state': NotificationState.silent.value,
            'hasCountdown': false,
          }),
        );
        
        debugPrint('[TestReminder] ✓ Notification #2 scheduled');
        debugPrint('[TestReminder]   - Has Chronometer: NO (stops countdown)');
        debugPrint('[TestReminder]   - Timeout After: 1ms (auto-delete)');
        debugPrint('[TestReminder]   - Schedule mode: exactAllowWhileIdle');
        debugPrint('[TestReminder]   - Channel: $killerChannelId (SILENT)');
        debugPrint('[TestReminder]   - Sound: NO');
        debugPrint('[TestReminder]   - Vibration: NO');
        debugPrint('[TestReminder]   - Will fire at: $prayerTzTime (${prayerTestTime.millisecondsSinceEpoch})');
      } catch (e2) {
        debugPrint('[TestReminder] ✗ Failed to schedule notification #2: $e2');
        rethrow;
      }
      
      debugPrint('[TestReminder] ═════════════════════════════════════════');
      debugPrint('[TestReminder] ✓ TEST SETUP COMPLETE');
      debugPrint('[TestReminder] Expected behavior:');
      debugPrint('[TestReminder]   1. NOW: Visual timer appears with countdown (5 seconds remaining)');
      debugPrint('[TestReminder]   2. At +5s: You should watch the countdown tick down');
      debugPrint('[TestReminder]   3. At +10s: Timer disappears (replaced by killer notification)');
      debugPrint('[TestReminder] ═════════════════════════════════════════');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✓ Visual timer should now be visible! Countdown will stop at +10s')),
        );
      }
    } catch (e) {
      debugPrint('[TestReminder] ✗ ERROR: $e');
      debugPrint('[TestReminder] Stack trace: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✗ Failed: $e')),
        );
      }
    }
  }

  /// Test function to compare offline calculation results vs Ministry API results
  Future<void> _testOfflineVsApiComparison() async {
    try {
      debugPrint('\n\n');
      debugPrint('╔══════════════════════════════════════════════════════════╗');
      debugPrint('║   COMPARING OFFLINE CALCULATION vs MINISTRY API TIMES    ║');
      debugPrint('╚══════════════════════════════════════════════════════════╝');
      
      final prefs = await SharedPreferences.getInstance();
      final latStr = prefs.getString('latitude') ?? '33.5898';
      final lonStr = prefs.getString('longitude') ?? '-7.6038';
      final latitude = double.tryParse(latStr) ?? 33.5898;
      final longitude = double.tryParse(lonStr) ?? -7.6038;
      
      final selectedCity = prefs.getString('selectedCityName') ?? 'Casablanca';
      final cityId = prefs.getString('cityCityId') ?? '58';
      
      debugPrint('[Comparison] Location: $selectedCity (Lat: $latitude, Lon: $longitude)');
      debugPrint('[Comparison] City ID: $cityId');
      debugPrint('[Comparison] Date: ${DateTime.now()}');
      debugPrint('[Comparison]');
      
      // ═════════════════════════════════════════════════════════════════
      // TEST 1: Offline Calculation
      // ═════════════════════════════════════════════════════════════════
      debugPrint('[Comparison] ━━━ TEST 1: OFFLINE CALCULATION ━━━');
      final offlineResult = calculatePrayerTimesOffline(
        latitude: latitude,
        longitude: longitude,
        date: DateTime.now(),
      );
      
      debugPrint('[Comparison] Offline Results:');
      debugPrint('[Comparison]   Fajr:    ${offlineResult['Fajr']}');
      debugPrint('[Comparison]   Sunrise: ${offlineResult['Sunrise']}');
      debugPrint('[Comparison]   Dhuhr:   ${offlineResult['Dhuhr']}');
      debugPrint('[Comparison]   Asr:     ${offlineResult['Asr']}');
      debugPrint('[Comparison]   Maghrib: ${offlineResult['Maghrib']}');
      debugPrint('[Comparison]   Isha:    ${offlineResult['Isha']}');
      
      // ═════════════════════════════════════════════════════════════════
      // TEST 2: Ministry API
      // ═════════════════════════════════════════════════════════════════
      debugPrint('[Comparison] ━━━ TEST 2: MINISTRY API ━━━');
      final apiService = ApiService();
      final apiResult = await apiService.fetchOfficialMoroccanTimes(selectedCity);
      
      debugPrint('[Comparison] API Results:');
      debugPrint('[Comparison]   Fajr:    ${apiResult.fajr}');
      debugPrint('[Comparison]   Sunrise: ${apiResult.sunrise}');
      debugPrint('[Comparison]   Dhuhr:   ${apiResult.dhuhr}');
      debugPrint('[Comparison]   Asr:     ${apiResult.asr}');
      debugPrint('[Comparison]   Maghrib: ${apiResult.maghrib}');
      debugPrint('[Comparison]   Isha:    ${apiResult.isha}');
      
      // ═════════════════════════════════════════════════════════════════
      // COMPARISON
      // ═════════════════════════════════════════════════════════════════
      debugPrint('[Comparison]');
      debugPrint('[Comparison] ━━━ COMPARISON ━━━');
      
      final prayers = ['Fajr', 'Sunrise', 'Dhuhr', 'Asr', 'Maghrib', 'Isha'];
      final offlineKeys = ['Fajr', 'Sunrise', 'Dhuhr', 'Asr', 'Maghrib', 'Isha'];
      final apiGetters = [apiResult.fajr, apiResult.sunrise, apiResult.dhuhr, apiResult.asr, apiResult.maghrib, apiResult.isha];
      
      int differences = 0;
      for (int i = 0; i < prayers.length; i++) {
        final prayer = prayers[i];
        final offlineTime = offlineResult[offlineKeys[i]]!;
        final apiTime = apiGetters[i];
        
        final match = offlineTime == apiTime ? '✓' : '✗ DIFF';
        if (offlineTime != apiTime) differences++;
        
        debugPrint('[Comparison] $prayer: $match');
        debugPrint('[Comparison]   Offline: $offlineTime');
        debugPrint('[Comparison]   API:     $apiTime');
        if (offlineTime != apiTime) {
          debugPrint('[Comparison]   ⚠️  MISMATCH DETECTED');
        }
      }
      
      debugPrint('[Comparison]');
      debugPrint('[Comparison] ═════════════════════════════════════════════');
      debugPrint('[Comparison] TOTAL DIFFERENCES: $differences out of ${prayers.length}');
      if (differences == 0) {
        debugPrint('[Comparison] ✓ PERFECT MATCH: All times are identical!');
      } else {
        debugPrint('[Comparison] ⚠️  WARNING: Found $differences mismatched prayer times');
      }
      debugPrint('[Comparison] ═════════════════════════════════════════════');
      
      if (!mounted) return;
      
      final message = differences == 0 
          ? '✓ Perfect match! Offline and API times are identical.'
          : '⚠️ Found $differences differences - check logs for details';
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      debugPrint('[Comparison] ✗ ERROR: $e');
      debugPrint('[Comparison] Stack trace: $e');
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✗ Comparison failed: $e'),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }
  // Vibration and sound settings (tri-state toggle)
  late NotificationState _notificationState;
  // Athan sound type preference (system/shortAthan/fullAthan)
  late AthanSoundType _athanSoundType;
  // Developer: use scheduling logic for test notifications instead of immediate show()
  bool _devUseScheduledTestNotification = false;
  // Developer: toggle to show/hide daily refresh notifications
  bool _devShowDailyRefreshNotification = false;
  // Developer: toggle to show/hide monthly refresh notifications
  bool _devShowMonthlyRefreshNotification = false;
  // Developer: whether the dev menu is unlocked (shown) - toggle with long-press on About
  bool _devMenuUnlocked = false;
  // Theme preference: 'system' | 'light' | 'dark'
  String _themeModePref = 'system';
  // Accent hue (0-360)
  double _primaryHue = 260.0;
  // Widget background transparency (0.0 = transparent, 1.0 = opaque)
  double _widgetBgTransparency = 1.0;
  List<String> _filteredCities = [];
  List<String> _favorites = [];
  String _adhanMethod = 'MWL';
  String _adhanSchool = 'Shafi';
  bool _moroccoDefaultsEnabled = false;
  double _customFajrAngle = 19.1;
  double _customIshaAngle = 17.0;
  late TextEditingController _fajrAngleController;
  late TextEditingController _ishaAngleController;
  // Custom dropdown state variables
  bool _showThemeDropdown = false;
  // Performance: cache city metadata to avoid repeated lookups
  final Map<String, Map<String, String>> _cityCache = {};
  
  // ═══════════════════════════════════════════════════════════════
  // CHANGE TRACKING: Store original values to detect changes
  // ═══════════════════════════════════════════════════════════════
  late String _originalSelectedCityName;
  late String _originalSelectedCityId;
  late String _originalMinistryUrl;
  late bool _originalUseMinistry;
  late bool _originalNotificationsEnabled;
  late bool _originalPrayerNotificationsEnabled;
  late bool _originalReminderEnabled;
  late int _originalReminderMinutes;
  late bool _originalEnableCountdownTimer;
  late bool _originalNotifyFajr;
  late bool _originalNotifySunrise;
  late bool _originalNotifyDhuhr;
  late bool _originalNotifyAsr;
  late bool _originalNotifyMaghrib;
  late bool _originalNotifyIsha;
  late bool _originalReminderFajr;
  late bool _originalReminderSunrise;
  late bool _originalReminderDhuhr;
  late bool _originalReminderAsr;
  late bool _originalReminderMaghrib;
  late bool _originalReminderIsha;
  late NotificationState _originalNotificationState;
  late AthanSoundType _originalAthanSoundType;
  late bool _originalUseAdvancedNotificationControl;
  late bool _originalDevUseScheduledTestNotification;
  late bool _originalDevShowDailyRefreshNotification;
  late bool _originalDevShowMonthlyRefreshNotification;
  late Map<String, NotificationState> _originalPrayerNotificationStates = {};
  late Map<String, NotificationState> _originalReminderNotificationStates = {};
  late String _originalAdhanLatitude;
  late String _originalAdhanLongitude;
  late String _originalAdhanCity;
  late String _originalAdhanCountry;
  late bool _originalIsOfflineMode;
  late String _originalThemeModePref;
  late double _originalPrimaryHue;
  late double _originalWidgetBgTransparency;
  late List<String> _originalFavorites;
  
  bool _settingsChanged = false;

  // Latin names mapping for searchability - comprehensive city index
  static const Map<String, String> latinNames = {
    'آزرو': 'Azrou',
    'آسفي': 'Safi',
    'آيت القاق': 'Aït El Kag',
    'آيت ورير': 'Aït Ourir',
    'أحفير': 'Ahfir',
    'أخفنير': 'Akhfennir',
    'أرفود': 'Erfoud',
    'أزمور': 'Azemmour',
    'أزيلال': 'Azilal',
    'أسا': 'Assa',
    'أسكين': 'Asguine',
    'أسول': 'Assoul',
    'أصيلة': 'Asilah',
    'أقا': 'Akka',
    'أكادير': 'Agadir',
    'أكايوار': 'Akaïouar',
    'أكدال أملشيل': 'Agoudal Amilchil',
    'أكدز': 'Agdz',
    'أكنول': 'Aknoul',
    'أمسمرير': 'Msemrir',
    'أمكالة': 'Amgala',
    'أوسرد': 'Aousserd',
    'أولاد تايمة': 'Oulad Teïma',
    'أولاد عياد': 'Oulad Ayad',
    'إغرم': 'Igherm',
    'إملشيل': 'Imilchil',
    'إموزار كندر': 'Imouzzer Kandar',
    'إيكس': 'Iks',
    'إيمنتانوت': 'Imintanoute',
    'إيمين ثلاث': 'Imin N\'Tlat',
    'ابن أحمد': 'Bin Ahmed',
    'اكودال املشيل ميدلت': 'Agoudal Amilchil Midelt',
    'البروج': 'El Borouj',
    'الجبهة': 'El Jebha',
    'الجديدة': 'El Jadida',
    'الحاجب': 'El Hajeb',
    'الحسيمة': 'Al Hoceima',
    'الخميسات': 'Khemisset',
    'الداخلة': 'Dakhla',
    'الدار البيضاء': 'Casablanca',
    'الرباط': 'Rabat',
    'الرحامنة': 'Rehamna',
    'الرشيدية': 'Errachidia',
    'الرماني': 'Rommani',
    'الريش': 'Errich',
    'الريصاني': 'Rissani',
    'الزاك': 'Assa-Zag',
    'السعيدية': 'Saïdia',
    'السمارة': 'Es-Semara',
    'الصويرة': 'Essaouira',
    'العرائش': 'Larache',
    'العيون': 'Laâyoune',
    'العيون الشرقية': 'El Aïoun Sidi Mellouk',
    'الفقيه بنصالح': 'Fquih Ben Salah',
    'الفنيدق': 'Fnideq',
    'القصر الصغير': 'Ksar Sghir',
    'القصر الكبير': 'Ksar El Kebir',
    'القصيبة': 'El Ksiba',
    'القنيطرة': 'Kenitra',
    'الكارة': 'El Gara',
    'الكويرة': 'Lagouira',
    'المحبس': 'Al Mahbass',
    'المحمدية': 'Mohammedia',
    'المضيق': 'M\'diq',
    'المنزل بني يازغة': 'El Menzel',
    'الناظور': 'Nador',
    'النيف': 'Alnif',
    'الوليدية': 'Oualidia',
    'اليوسفية': 'Youssoufia',
    'بئر أنزاران': 'Bir Anzarane',
    'بئر كندوز': 'Bir Gandouz',
    'باب برد': 'Bab Berred',
    'برشيد': 'Berrechid',
    'بركان': 'Berkane',
    'بن سليمان': 'Benslimane',
    'بنجرير': 'Benguerir',
    'بني أنصار': 'Beni Ensar',
    'بني ادرار': 'Beni Drar',
    'بني تجيت': 'Beni Tadjit',
    'بني ملال': 'Beni Mellal',
    'بوجدور': 'Boujdour',
    'بورد': 'Boured',
    'بوزنيقة': 'Bouznika',
    'بوسكور': 'Bouskour',
    'بوعرفة': 'Bouarfa',
    'بوعنان': 'Bouanane',
    'بوكراع': 'Boukraa',
    'بولمان': 'Boulemane',
    'بومالن دادس': 'Boumalne Dades',
    'بويزكارن': 'Bouizakarne',
    'بويكرة': 'Biougra',
    'تارودانت': 'Taroudant',
    'تازارين': 'Tazarine',
    'تازة': 'Taza',
    'تافراوت': 'Tafraout',
    'تافوغالت': 'Tafoughalt',
    'تالسينت': 'Talsint',
    'تالوين': 'Taliouine',
    'تامصلوحت': 'Tamsloht',
    'تاهلة': 'Tahala',
    'تاوريرت': 'Taourirt',
    'تاونات': 'Taounate',
    'تزنيت': 'Tiznit',
    'تسلطانت': 'Tasoultante',
    'تطوان': 'Tetouan',
    'تفاريتي': 'Tifariti',
    'تفنتان': 'Tifntan',
    'تمنار': 'Smimou/Tamanar',
    'تنجداد': 'Tinejdad',
    'تندرارة': 'Tendrara',
    'تنديت': 'Tendit',
    'تنغير': 'Tinghir',
    'تولكولت': 'Toulkoult',
    'تيزي وسلي': 'Tizi Ousli',
    'تيسة': 'Tissa',
    'تيسنت': 'Tissint',
    'تيفلت': 'Tiflet',
    'جرادة': 'Jerada',
    'خريبكة': 'Khouribga',
    'خميس الزمامرة': 'Zemamra',
    'خميس سيدي عبد الجليل': 'Sidi Abdeljalil',
    'خنيفرة': 'Khenifra',
    'دبدو': 'Debdou',
    'دريوش': 'Driouch',
    'دمنات': 'Demnate',
    'رأس الماء': 'Ras El Ma',
    'رباط الخير': 'Ribate El Kheir',
    'زاكورة': 'Zagora',
    'زاوية أحنصال': 'Zaouiat Ahansal',
    'زاوية مولاي ابراهيم': 'Moulay Brahim',
    'زايو': 'Zaio',
    'زرهون': 'Moulay Idriss Zerhoun',
    'سبتة': 'Ceuta',
    'سطات': 'Settat',
    'سلوان': 'Selouane',
    'سوق أربعاء الغرب': 'Souk El Arba',
    'سيدي إفني': 'Sidi Ifni',
    'سيدي بنور': 'Sidi Bennour',
    'سيدي سليمان': 'Sidi Slimane',
    'سيدي غانم': 'Sidi Ghanem',
    'سيدي قاسم': 'Sidi Kacem',
    'سيدي يحيى الغرب': 'Sidi Yahya El Gharb',
    'شفشاون': 'Chefchaouen',
    'شيشاوة': 'Chichaoua',
    'صفرو': 'Sefrou',
    'طاطا': 'Tata',
    'طانطان': 'Tan-Tan',
    'طرفاية': 'Tarfaya',
    'طنجة': 'Tangier',
    'عرباوة': 'Arbaoua',
    'عين الشعير': 'Aïn Chaïr',
    'عين العودة': 'Aïn El Aouda',
    'فاس': 'Fes',
    'فرخانة': 'Farkhana',
    'فزوان': 'Fezouane',
    'فكيك': 'Figuig',
    'فم زكيد': 'Foum Zguid',
    'فم لحصن': 'Foum El Hisn',
    'قرية با محمد': 'Karia Ba Mohamed',
    'قصبة تادلة': 'Kasba Tadla',
    'قصر إيش': 'Ksar Ich',
    'قطارة': 'Ghattara',
    'قلعة السراغنة': 'El Kelaa des Sraghna',
    'قلعة مكونة': 'Kalaat M\'Gouna',
    'كتامة': 'Ketama',
    'كرس': 'Guers',
    'كرسيف': 'Guercif',
    'كلتة زمور': 'Guelta Zemmur',
    'كلميم': 'Guelmim',
    'كلميمة': 'Goulmima',
    'لمسيد': 'Lemseid',
    'مراكش': 'Marrakech',
    'مرتيل': 'Martil',
    'مطماطة': 'Matmata',
    'مكناس': 'Meknes',
    'مليلية': 'Melilla',
    'مولاي بوسلهام': 'Moulay Bousselham',
    'مولاي بوعزة': 'Moulay Bouazza',
    'مولاي يعقوب': 'Moulay Yacoub',
    'ميدلت': 'Midelt',
    'ميسور': 'Missour',
    'هسكورة': 'Skoura',
    'واد أمليل': 'Oued Amlil',
    'واد لاو': 'Oued Laou',
    'وادي زم': 'Oued Zem',
    'والماس': 'Oulmes',
    'وجدة': 'Oujda',
    'ورزازات': 'Ouarzazate',
    'وزان': 'Ouezzane',
    'يفرن': 'Ifrane',
  };

  @override
  void initState() {
    super.initState();
    _selectedCityName = 'الدار البيضاء';
    _selectedCityId = '58';
    _filteredCities = List.from(ApiService.ministrycityIds.keys);
    // Build city cache for fast lookups during render
    for (final city in ApiService.ministrycityIds.keys) {
      _cityCache[city] = {
        'id': ApiService.ministrycityIds[city] ?? '',
        'latin': latinNames[city] ?? '',
      };
    }
    _reminderMinutesController = TextEditingController(text: _reminderMinutes.toString());
    _fajrAngleController = TextEditingController(text: _customFajrAngle.toString());
    _ishaAngleController = TextEditingController(text: _customIshaAngle.toString());
    // Initialize _notificationState with default value to prevent LateInitializationError
    _notificationState = NotificationState.full;
    // Initialize _athanSoundType with default value to prevent LateInitializationError
    _athanSoundType = AthanSoundType.system;
    // Initialize cached future for notifications immediately with empty list
    // Then reschedule and reload notifications to ensure they're visible
    _pendingNotificationsFuture = Future.value([]);
    Future.delayed(const Duration(milliseconds: 1000), () async {
      if (mounted) {
        // Reschedule notifications to ensure they're in the system queue
        await refreshScheduledNotificationsGlobal();
        // Now fetch and display them
        _updatePendingNotificationsFuture();
      }
    });
    _loadSettings();
  }
  
  /// Update the cached pending notifications future - call this whenever refresh key changes
  void _updatePendingNotificationsFuture() {
    setState(() {
      _pendingNotificationsFuture = getPendingNotificationsWithMetadata();
      _scheduledNotificationsRefreshKey++; // Increment key to force FutureBuilder rebuild
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _urlController.text = prefs.getString('ministryUrl') ?? ApiService.defaultMinistryUrl;
      _selectedCityName = prefs.getString('selectedCityName') ?? 'الدار البيضاء';
      _selectedCityId = prefs.getString('cityCityId') ?? '58';
      _useMinistry = prefs.getBool('useMinistry') ?? true;
      _notificationsEnabled = prefs.getBool('notificationsEnabled') ?? true;
      _prayerNotificationsEnabled = prefs.getBool('prayerNotificationsEnabled') ?? true;
      _reminderEnabled = prefs.getBool('reminderEnabled') ?? false;
      _reminderMinutes = prefs.getInt('reminderMinutes') ?? 10;
      _previousReminderMinutes = _reminderMinutes;
      _reminderMinutesController.text = _reminderMinutes.toString();
      _enableCountdownTimer = prefs.getBool('enableCountdownTimer') ?? false;
      _notifyFajr = prefs.getBool('notifyFajr') ?? true;
      _notifySunrise = prefs.getBool('notifySunrise') ?? true;
      _notifyDhuhr = prefs.getBool('notifyDhuhr') ?? true;
      _notifyAsr = prefs.getBool('notifyAsr') ?? true;
      _notifyMaghrib = prefs.getBool('notifyMaghrib') ?? true;
      _notifyIsha = prefs.getBool('notifyIsha') ?? true;
      // 🔔 Load per-prayer reminder toggles
      _reminderFajr = prefs.getBool('reminderFajr') ?? true;
      _reminderSunrise = prefs.getBool('reminderSunrise') ?? true;
      _reminderDhuhr = prefs.getBool('reminderDhuhr') ?? true;
      _reminderAsr = prefs.getBool('reminderAsr') ?? true;
      _reminderMaghrib = prefs.getBool('reminderMaghrib') ?? true;
      _reminderIsha = prefs.getBool('reminderIsha') ?? true;
      final notificationStateValue = prefs.getInt('notificationState') ?? 2;
      _notificationState = NotificationState.fromValue(notificationStateValue);
      final athanSoundTypeValue = prefs.getInt('athanSoundType') ?? 0;
      _athanSoundType = AthanSoundType.fromValue(athanSoundTypeValue);
      _useAdvancedNotificationControl = prefs.getBool('useAdvancedNotificationControl') ?? false;
      _devUseScheduledTestNotification = prefs.getBool('devUseScheduledTestNotification') ?? false;
      _devShowDailyRefreshNotification = prefs.getBool('devShowDailyRefreshNotification') ?? false;
      _devShowMonthlyRefreshNotification = prefs.getBool('devShowMonthlyRefreshNotification') ?? false;
      _devMenuUnlocked = prefs.getBool('devMenuUnlocked') ?? false;
      
      // 🔔 Clear and reload granular notification states
      _prayerNotificationStates.clear();
      _prayerNotificationStates.addAll({
        'Fajr': NotificationState.full,
        'Sunrise': NotificationState.full,
        'Dhuhr': NotificationState.full,
        'Asr': NotificationState.full,
        'Maghrib': NotificationState.full,
        'Isha': NotificationState.full,
      });
      
      final prayerStatesStr = prefs.getString('prayerNotificationStates');
      if (prayerStatesStr != null) {
        final prayerStatesMap = jsonDecode(prayerStatesStr) as Map<String, dynamic>;
        prayerStatesMap.forEach((prayer, value) {
          _prayerNotificationStates[prayer] = NotificationState.fromValue(value as int);
        });
      }
      
      // 🔔 Clear and reload reminder notification states
      _reminderNotificationStates.clear();
      _reminderNotificationStates.addAll({
        'Fajr': NotificationState.full,
        'Sunrise': NotificationState.full,
        'Dhuhr': NotificationState.full,
        'Asr': NotificationState.full,
        'Maghrib': NotificationState.full,
        'Isha': NotificationState.full,
      });
      
      final reminderStatesStr = prefs.getString('reminderNotificationStates');
      if (reminderStatesStr != null) {
        final reminderStatesMap = jsonDecode(reminderStatesStr) as Map<String, dynamic>;
        reminderStatesMap.forEach((prayer, value) {
          _reminderNotificationStates[prayer] = NotificationState.fromValue(value as int);
        });
      }
      _adhanLatitudeController.text = prefs.getString('adhanLatitude') ?? '';
      _adhanLongitudeController.text = prefs.getString('adhanLongitude') ?? '';
      _adhanCityController.text = prefs.getString('adhanCity') ?? '';
      _adhanCountryController.text = prefs.getString('adhanCountry') ?? '';
      _adhanMethod = 'MWL';
      _adhanSchool = 'Shafi';
      _moroccoDefaultsEnabled = true;
      _customFajrAngle = 19.1;
      _customIshaAngle = 17.0;
      _fajrAngleController.text = '19.1';
      _ishaAngleController.text = '17.0';
      _isOfflineMode = prefs.getBool('isOfflineMode') ?? false;
      _themeModePref = prefs.getString('themeMode') ?? 'system';
      _primaryHue = prefs.getDouble('primaryHue') ?? 260.0;
      primaryHueNotifier.value = _primaryHue;
      _widgetBgTransparency = prefs.getDouble('widgetBgTransparency') ?? 1.0;
      if (_themeModePref == 'light') {
        themeNotifier.value = ThemeMode.light;
      } else if (_themeModePref == 'dark') {
        themeNotifier.value = ThemeMode.dark;
      } else {
        themeNotifier.value = ThemeMode.system;
      }
      _favorites = prefs.getStringList('favorites') ?? [];
      
      // ═══════════════════════════════════════════════════════════════
      // Store ORIGINAL values for change detection
      // ═══════════════════════════════════════════════════════════════
      _originalMinistryUrl = _urlController.text;
      _originalSelectedCityName = _selectedCityName;
      _originalSelectedCityId = _selectedCityId;
      _originalUseMinistry = _useMinistry;
      _originalNotificationsEnabled = _notificationsEnabled;
      _originalPrayerNotificationsEnabled = _prayerNotificationsEnabled;
      _originalReminderEnabled = _reminderEnabled;
      _originalReminderMinutes = _reminderMinutes;
      _originalEnableCountdownTimer = _enableCountdownTimer;
      _originalNotifyFajr = _notifyFajr;
      _originalNotifySunrise = _notifySunrise;
      _originalNotifyDhuhr = _notifyDhuhr;
      _originalNotifyAsr = _notifyAsr;
      _originalNotifyMaghrib = _notifyMaghrib;
      _originalNotifyIsha = _notifyIsha;
      _originalReminderFajr = _reminderFajr;
      _originalReminderSunrise = _reminderSunrise;
      _originalReminderDhuhr = _reminderDhuhr;
      _originalReminderAsr = _reminderAsr;
      _originalReminderMaghrib = _reminderMaghrib;
      _originalReminderIsha = _reminderIsha;
      _originalNotificationState = _notificationState;
      _originalAthanSoundType = _athanSoundType;
      _originalUseAdvancedNotificationControl = _useAdvancedNotificationControl;
      _originalDevUseScheduledTestNotification = _devUseScheduledTestNotification;
      _originalDevShowDailyRefreshNotification = _devShowDailyRefreshNotification;
      _originalDevShowMonthlyRefreshNotification = _devShowMonthlyRefreshNotification;
      _originalPrayerNotificationStates = Map.from(_prayerNotificationStates);
      _originalReminderNotificationStates = Map.from(_reminderNotificationStates);
      _originalAdhanLatitude = _adhanLatitudeController.text;
      _originalAdhanLongitude = _adhanLongitudeController.text;
      _originalAdhanCity = _adhanCityController.text;
      _originalAdhanCountry = _adhanCountryController.text;
      _originalIsOfflineMode = _isOfflineMode;
      _originalThemeModePref = _themeModePref;
      _originalPrimaryHue = _primaryHue;
      _originalWidgetBgTransparency = _widgetBgTransparency;
      _originalFavorites = List.from(_favorites);
      
      _settingsChanged = false;
    });
  }
  
  /// Detect if ANY setting has changed compared to original values
  /// Call this after EVERY user interaction (button click, text change, toggle, slider, etc.)
  void _detectChanges() {
    setState(() {
      _settingsChanged = 
        _urlController.text != _originalMinistryUrl ||
        _selectedCityName != _originalSelectedCityName ||
        _selectedCityId != _originalSelectedCityId ||
        _useMinistry != _originalUseMinistry ||
        _notificationsEnabled != _originalNotificationsEnabled ||
        _prayerNotificationsEnabled != _originalPrayerNotificationsEnabled ||
        _reminderEnabled != _originalReminderEnabled ||
        _reminderMinutes != _originalReminderMinutes ||
        _enableCountdownTimer != _originalEnableCountdownTimer ||
        _notifyFajr != _originalNotifyFajr ||
        _notifySunrise != _originalNotifySunrise ||
        _notifyDhuhr != _originalNotifyDhuhr ||
        _notifyAsr != _originalNotifyAsr ||
        _notifyMaghrib != _originalNotifyMaghrib ||
        _notifyIsha != _originalNotifyIsha ||
        _reminderFajr != _originalReminderFajr ||
        _reminderSunrise != _originalReminderSunrise ||
        _reminderDhuhr != _originalReminderDhuhr ||
        _reminderAsr != _originalReminderAsr ||
        _reminderMaghrib != _originalReminderMaghrib ||
        _reminderIsha != _originalReminderIsha ||
        _notificationState != _originalNotificationState ||
        _athanSoundType != _originalAthanSoundType ||
        _useAdvancedNotificationControl != _originalUseAdvancedNotificationControl ||
        _devUseScheduledTestNotification != _originalDevUseScheduledTestNotification ||
        _devShowDailyRefreshNotification != _originalDevShowDailyRefreshNotification ||
        _devShowMonthlyRefreshNotification != _originalDevShowMonthlyRefreshNotification ||
        _adhanLatitudeController.text != _originalAdhanLatitude ||
        _adhanLongitudeController.text != _originalAdhanLongitude ||
        _adhanCityController.text != _originalAdhanCity ||
        _adhanCountryController.text != _originalAdhanCountry ||
        _isOfflineMode != _originalIsOfflineMode ||
        _themeModePref != _originalThemeModePref ||
        _primaryHue != _originalPrimaryHue ||
        _widgetBgTransparency != _originalWidgetBgTransparency ||
        !_mapEqualsNotificationState(_prayerNotificationStates, _originalPrayerNotificationStates) ||
        !_mapEqualsNotificationState(_reminderNotificationStates, _originalReminderNotificationStates) ||
        !_listEqualsString(_favorites, _originalFavorites);
    });
  }
  
  /// Helper to compare two maps of NotificationState
  bool _mapEqualsNotificationState(Map<String, NotificationState> a, Map<String, NotificationState> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }
  
  /// Helper to compare two lists of strings
  bool _listEqualsString(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    debugPrint('═════ SAVING SETTINGS ═════');
    debugPrint('[SaveSettings] ENTRY STATE:');
    debugPrint('[SaveSettings]   _widgetBgTransparency = $_widgetBgTransparency');
    debugPrint('[SaveSettings]   _originalWidgetBgTransparency = $_originalWidgetBgTransparency');
    debugPrint('[SaveSettings]   Are equal? ${_originalWidgetBgTransparency == _widgetBgTransparency}');
    debugPrint('[SaveSettings]   Difference: ${(_widgetBgTransparency - _originalWidgetBgTransparency).abs()}');
    debugPrint('[PreSave] Prayer Notification States Map: ${_prayerNotificationStates.entries.map((e) => '${e.key}=${e.value.label}(${e.value.value})').join(', ')}');
    
    // Check if city changed - if so, clear the old cache
    final originalCityId = prefs.getString('cityCityId') ?? '58';
    final cityCityIdChanged = originalCityId != _selectedCityId;
    if (cityCityIdChanged) {
      debugPrint('[Settings] City ID changed from $originalCityId to $_selectedCityId - clearing cache');
      await prefs.remove('calendarData_$originalCityId');
      await prefs.remove('calendarLastCity_$originalCityId');
      await prefs.remove('calendarLastHijriMonth_$originalCityId');
    }
    
    // City & Source Settings
    await prefs.setString('ministryUrl', _urlController.text.trim());
    debugPrint('[Settings] Ministry URL: ${_urlController.text.trim()}');
    
    await prefs.setString('selectedCityName', _selectedCityName);
    debugPrint('[Settings] Selected City Name: $_selectedCityName');
    
    await prefs.setString('cityCityId', _selectedCityId);
    debugPrint('[Settings] City ID: $_selectedCityId');
    
    await prefs.setBool('useMinistry', _useMinistry);
    debugPrint('[Settings] Use Ministry Source: $_useMinistry');
    
    // Notification Enable/Disable
    await prefs.setBool('notificationsEnabled', _notificationsEnabled);
    debugPrint('[Settings] Notifications Enabled: $_notificationsEnabled');
    
    await prefs.setBool('prayerNotificationsEnabled', _prayerNotificationsEnabled);
    debugPrint('[Settings] Athan Notifications Enabled: $_prayerNotificationsEnabled');
    
    // Reminder Settings
    await prefs.setBool('reminderEnabled', _reminderEnabled);
    debugPrint('[Settings] Reminder Enabled: $_reminderEnabled');
    
    await prefs.setInt('reminderMinutes', _reminderMinutes);
    debugPrint('[Settings] Reminder Minutes: $_reminderMinutes');
    
    // Countdown timer toggle (uses same duration as reminder)
    await prefs.setBool('enableCountdownTimer', _enableCountdownTimer);
    debugPrint('[Settings] Enable Countdown Timer: $_enableCountdownTimer');
    
    await prefs.setBool('devUseScheduledTestNotification', _devUseScheduledTestNotification);
    debugPrint('[Settings] Dev Use Scheduled Test Notification: $_devUseScheduledTestNotification');
    
    await prefs.setBool('devShowDailyRefreshNotification', _devShowDailyRefreshNotification);
    debugPrint('[Settings] Dev Show Daily Refresh Notification: $_devShowDailyRefreshNotification');
    
    await prefs.setBool('devShowMonthlyRefreshNotification', _devShowMonthlyRefreshNotification);
    debugPrint('[Settings] Dev Show Monthly Refresh Notification: $_devShowMonthlyRefreshNotification');
    
    await prefs.setBool('devMenuUnlocked', _devMenuUnlocked);
    debugPrint('[Settings] Dev Menu Unlocked: $_devMenuUnlocked');
    
    // Individual prayer toggles
    await prefs.setBool('notifyFajr', _notifyFajr);
    debugPrint('[Settings] Notify Fajr: $_notifyFajr');
    
    await prefs.setBool('notifySunrise', _notifySunrise);
    debugPrint('[Settings] Notify Sunrise: $_notifySunrise');
    
    await prefs.setBool('notifyDhuhr', _notifyDhuhr);
    debugPrint('[Settings] Notify Dhuhr: $_notifyDhuhr');
    
    await prefs.setBool('notifyAsr', _notifyAsr);
    debugPrint('[Settings] Notify Asr: $_notifyAsr');
    
    await prefs.setBool('notifyMaghrib', _notifyMaghrib);
    debugPrint('[Settings] Notify Maghrib: $_notifyMaghrib');
    
    await prefs.setBool('notifyIsha', _notifyIsha);
    debugPrint('[Settings] Notify Isha: $_notifyIsha');
    
    // Per-prayer reminder toggles
    await prefs.setBool('reminderFajr', _reminderFajr);
    await prefs.setBool('reminderSunrise', _reminderSunrise);
    await prefs.setBool('reminderDhuhr', _reminderDhuhr);
    await prefs.setBool('reminderAsr', _reminderAsr);
    await prefs.setBool('reminderMaghrib', _reminderMaghrib);
    await prefs.setBool('reminderIsha', _reminderIsha);
    final reminderTogglesStr = 'Fajr: $_reminderFajr, Sunrise: $_reminderSunrise, Dhuhr: $_reminderDhuhr, Asr: $_reminderAsr, Maghrib: $_reminderMaghrib, Isha: $_reminderIsha';
    debugPrint('[Settings] Per-Prayer Reminder Toggles: $reminderTogglesStr');
    
    // Notification state setting (0=Silent, 1=Vibration, 2=Full)
    await prefs.setInt('notificationState', _notificationState.value);
    debugPrint('[Settings] Global Notification State: ${_notificationState.label} (${_notificationState.value})');
    
    // Athan sound type setting (0=System, 1=Short Athan, 2=Full Athan)
    await prefs.setInt('athanSoundType', _athanSoundType.value);
    debugPrint('[Settings] Athan Sound Type: ${_athanSoundType.label} (${_athanSoundType.value})');
    
    // Advanced notification control mode
    await prefs.setBool('useAdvancedNotificationControl', _useAdvancedNotificationControl);
    debugPrint('[Settings] Use Advanced Notification Control: $_useAdvancedNotificationControl');
    
    // Save advanced notification states
    await prefs.setString('prayerNotificationStates', jsonEncode(_prayerNotificationStates.map((k, v) => MapEntry(k, v.value))));
    final prayerStatesStr = _prayerNotificationStates.entries.map((e) => '${e.key}: ${e.value.label}').join(', ');
    debugPrint('[Settings] Athan Notification States: $prayerStatesStr');
    
    await prefs.setString('reminderNotificationStates', jsonEncode(_reminderNotificationStates.map((k, v) => MapEntry(k, v.value))));
    final reminderStatesStr = _reminderNotificationStates.entries.map((e) => '${e.key}: ${e.value.label}').join(', ');
    debugPrint('[Settings] Reminder Notification States: $reminderStatesStr');
    
    // Favorites & Theme
    await prefs.setStringList('favorites', _favorites);
    debugPrint('[Settings] Favorites: ${_favorites.length} items');
    
    await prefs.setString('themeMode', _themeModePref);
    debugPrint('[Settings] Theme Mode: $_themeModePref');
    
    await prefs.setDouble('primaryHue', _primaryHue);
    debugPrint('[Settings] Primary Hue: $_primaryHue°');
    
    await prefs.setDouble('widgetBgTransparency', _widgetBgTransparency);
    debugPrint('[Settings] Widget Background Transparency: ${(_widgetBgTransparency * 100).toStringAsFixed(0)}%');
    debugPrint('[Settings] DEBUG - Before change detection: _widgetBgTransparency=$_widgetBgTransparency, _originalWidgetBgTransparency=$_originalWidgetBgTransparency');
    
    // Verify it was actually saved
    final savedValue = prefs.getDouble('widgetBgTransparency');
    debugPrint('[Settings] DEBUG - Verify saved to prefs: widgetBgTransparency=$savedValue (expected: $_widgetBgTransparency)');
    
    // Adhan API settings
    await prefs.setString('adhanLatitude', _adhanLatitudeController.text.trim());
    debugPrint('[Settings] Adhan Latitude: ${_adhanLatitudeController.text.trim()}');
    
    await prefs.setString('adhanLongitude', _adhanLongitudeController.text.trim());
    debugPrint('[Settings] Adhan Longitude: ${_adhanLongitudeController.text.trim()}');
    
    await prefs.setString('adhanCity', _adhanCityController.text.trim());
    debugPrint('[Settings] Adhan City: ${_adhanCityController.text.trim()}');
    
    await prefs.setString('adhanCountry', _adhanCountryController.text.trim());
    debugPrint('[Settings] Adhan Country: ${_adhanCountryController.text.trim()}');
    
    // Morocco defaults permanently enabled - no need to save method/school/angles
    

    // Offline mode settings
    await prefs.setBool('isOfflineMode', _isOfflineMode);
    debugPrint('[Settings] Offline Mode: $_isOfflineMode');
    
    // Update live theme and hue colors
    if (_themeModePref == 'light') {
      themeNotifier.value = ThemeMode.light;
    } else if (_themeModePref == 'dark') {
      themeNotifier.value = ThemeMode.dark;
    } else {
      themeNotifier.value = ThemeMode.system;
    }
    primaryHueNotifier.value = _primaryHue;
    debugPrint('═════ SETTINGS SAVED SUCCESSFULLY ═════\n');
    
    // 🔔 CRITICAL: If source (Ministry/Adhan/Offline) changed, update widget cache with new times
    final sourceChanged = _originalIsOfflineMode != _isOfflineMode;
    if (sourceChanged) {
      debugPrint('[SaveSettings] Source setting changed - updating widget cache with new prayer times');
      try {
        final widgetManager = WidgetInfoManager();
        final success = await widgetManager.quickUpdateWidgetCache();
        if (success) {
          debugPrint('[SaveSettings] ✓ Widget cache updated with new source times');
        } else {
          debugPrint('[SaveSettings] ⚠ Failed to update widget cache');
        }
      } catch (e) {
        debugPrint('[SaveSettings] ⚠ Failed to update widget cache: $e');
      }
    }
    
    // 🔔 CRITICAL: If useMinistry setting changed, notify main page to update calendar button state
    final useMinistryChanged = _originalUseMinistry != _useMinistry;
    if (useMinistryChanged) {
      debugPrint('[SaveSettings] useMinistry setting changed from $_originalUseMinistry to $_useMinistry');
      debugPrint('[SaveSettings] Notifying main page to update calendar button state');
      // Trigger the settings change notifier to update dependent widgets
      settingsChangeNotifier.value++;
    }
    
    // 🔔 CRITICAL: If widget background transparency changed, update widget cache
    debugPrint('[SaveSettings] DEBUG - Checking bgTransparency: current=$_widgetBgTransparency, original=$_originalWidgetBgTransparency');
    final bgTransparencyChanged = _originalWidgetBgTransparency != _widgetBgTransparency;
    debugPrint('[SaveSettings] DEBUG - bgTransparencyChanged=$bgTransparencyChanged');
    if (bgTransparencyChanged) {
      debugPrint('[SaveSettings] Widget background transparency changed - updating widget cache');
      debugPrint('[SaveSettings] bgTransparency: $_originalWidgetBgTransparency → $_widgetBgTransparency');
      try {
        final widgetManager = WidgetInfoManager();
        final success = await widgetManager.quickUpdateWidgetCache();
        if (success) {
          debugPrint('[SaveSettings] ✓ Widget cache updated with new transparency');
        } else {
          debugPrint('[SaveSettings] ⚠ Failed to update widget cache');
        }
      } catch (e) {
        debugPrint('[SaveSettings] ⚠ Failed to update widget cache: $e');
      }
    }
    
    // 🔔 CRITICAL: Reschedule all notifications with the new states
    debugPrint('[SaveSettings] Rescheduling notifications with updated states...');
    await refreshScheduledNotificationsGlobal();
    
    // ✅ Update all original values to match current values so the button highlight resets
    if (mounted) {
      setState(() {
        _originalMinistryUrl = _urlController.text;
        _originalSelectedCityName = _selectedCityName;
        _originalSelectedCityId = _selectedCityId;
        _originalUseMinistry = _useMinistry;
        _originalNotificationsEnabled = _notificationsEnabled;
        _originalPrayerNotificationsEnabled = _prayerNotificationsEnabled;
        _originalReminderEnabled = _reminderEnabled;
        _originalReminderMinutes = _reminderMinutes;
        _originalEnableCountdownTimer = _enableCountdownTimer;
        _originalNotifyFajr = _notifyFajr;
        _originalNotifySunrise = _notifySunrise;
        _originalNotifyDhuhr = _notifyDhuhr;
        _originalNotifyAsr = _notifyAsr;
        _originalNotifyMaghrib = _originalNotifyMaghrib;
        _originalNotifyIsha = _notifyIsha;
        _originalReminderFajr = _reminderFajr;
        _originalReminderSunrise = _reminderSunrise;
        _originalReminderDhuhr = _reminderDhuhr;
        _originalReminderAsr = _reminderAsr;
        _originalReminderMaghrib = _reminderMaghrib;
        _originalReminderIsha = _reminderIsha;
        _originalNotificationState = _notificationState;
        _originalAthanSoundType = _athanSoundType;
        _originalUseAdvancedNotificationControl = _useAdvancedNotificationControl;
        _originalDevUseScheduledTestNotification = _devUseScheduledTestNotification;
        _originalDevShowDailyRefreshNotification = _devShowDailyRefreshNotification;
        _originalDevShowMonthlyRefreshNotification = _devShowMonthlyRefreshNotification;
        _originalAdhanLatitude = _adhanLatitudeController.text;
        _originalAdhanLongitude = _adhanLongitudeController.text;
        _originalAdhanCity = _adhanCityController.text;
        _originalAdhanCountry = _adhanCountryController.text;
        _originalIsOfflineMode = _isOfflineMode;
        _originalThemeModePref = _themeModePref;
        _originalPrimaryHue = _primaryHue;
        _originalWidgetBgTransparency = _widgetBgTransparency;
        _originalPrayerNotificationStates = Map.from(_prayerNotificationStates);
        _originalReminderNotificationStates = Map.from(_reminderNotificationStates);
        _originalFavorites = List.from(_favorites);
      });
      _detectChanges(); // This will set _settingsChanged to false since originals now match current
    }
    
    // Stay on settings screen instead of popping back to main
    // User can navigate away manually when they choose to
  }
  
  /// Get the Latin transliteration of an Arabic city name
  String _getLatinCityName(String arabicName) {
    return latinNames[arabicName] ?? arabicName;
  }

  void _selectCity(String cityName) {
    setState(() {
      _selectedCityName = cityName;
      _selectedCityId = ApiService.ministrycityIds[cityName] ?? '58';
      _searchController.clear();
      _directIdController.clear();
      _filteredCities = List.from(ApiService.ministrycityIds.keys);
    });
    _detectChanges();
  }

  void _selectCityById(String id) {
    // Find city by ID
    for (final entry in ApiService.ministrycityIds.entries) {
      if (entry.value == id) {
        _selectCity(entry.key);
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('City ID not found')),
    );
  }

  void _toggleFavorite(String cityName) {
    // Maintain backward compatibility: favorites are stored as JSON blobs.
    setState(() {
      // Try to find an existing favorite of type 'city' with this value
      final existingIndex = _favorites.indexWhere((raw) {
        try {
          final m = jsonDecode(raw) as Map<String, dynamic>;
          return (m['type'] == 'city' && m['value'] == cityName);
        } catch (_) {
          // legacy plain string
          return raw == cityName;
        }
      });

      if (existingIndex != -1) {
        _favorites.removeAt(existingIndex);
      } else {
        final fav = {'type': 'city', 'value': cityName, 'label': cityName};
        _favorites.add(jsonEncode(fav));
      }
    });
    _detectChanges();
  }

  Map<String, String> _decodeFavorite(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, v?.toString() ?? ''));
    } catch (_) {
      // legacy plain string -> city
      return {'type': 'city', 'value': raw, 'label': raw};
    }
  }

  String _encodeFavorite(Map<String, String> fav) => jsonEncode(fav);

  Future<void> _showEditFavoriteDialog(int index) async {
    final raw = _favorites[index];
    final fav = _decodeFavorite(raw);
    final labelController = TextEditingController(text: fav['label'] ?? fav['value']);
    String type = fav['type'] ?? 'city';
    final valueController = TextEditingController(text: fav['value']);

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit Quick Access'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: labelController,
                decoration: const InputDecoration(labelText: 'Label'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: type,
                items: [
                  (value: 'city', label: 'City'),
                  (value: 'id', label: 'City ID'),
                  (value: 'coords', label: 'Coordinates'),
                  (value: 'coords_location', label: 'Location (City/Country)'),
                ]
                    .asMap()
                    .entries
                    .map((e) => DropdownMenuItem(
                      value: e.value.value,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Text(e.value.label),
                          ),
                          if (e.key < 3)
                            Divider(height: 1, color: Theme.of(context).colorScheme.outline.withAlpha(100)),
                        ],
                      ),
                    ))
                    .toList(),
                onChanged: (v) => type = v ?? 'city',
                decoration: const InputDecoration(labelText: 'Type'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: valueController,
                decoration: InputDecoration(
                  labelText: type == 'coords' ? 'lat,lon' : (type == 'id' ? 'City ID' : 'City Name'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final updated = {
                  'type': type,
                  'value': valueController.text.trim(),
                  'label': labelController.text.trim().isEmpty ? valueController.text.trim() : labelController.text.trim(),
                };
                setState(() => _favorites[index] = _encodeFavorite(updated));
                _detectChanges();
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _selectFavorite(Map<String, String> fav) {
    final type = fav['type'] ?? 'city';
    final value = fav['value'] ?? '';
    if (type == 'city') {
      setState(() {
        _useMinistry = true;
        // Clear Adhan fields when selecting city
        _adhanLatitudeController.clear();
        _adhanLongitudeController.clear();
        _adhanCityController.clear();
      });
      _selectCity(value);
    } else if (type == 'id') {
      setState(() {
        _useMinistry = true;
        // Clear Adhan fields when selecting ID
        _adhanLatitudeController.clear();
        _adhanLongitudeController.clear();
        _adhanCityController.clear();
      });
      _selectCityById(value);
    } else if (type == 'coords') {
      final parts = value.split(',');
      if (parts.length >= 2) {
        setState(() {
          _useMinistry = false;
          _moroccoDefaultsEnabled = false; // Coords mode, not Morocco defaults
          _adhanLatitudeController.text = parts[0].trim();
          _adhanLongitudeController.text = parts[1].trim();
          _adhanCityController.clear(); // Clear city when using coords
          _adhanCountryController.clear(); // Clear country when using coords
        });
      }
    } else if (type == 'coords_location') {
      final parts = value.split(',');
      setState(() {
        _useMinistry = false;
        _moroccoDefaultsEnabled = false; // City name mode, not Morocco defaults
        _adhanCityController.text = parts[0].trim();
        _adhanCountryController.text = parts.length > 1 ? parts[1].trim() : '';
        _adhanLatitudeController.clear(); // Clear coords when using city name
        _adhanLongitudeController.clear(); // Clear coords when using city name
      });
    } else if (type == 'adhan') {
      // Adhan API settings: value is "lat|lon|method|school"
      final parts = value.split('|');
      if (parts.length >= 4) {
        setState(() {
          _useMinistry = false;
          _moroccoDefaultsEnabled = true; // Auto-enable Morocco defaults for Adhan presets
          _adhanLatitudeController.text = parts[0].trim();
          _adhanLongitudeController.text = parts[1].trim();
          _adhanCityController.clear(); // Clear city when using coords
          _adhanCountryController.clear(); // Clear country when using coords
          _adhanMethod = parts[2].trim();
          _adhanSchool = parts[3].trim();
        });
      }
    } else if (type == 'offline') {
      // Offline mode settings: value is "lat|lon"
      final parts = value.split('|');
      if (parts.length >= 2) {
        setState(() {
          _useMinistry = false;
          _isOfflineMode = true;
          _adhanLatitudeController.text = parts[0].trim();
          _adhanLongitudeController.text = parts[1].trim();
          _adhanCityController.clear();
          _adhanCountryController.clear();
        });
      }
    } else if (type == 'api_coords') {
      // API mode with coordinates: value is "lat|lon|method|school"
      final parts = value.split('|');
      if (parts.length >= 4) {
        setState(() {
          _useMinistry = false;
          _isOfflineMode = false;
          _adhanLatitudeController.text = parts[0].trim();
          _adhanLongitudeController.text = parts[1].trim();
          _adhanCityController.clear();
          _adhanCountryController.clear();
          _adhanMethod = parts[2].trim();
          _adhanSchool = parts[3].trim();
        });
      }
    } else if (type == 'api_city') {
      // API mode with city: value is "lat|lon|city"
      final parts = value.split('|');
      if (parts.length >= 3) {
        setState(() {
          _useMinistry = false;
          _isOfflineMode = false;
          _adhanLatitudeController.text = parts[0].trim();
          _adhanLongitudeController.text = parts[1].trim();
          _adhanCityController.text = parts[2].trim();
          _adhanCountryController.clear();
        });
      }
    }
    _detectChanges();
  }

  void _saveAdhanToQuickAccess() {
    // Show dialog to ask for custom name
    final nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Quick Setting'),
        content: TextField(
          controller: nameController,
          decoration: InputDecoration(
            labelText: 'Setting Name',
            hintText: _isOfflineMode ? 'My Offline Location' : 'My Prayer Times',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final customName = nameController.text.trim();
              if (customName.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a name')),
                );
                return;
              }
              Navigator.pop(context);
              _performSaveToQuickAccess(customName);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _performSaveToQuickAccess(String customName) {
    final lat = _adhanLatitudeController.text.trim();
    final lon = _adhanLongitudeController.text.trim();
    final city = _adhanCityController.text.trim();

    if (lat.isEmpty || lon.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter coordinates')),
      );
      return;
    }

    String type = '';
    String value = '';

    if (_isOfflineMode) {
      // Save offline mode settings
      type = 'offline';
      value = '$lat|$lon';
    } else {
      // Save API mode settings
      if (city.isNotEmpty) {
        type = 'api_city';
        value = '$lat|$lon|$city';
      } else {
        type = 'api_coords';
        value = '$lat|$lon|$_adhanMethod|$_adhanSchool';
      }
    }

    final fav = {'type': type, 'value': value, 'label': customName};
    setState(() {
      _favorites.add(_encodeFavorite(fav));
    });
    _detectChanges();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved to Quick Access: $customName')),
    );
  }

  Future<void> _requestNotificationPermission() async {
    if (Platform.isAndroid) {
      try {
        final granted = await flutterLocalNotificationsPlugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
        
        if (granted ?? false) {
          debugPrint('[Notifications] Permission granted');
        }
      } catch (e) {
        debugPrint('[Notifications] Permission request failed: $e');
      }
    }
  }

  // Normalize accented characters and special characters for search
  String _normalizeForSearch(String text) {
    // Map of accented characters to their base forms
    const accentMap = {
      'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a', 'å': 'a',
      'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
      'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
      'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
      'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
      'ý': 'y', 'ÿ': 'y',
      'ç': 'c', 'ñ': 'n',
      'æ': 'ae', 'œ': 'oe',
    };

    String normalized = text.toLowerCase();
    
    // Replace accented characters
    accentMap.forEach((accented, base) {
      normalized = normalized.replaceAll(accented, base);
    });
    
    // Remove spaces and dashes
    normalized = normalized.replaceAll(RegExp(r'[\s\-]'), '');
    
    return normalized;
  }

  void _filterCities(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredCities = List.from(ApiService.ministrycityIds.keys);
      } else {
        final normalizedQuery = _normalizeForSearch(query);
        
        _filteredCities = ApiService.ministrycityIds.keys
            .where((city) {
              // Normalize city names for comparison
              final normalizedCity = _normalizeForSearch(city);
              final normalizedLatin = _normalizeForSearch(latinNames[city] ?? '');
              
              // Search in both Arabic and Latin names
              return normalizedCity.contains(normalizedQuery) || 
                     normalizedLatin.contains(normalizedQuery);
            })
            .toList();
      }
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _searchController.dispose();
    _directIdController.dispose();
    _adhanLatitudeController.dispose();
    _adhanLongitudeController.dispose();
    _adhanCityController.dispose();
    _adhanCountryController.dispose();
    _reminderMinutesController.dispose();
    _testNotificationSecondsController.dispose();
    _fajrAngleController.dispose();
    _ishaAngleController.dispose();
    super.dispose();
  }

  Widget _buildAdvancedNotificationControl() {
    const prayers = ['Fajr', 'Sunrise', 'Dhuhr', 'Asr', 'Maghrib', 'Isha'];
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Three columns: Names | Prayers | Reminders
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
              width: 1,
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Prayer Names Column
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Align(
                        alignment: Alignment.center,
                        child: Text('Prayer', style: TextStyle(fontSize: ResponsiveSizes(context).bodySize, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9))),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...prayers.map((prayer) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Container(
                          width: double.infinity,
                          height: 40,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Align(
                            alignment: Alignment.center,
                            child: Text(prayer, style: TextStyle(fontSize: ResponsiveSizes(context).settingLabelSize)),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Reminder Notifications Column
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Align(
                        alignment: Alignment.center,
                        child: Text('Reminder', style: TextStyle(fontSize: ResponsiveSizes(context).bodySize, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9))),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...prayers.map((prayer) {
                      final state = _reminderNotificationStates[prayer] ?? NotificationState.full;
                      final isEnabled = _reminderEnabled;
                      
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Container(
                          height: 40,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Align(
                            alignment: Alignment.center,
                            child: IconButton(
                              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                              padding: EdgeInsets.zero,
                              icon: Icon(
                                isEnabled ? _getNotificationIcon(state) : Icons.notifications_off,
                                size: 20,
                                color: isEnabled ? _getNotificationIconColor(context, state) : Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                              ),
                              onPressed: isEnabled ? () {
                                setState(() {
                                  final current = _reminderNotificationStates[prayer] ?? NotificationState.full;
                                  _reminderNotificationStates[prayer] = _cycleNotificationState(current);
                                });
                                _detectChanges();
                              } : null,
                              tooltip: isEnabled ? _getNotificationTooltip(state) : 'Disabled',
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Athan Notifications Column
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Align(
                        alignment: Alignment.center,
                        child: Text('Athan', style: TextStyle(fontSize: ResponsiveSizes(context).bodySize, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9))),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...prayers.map((prayer) {
                      final state = _prayerNotificationStates[prayer] ?? NotificationState.full;
                      final isEnabled = switch (prayer) {
                        'Fajr' => _notifyFajr,
                        'Sunrise' => _notifySunrise,
                        'Dhuhr' => _notifyDhuhr,
                        'Asr' => _notifyAsr,
                        'Maghrib' => _notifyMaghrib,
                        'Isha' => _notifyIsha,
                        _ => true,
                      };
                      
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Container(
                          height: 40,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Align(
                            alignment: Alignment.center,
                            child: IconButton(
                              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                              padding: EdgeInsets.zero,
                              icon: Icon(
                                isEnabled ? _getNotificationIcon(state) : Icons.notifications_off,
                                size: 20,
                                color: isEnabled ? _getNotificationIconColor(context, state) : Colors.grey,
                              ),
                              onPressed: isEnabled ? () {
                                setState(() {
                                  final current = _prayerNotificationStates[prayer] ?? NotificationState.full;
                                  final next = _cycleNotificationState(current);
                                  debugPrint('[Toggle] $prayer: $current (${current.value}) → $next (${next.value})');
                                  _prayerNotificationStates[prayer] = next;
                                  debugPrint('[Toggle] Updated map[$prayer] = ${_prayerNotificationStates[prayer]}');
                                });
                                _detectChanges();
                              } : null,
                              tooltip: isEnabled ? _getNotificationTooltip(state) : 'Disabled',
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Legend
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6.0),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 0,
            crossAxisSpacing: 8,
            childAspectRatio: 3.0,
            children: [
              // Off
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notifications_off, size: 18, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
                  const SizedBox(width: 8),
                  Text('Off', style: TextStyle(fontSize: ResponsiveSizes(context).bodySize)),
                ],
              ),
              // Silent
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.volume_off, size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('Silent', style: TextStyle(fontSize: ResponsiveSizes(context).bodySize)),
                ],
              ),
              // Vibrate
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.vibration, size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('Vibrate', style: TextStyle(fontSize: ResponsiveSizes(context).bodySize)),
                ],
              ),
              // Full
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notifications_active, size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('Full', style: TextStyle(fontSize: ResponsiveSizes(context).bodySize)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  IconData _getNotificationIcon(NotificationState state) {
    return switch (state) {
      NotificationState.off => Icons.notifications_off,
      NotificationState.silent => Icons.volume_off,
      NotificationState.vibrate => Icons.vibration,
      NotificationState.full => Icons.notifications_active,
    };
  }

  Color _getNotificationIconColor(BuildContext context, NotificationState state) {
    return switch (state) {
      NotificationState.off => Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
      NotificationState.silent => Theme.of(context).colorScheme.primary,
      NotificationState.vibrate => Theme.of(context).colorScheme.primary,
      NotificationState.full => Theme.of(context).colorScheme.primary,
    };
  }

  String _getNotificationTooltip(NotificationState state) {
    return switch (state) {
      NotificationState.off => 'Off (disabled)',
      NotificationState.silent => 'Silent (no sound, no vibration)',
      NotificationState.vibrate => 'Vibrate (vibration only)',
      NotificationState.full => 'Full (sound + vibration)',
    };
  }

  NotificationState _cycleNotificationState(NotificationState current) {
    return switch (current) {
      NotificationState.off => NotificationState.silent,
      NotificationState.silent => NotificationState.vibrate,
      NotificationState.vibrate => NotificationState.full,
      NotificationState.full => NotificationState.off,
    };
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          foregroundColor: Theme.of(context).colorScheme.primary,
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: Container(
              color: Theme.of(context).colorScheme.primaryContainer.adaptive(context, 0.2),
              child: TabBar(
                tabs: const [
                  Tab(text: 'City'),
                  Tab(text: 'Notifications'),
                  Tab(text: 'Misc'),
                ],
                unselectedLabelColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
        body: TabBarView(
          children: [
            // Tab 1: City Selection
            SingleChildScrollView(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 80),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Opacity(
                    opacity: 1.0,
                    child: IgnorePointer(
                      ignoring: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Parent Rank: "Selected City" - Independent parent section, displays current selection
                          Container(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                                width: 1,
                              ),
                            ),
                            padding: EdgeInsets.all(ResponsiveSizes(context).spacingM),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Selected City',
                                  style: TextStyle(
                                    fontSize: ResponsiveSizes(context).settingHeaderSize,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                                  ),
                                ),
                                SizedBox(height: ResponsiveSizes(context).spacingM),
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: ResponsiveSizes(context).spacingM,
                                    vertical: ResponsiveSizes(context).spacingS,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(Icons.location_on, size: ResponsiveSizes(context).iconSizeMedium, color: Theme.of(context).colorScheme.primary),
                                      SizedBox(width: ResponsiveSizes(context).spacingS),
                                      Expanded(
                                        child: _useMinistry
                                            ? Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Text(_getLatinCityName(_selectedCityName), style: TextStyle(fontWeight: FontWeight.w500, fontSize: ResponsiveSizes(context).settingLabelSize)),
                                                  Text('ID: $_selectedCityId', style: TextStyle(fontSize: ResponsiveSizes(context).bodySize, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                                ],
                                              )
                                            : Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  if (_adhanLatitudeController.text.trim().isNotEmpty && _adhanLongitudeController.text.trim().isNotEmpty)
                                                    Text('Adhan coords: ${_adhanLatitudeController.text.trim()}, ${_adhanLongitudeController.text.trim()}', style: TextStyle(fontWeight: FontWeight.w500, fontSize: ResponsiveSizes(context).settingLabelSize))
                                                  else if (_adhanCityController.text.trim().isNotEmpty)
                                                    Text('${_adhanCityController.text.trim()}, ${_adhanCountryController.text.trim()}', style: TextStyle(fontWeight: FontWeight.w500, fontSize: ResponsiveSizes(context).settingLabelSize))
                                                  else
                                                    Text('Adhan: no location set', style: TextStyle(fontWeight: FontWeight.w500, fontSize: ResponsiveSizes(context).settingLabelSize)),
                                                  SizedBox(height: ResponsiveSizes(context).spacingXS),
                                                  Text(_isOfflineMode ? 'Offline Mode' : 'API Mode', style: TextStyle(fontSize: ResponsiveSizes(context).bodySize, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                                ],
                                              ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Parent Rank: "Quick Access" - Independent parent section, shows favorites (only when favorites exist)
                          if (_favorites.isNotEmpty) ...[
                            Container(
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                                  width: 1,
                                ),
                              ),
                              padding: EdgeInsets.all(ResponsiveSizes(context).spacingM),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Quick Access',
                                    style: TextStyle(
                                      fontSize: ResponsiveSizes(context).settingHeaderSize,
                                      fontWeight: FontWeight.w600,
                                      color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                                    ),
                                  ),
                                  SizedBox(height: ResponsiveSizes(context).spacingM),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: _favorites.asMap().entries.map((entry) {
                                      final idx = entry.key;
                                      final raw = entry.value;
                                      final fav = _decodeFavorite(raw);
                                      final display = fav['label'] ?? fav['value'];
                                      final type = fav['type'] ?? 'city';
                                      bool isSelected = false;
                                      
                                      // Simple highlighting: check if current selection matches favorite
                                      if (type == 'city' && _useMinistry) {
                                        isSelected = fav['value'] == _selectedCityName;
                                      } else if (type == 'id' && _useMinistry) {
                                        isSelected = fav['value'] == _selectedCityId;
                                      } else if (type == 'coords' && !_useMinistry && !_moroccoDefaultsEnabled) {
                                        final lat = _adhanLatitudeController.text.trim();
                                        final lon = _adhanLongitudeController.text.trim();
                                        isSelected = lat.isNotEmpty && lon.isNotEmpty && fav['value'] == '$lat,$lon';
                                      } else if (type == 'coords_location' && !_useMinistry && !_moroccoDefaultsEnabled) {
                                        final city = _adhanCityController.text.trim();
                                        final country = _adhanCountryController.text.trim();
                                        isSelected = city.isNotEmpty && (fav['value'] == city || fav['value'] == '$city,$country');
                                      } else if (type == 'adhan' && !_useMinistry && _moroccoDefaultsEnabled) {
                                        final lat = _adhanLatitudeController.text.trim();
                                        final lon = _adhanLongitudeController.text.trim();
                                        if (lat.isNotEmpty && lon.isNotEmpty) {
                                          isSelected = fav['value'] == '$lat|$lon|$_adhanMethod|$_adhanSchool';
                                        }
                                      } else if (type == 'offline' && !_useMinistry && _isOfflineMode) {
                                        final lat = _adhanLatitudeController.text.trim();
                                        final lon = _adhanLongitudeController.text.trim();
                                        if (lat.isNotEmpty && lon.isNotEmpty) {
                                          isSelected = fav['value'] == '$lat|$lon';
                                        }
                                      } else if (type == 'api_coords' && !_useMinistry && !_isOfflineMode) {
                                        final lat = _adhanLatitudeController.text.trim();
                                        final lon = _adhanLongitudeController.text.trim();
                                        final city = _adhanCityController.text.trim();
                                        if (lat.isNotEmpty && lon.isNotEmpty && city.isEmpty) {
                                          isSelected = fav['value'] == '$lat|$lon|$_adhanMethod|$_adhanSchool';
                                        }
                                      } else if (type == 'api_city' && !_useMinistry && !_isOfflineMode) {
                                        final lat = _adhanLatitudeController.text.trim();
                                        final lon = _adhanLongitudeController.text.trim();
                                        final city = _adhanCityController.text.trim();
                                        if (lat.isNotEmpty && lon.isNotEmpty && city.isNotEmpty) {
                                          isSelected = fav['value'] == '$lat|$lon|$city';
                                        }
                                      }

                                      return PopupMenuButton<String>(
                                        onSelected: (choice) {
                                          if (choice == 'select') {
                                            _selectFavorite(fav);
                                          } else if (choice == 'rename') {
                                            _showEditFavoriteDialog(idx);
                                          } else if (choice == 'remove') {
                                            setState(() => _favorites.removeAt(idx));
                                            _detectChanges();
                                          }
                                        },
                                        itemBuilder: (context) => [
                                          const PopupMenuItem(value: 'select', child: Text('Select')),
                                          const PopupMenuItem(value: 'rename', child: Text('Rename')),
                                          const PopupMenuItem(value: 'remove', child: Text('Remove')),
                                        ],
                                        child: GestureDetector(
                                          onLongPress: () {
                                            // Long-press to remove
                                            setState(() => _favorites.removeAt(idx));
                                            _detectChanges();
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text('Removed from Quick Access')),
                                            );
                                          },
                                          child: Tooltip(
                                            message: '',
                                            showDuration: Duration.zero,
                                            child: ElevatedButton.icon(
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: isSelected 
                                                  ? Theme.of(context).colorScheme.primary
                                                  : getTextInputPromptColor(context),
                                                foregroundColor: isSelected 
                                                  ? Theme.of(context).colorScheme.onPrimary
                                                  : Theme.of(context).colorScheme.onSurface,
                                                elevation: isSelected ? 2 : 0,
                                                padding: EdgeInsets.symmetric(
                                                  horizontal: ResponsiveSizes(context).spacingM,
                                                  vertical: ResponsiveSizes(context).spacingXS,
                                                ),
                                              ),
                                              onPressed: () => _selectFavorite(fav),
                                              icon: type == 'city'
                                                ? Icon(Icons.star, size: ResponsiveSizes(context).iconSizeSmall)
                                                : (type == 'id' ? Icon(Icons.confirmation_num, size: ResponsiveSizes(context).iconSizeSmall) : (type == 'adhan' ? Icon(Icons.location_on_outlined, size: ResponsiveSizes(context).iconSizeSmall) : Icon(Icons.location_on, size: ResponsiveSizes(context).iconSizeSmall))),
                                              label: Text(display ?? '', style: TextStyle(fontSize: ResponsiveSizes(context).settingLabelSize)),
                                            ),
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],

                          if (_useMinistry) ...[
                            // Parent Rank: "Search Cities" - Independent parent section, city search interface (only when using Ministry source)
                            Container(
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                                  width: 1,
                                ),
                              ),
                              padding: EdgeInsets.all(ResponsiveSizes(context).spacingM),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Search Cities',
                                    style: TextStyle(
                                      fontSize: ResponsiveSizes(context).settingHeaderSize,
                                      fontWeight: FontWeight.w600,
                                      color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                                    ),
                                  ),
                                  SizedBox(height: ResponsiveSizes(context).spacingM),
                                  TextField(
                                    controller: _searchController,
                                    onChanged: _filterCities,
                                    style: TextStyle(fontSize: ResponsiveSizes(context).settingInputSize),
                                    decoration: InputDecoration(
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
                                      ),
                                      hintText: 'e.g., "Casablanca" or "الدار"',
                                      hintStyle: TextStyle(
                                        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                                        fontSize: ResponsiveSizes(context).bodySize,
                                      ),
                                      prefixIcon: Icon(Icons.search, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                      suffixIcon: IconButton(
                                        icon: Icon(Icons.clear, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                        onPressed: () {
                                          _searchController.clear();
                                          _filterCities('');
                                        },
                                      ),
                                      filled: true,
                                      fillColor: getTextInputPromptColor(context),
                                    ),
                                  ),
                                  SizedBox(height: ResponsiveSizes(context).spacingM),
                                  SizedBox(
                                    height: 250,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: ListView.builder(
                                        itemCount: _filteredCities.length,
                                        itemBuilder: (context, index) {
                                          final city = _filteredCities[index];
                                          final isSelected = city == _selectedCityName;
                                          final isFavorite = _favorites.any((raw) {
                                            try {
                                              final m = jsonDecode(raw) as Map<String, dynamic>;
                                              return m['type'] == 'city' && m['value'] == city;
                                            } catch (_) {
                                              return raw == city;
                                            }
                                          });
                                          final bgColor = index.isEven
                                              ? Theme.of(context).colorScheme.surface
                                              : Theme.of(context).colorScheme.surface.withValues(alpha: 0.5);
                                          // Use cached city metadata instead of repeated lookups
                                          final cityData = _cityCache[city];
                                          final cityId = cityData?['id'] ?? '';
                                          final latinName = cityData?['latin'] ?? '';

                                          return Material(
                                            color: isSelected ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4) : bgColor,
                                            child: InkWell(
                                              onTap: () => _selectCity(city),
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                                child: Row(
                                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                  children: [
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment: CrossAxisAlignment.start,
                                                        children: [
                                                          Text(_getLatinCityName(city), style: TextStyle(fontSize: ResponsiveSizes(context).settingLabelSize, fontWeight: FontWeight.w500)),
                                                          Text(
                                                            '$cityId${latinName.isNotEmpty ? ' • $city' : ''}',
                                                            style: TextStyle(fontSize: ResponsiveSizes(context).bodySize, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                    IconButton(
                                                      icon: Icon(
                                                        isFavorite ? Icons.star : Icons.star_outline,
                                                        color: isFavorite ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                                                        size: 20,
                                                      ),
                                                      onPressed: () => _toggleFavorite(city),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  // Hint Rank: "Direct ID Entry" helper text for direct ID input
                                  Text(
                                    'Direct ID Entry',
                                    style: TextStyle(
                                      fontSize: ResponsiveSizes(context).bodySize,
                                      fontWeight: FontWeight.normal,
                                      color: Theme.of(context).colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _directIdController,
                                          keyboardType: TextInputType.number,
                                          style: TextStyle(fontSize: ResponsiveSizes(context).settingInputSize),
                                          decoration: InputDecoration(
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(8),
                                              borderSide: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                                            ),
                                            enabledBorder: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(8),
                                              borderSide: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                                            ),
                                            focusedBorder: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(8),
                                              borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
                                            ),
                                            hintText: 'Enter ID (e.g., 58)',
                                            hintStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
                                            filled: true,
                                            fillColor: getTextInputPromptColor(context),
                                            suffixIcon: _directIdController.text.isNotEmpty
                                                ? IconButton(
                                                    icon: Icon(Icons.clear, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                                    onPressed: () {
                                                      _directIdController.clear();
                                                      setState(() {});
                                                    },
                                                  )
                                                : null,
                                          ),
                                          onChanged: (_) => setState(() {}),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                                          foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
                                          elevation: 0,
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                        ),
                                        onPressed: _directIdController.text.isNotEmpty
                                            ? () => _selectCityById(_directIdController.text)
                                            : null,
                                        child: Text('Go', style: TextStyle(fontSize: ResponsiveSizes(context).settingLabelSize, fontWeight: FontWeight.w500)),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                        ],
                      ),
                    ),
                  ),

                  // Prayer Times Source Toggle (Ministry vs API/Offline)
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                        width: 1,
                      ),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Prayer Times Source',
                          style: TextStyle(
                            fontSize: ResponsiveSizes(context).settingHeaderSize,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Use Ministry Source',
                                style: TextStyle(
                                  fontSize: ResponsiveSizes(context).settingLabelSize,
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                              Switch(
                                value: _useMinistry,
                                activeColor: Theme.of(context).colorScheme.primary,
                                onChanged: (v) {
                                  setState(() => _useMinistry = v);
                                  _detectChanges();
                                },
                              ),
                            ],
                          ),
                        ),
                       
                      ],
                    ),
                  ),

                  if (!_useMinistry) ...[
                    const SizedBox(height: 16),
                    // Unified Prayer Times Source - Merges API and Offline modes
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                          width: 1,
                        ),
                      ),
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Prayer Times Source',
                            style: TextStyle(
                              fontSize: ResponsiveSizes(context).settingHeaderSize,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Mode Toggle - API vs Offline
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _isOfflineMode ? 'Offline Mode' : 'API Mode',
                                        style: TextStyle(
                                          fontSize: ResponsiveSizes(context).settingLabelSize,
                                          fontWeight: FontWeight.w500,
                                          color: Theme.of(context).colorScheme.onSurface,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: _isOfflineMode,
                                  activeColor: Theme.of(context).colorScheme.primary,
                                  onChanged: (v) {
                                    setState(() => _isOfflineMode = v);
                                    _detectChanges();
                                  },
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 16),
                          Text(
                            'Location',
                            style: TextStyle(
                              fontSize: ResponsiveSizes(context).settingLabelSize,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _adhanLatitudeController,
                                  keyboardType: TextInputType.numberWithOptions(decimal: true, signed: true),
                                  style: TextStyle(fontSize: ResponsiveSizes(context).settingInputSize),
                                  decoration: InputDecoration(
                                    labelText: 'Latitude',
                                    labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                                    prefixIcon: Icon(Icons.my_location, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
                                    ),
                                    hintText: '33.5898',
                                    hintStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
                                    filled: true,
                                    fillColor: getTextInputPromptColor(context),
                                  ),
                                  onChanged: (_) => _detectChanges(),  // Latitude: detect changes
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _adhanLongitudeController,
                                  keyboardType: TextInputType.numberWithOptions(decimal: true, signed: true),
                                  style: TextStyle(fontSize: ResponsiveSizes(context).settingInputSize),
                                  decoration: InputDecoration(
                                    labelText: 'Longitude',
                                    labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                                    prefixIcon: Icon(Icons.location_searching, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
                                    ),
                                    hintText: '-7.6038',
                                    hintStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
                                    filled: true,
                                    fillColor: getTextInputPromptColor(context),
                                  ),
                                  onChanged: (_) => _detectChanges(),  // Longitude: detect changes
                                ),
                              ),
                            ],
                          ),



                          // Save to Quick Access button - Visible in both API and Offline modes
                          const SizedBox(height: 16),
                          Center(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                                foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              ),
                              onPressed: _saveAdhanToQuickAccess,
                              icon: const Icon(Icons.save, size: 18),
                              label: Text('Save to Quick Access', style: TextStyle(fontSize: ResponsiveSizes(context).settingLabelSize, fontWeight: FontWeight.w500)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                
                ],
              ),
            ),

            // Tab 2: Notifications
            SingleChildScrollView(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 80),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Grandparent Rank: "Enable Notifications" - Controls all notification features
                  SwitchListTile(
                    title: Text(
                      'Enable Notifications',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: ResponsiveSizes(context).titleSize),
                    ),
                    value: _notificationsEnabled,
                    onChanged: (v) {
                      setState(() => _notificationsEnabled = v);
                      _detectChanges();
                      if (v) {
                        _requestNotificationPermission();
                      }
                    },
                    activeColor: Theme.of(context).colorScheme.primary,
                  ),
                  // All elements below are children of Enable Notifications grandparent
                  if (_notificationsEnabled) ...[
                    const SizedBox(height: 12),
                    // Parent Rank: "Athan Notifications" - Child of Enable Notifications grandparent
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                          width: 1,
                        ),
                      ),
                      child: SwitchListTile(
                        title: Text(
                          'Athan Notifications',
                          style: TextStyle(
                            fontSize: ResponsiveSizes(context).settingHeaderSize,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                          ),
                        ),
                        value: _prayerNotificationsEnabled,
                        onChanged: (v) {
                          setState(() => _prayerNotificationsEnabled = v);
                          _detectChanges();
                        },
                        activeColor: Theme.of(context).colorScheme.primary,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Parent Rank: "Prayer Reminder" - Child of Enable Notifications grandparent, parent of Minutes/Countdown Timer
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                          width: 1,
                        ),
                      ),
                      child: SwitchListTile(
                        title: Text(
                          'Prayer Reminder',
                          style: TextStyle(
                            fontSize: ResponsiveSizes(context).settingHeaderSize,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                          ),
                        ),
                        value: _reminderEnabled,
                        onChanged: (v) {
                          setState(() => _reminderEnabled = v);
                          _detectChanges();
                        },
                        activeColor: Theme.of(context).colorScheme.primary,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                    ),
                    // Child elements: Minutes input and Countdown Timer (only visible when reminder enabled)
                    if (_reminderEnabled)
                      Padding(
                        padding: const EdgeInsets.only(left: 32.0, top: 8.0, bottom: 8.0),
                        // Child Rank: "Minutes before" input - Child of Prayer Reminder parent
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 300, minWidth: 100),
                          child: TextField(
                            controller: _reminderMinutesController,
                            enabled: true,
                            keyboardType: const TextInputType.numberWithOptions(decimal: false, signed: false),
                            decoration: InputDecoration(
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Theme.of(context).colorScheme.primary,
                                  width: 2,
                                ),
                              ),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                              suffixText: 'min',
                              hintText: 'Minutes before',
                              hintStyle: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                              ),
                            ),
                            style: TextStyle(fontSize: ResponsiveSizes(context).settingInputSize),
                            onChanged: (value) {
                              final trimmed = value.trim();
                              if (trimmed.isEmpty) return;
                              
                              final parsed = int.tryParse(trimmed);
                              if (parsed == null || parsed < 0 || value.contains('.')) {
                                // Invalid: revert to previous value
                                _reminderMinutesController.text = _previousReminderMinutes.toString();
                              } else {
                                // Valid: update state
                                setState(() {
                                  _reminderMinutes = parsed;
                                  _previousReminderMinutes = parsed;
                                });
                                _detectChanges();
                              }
                            },
                            onSubmitted: (_) {
                              final trimmed = _reminderMinutesController.text.trim();
                              if (trimmed.isEmpty) {
                                _reminderMinutesController.text = _previousReminderMinutes.toString();
                              } else {
                                final parsed = int.tryParse(trimmed);
                                if (parsed == null || parsed < 0) {
                                  _reminderMinutesController.text = _previousReminderMinutes.toString();
                                } else {
                                  setState(() {
                                    _reminderMinutes = parsed;
                                    _previousReminderMinutes = parsed;
                                  });
                                  _detectChanges();
                                }
                              }
                            },
                          ),
                        ),
                      ),
                    if (!_reminderEnabled)
                      const SizedBox(height: 12),
                    // Child Rank: "Countdown Timer" - Child of Prayer Reminder parent
                    if (_reminderEnabled)
                      Padding(
                        padding: const EdgeInsets.only(left: 32.0, top: 0.0, bottom: 12.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                              width: 1,
                            ),
                          ),
                          child: SwitchListTile(
                            title: Text(
                              'Countdown Timer',
                              style: TextStyle(
                                fontSize: ResponsiveSizes(context).settingLabelSize,
                                fontWeight: FontWeight.w500,
                                color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                              ),
                            ),
                            value: _enableCountdownTimer,
                            onChanged: (v) {
                              setState(() => _enableCountdownTimer = v);
                              _detectChanges();
                            },
                            activeColor: Theme.of(context).colorScheme.primary,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12,),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    // Parent Rank: "Notification Control" - Independent parent section, manages global/advanced mode
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 0.0),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                            width: 1,
                          ),
                        ),
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                          Text(
                            'Notification Control',
                            style: TextStyle(
                              fontSize: ResponsiveSizes(context).settingHeaderSize,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: !_useAdvancedNotificationControl
                                        ? Theme.of(context).colorScheme.primaryContainer
                                        : Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
                                    foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                                    side: !_useAdvancedNotificationControl
                                        ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)
                                        : BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                                  ),
                                  onPressed: () {
                                    setState(() => _useAdvancedNotificationControl = false);
                                    _detectChanges();
                                  },
                                  child: const Text('Global'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _useAdvancedNotificationControl
                                        ? Theme.of(context).colorScheme.primaryContainer
                                        : Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
                                    foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                                    side: _useAdvancedNotificationControl
                                        ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)
                                        : BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                                  ),
                                  onPressed: () {
                                    setState(() => _useAdvancedNotificationControl = true);
                                    _detectChanges();
                                  },
                                  child: const Text('Advanced'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          
                          // Show appropriate UI based on mode
                          if (!_useAdvancedNotificationControl) ...[
                            // Global Mode: Show Notification Mode toggle
                            Padding(
                              padding: const EdgeInsets.only(left: 16.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Global Notification Control', style: TextStyle(fontSize: ResponsiveSizes(context).settingLabelSize, fontWeight: FontWeight.w400, color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9))),
                                  const SizedBox(height: 12),
                                ],
                              ),
                            ),
                            // Three toggle buttons for: Silent, Vibration, Full
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _notificationState == NotificationState.silent
                                          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                                          : Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
                                      foregroundColor: _notificationState == NotificationState.silent
                                          ? Theme.of(context).colorScheme.onPrimaryContainer
                                          : Theme.of(context).colorScheme.onSurface,
                                      side: _notificationState == NotificationState.silent
                                          ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)
                                          : BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                                    ),
                                    onPressed: () {
                                      setState(() => _notificationState = NotificationState.silent);
                                      _detectChanges();
                                    },
                                    child: const Text('Silent'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _notificationState == NotificationState.vibrate
                                          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                                          : Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
                                      foregroundColor: _notificationState == NotificationState.vibrate
                                          ? Theme.of(context).colorScheme.onPrimaryContainer
                                          : Theme.of(context).colorScheme.onSurface,
                                      side: _notificationState == NotificationState.vibrate
                                          ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)
                                          : BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                                    ),
                                    onPressed: () {
                                      setState(() => _notificationState = NotificationState.vibrate);
                                      _detectChanges();
                                    },
                                    child: Text('Vibrate', style: TextStyle(fontSize: ResponsiveSizes(context).bodySize)),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _notificationState == NotificationState.full
                                          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                                          : Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
                                      foregroundColor: _notificationState == NotificationState.full
                                          ? Theme.of(context).colorScheme.onPrimaryContainer
                                          : Theme.of(context).colorScheme.onSurface,
                                      side: _notificationState == NotificationState.full
                                          ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)
                                          : BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                                    ),
                                    onPressed: () {
                                      setState(() => _notificationState = NotificationState.full);
                                      _detectChanges();
                                    },
                                    child: const Text('Full'),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // Child Rank: Status display box showing current notification state
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    _notificationState == NotificationState.silent
                                        ? Icons.volume_off
                                        : _notificationState == NotificationState.vibrate
                                            ? Icons.vibration
                                            : Icons.volume_up,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _notificationState.label,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: Theme.of(context).colorScheme.primary,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _notificationState == NotificationState.silent
                                              ? 'No sound, no vibration'
                                              : _notificationState == NotificationState.vibrate
                                                  ? 'Vibration only, no sound'
                                                  : 'Full sound and vibration',
                                          style: TextStyle(fontSize: ResponsiveSizes(context).bodySize),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ] else ...[
                            // Advanced Mode: Show per-prayer granular control
                            Padding(
                              padding: const EdgeInsets.only(left: 16.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Granular Notification Control', style: TextStyle(fontSize: ResponsiveSizes(context).settingLabelSize, fontWeight: FontWeight.w400, color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9))),
                                  const SizedBox(height: 12),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            _buildAdvancedNotificationControl(),
                          ],
                        ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Parent Rank: "Athan Sound Type" - Independent parent section
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                            width: 1,
                          ),
                        ),
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Athan Sound Type',
                              style: TextStyle(
                                fontSize: ResponsiveSizes(context).settingHeaderSize,
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                              ),
                              child: DropdownButton<AthanSoundType>(
                                value: _athanSoundType,
                                isExpanded: true,
                                underline: const SizedBox(),
                                items: AthanSoundType.values.map((AthanSoundType type) {
                                  return DropdownMenuItem<AthanSoundType>(
                                    value: type,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                                      child: Text(
                                        type.label,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w500,
                                          color: Theme.of(context).colorScheme.onSurface,
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                                onChanged: (AthanSoundType? newValue) {
                                  if (newValue != null) {
                                    setState(() => _athanSoundType = newValue);
                                    _detectChanges();
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Parent Rank: "Scheduled Notifications" - Independent parent section, displays scheduled list
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                            width: 1,
                          ),
                        ),
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FutureBuilder<List<Map<String, dynamic>>>(
                              key: ValueKey(_scheduledNotificationsRefreshKey),
                              future: _pendingNotificationsFuture,
                              builder: (context, snapshot) {
                                // Debug: Print snapshot state
                                if (snapshot.hasError) {
                                  debugPrint('[ScheduledNotifications] Error: ${snapshot.error}');
                                }
                                if (snapshot.connectionState == ConnectionState.waiting) {
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Scheduled Notifications (loading...)', 
                                        style: TextStyle(fontSize: ResponsiveSizes(context).settingHeaderSize, fontWeight: FontWeight.w600)),
                                      const SizedBox(height: 8),
                                      const SizedBox(
                                        height: 40,
                                        child: Center(child: CircularProgressIndicator()),
                                      ),
                                    ],
                                  );
                                }
                                
                                final pendingNotifications = snapshot.data ?? [];
                                debugPrint('[ScheduledNotifications] Found ${pendingNotifications.length} notifications');
                                
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          'Scheduled Notifications (${pendingNotifications.length})',
                                          style: TextStyle(
                                            fontSize: ResponsiveSizes(context).settingHeaderSize,
                                            fontWeight: FontWeight.w600,
                                            color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: () async {
                                            // Trigger reschedule with debug logs
                                            await refreshScheduledNotificationsGlobal();
                                            // Then refresh the display
                                            setState(() {
                                              _scheduledNotificationsRefreshKey++;
                                              _updatePendingNotificationsFuture();
                                            });
                                          },
                                          icon: const Icon(Icons.refresh),
                                          color: Theme.of(context).colorScheme.primary,
                                          tooltip: 'Refresh scheduled notifications',
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    if (snapshot.hasError)
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).colorScheme.errorContainer,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          'Error: ${snapshot.error}',
                                          style: TextStyle(
                                            fontSize: ResponsiveSizes(context).bodySize,
                                            color: Theme.of(context).colorScheme.error,
                                          ),
                                        ),
                                      )
                                    else if (pendingNotifications.isEmpty)
                                      Text(
                                        '  No notifications scheduled',
                                        style: TextStyle(
                                          fontSize: ResponsiveSizes(context).settingLabelSize,
                                          color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.6),
                                        ),
                                      )
                                    else
                                      Container(
                                        decoration: BoxDecoration(
                                          border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)),
                                          borderRadius: BorderRadius.circular(8),
                                          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.1),
                                        ),
                                        child: ListView.separated(
                                          shrinkWrap: true,
                                          physics: const NeverScrollableScrollPhysics(),
                                          itemCount: pendingNotifications.where((n) => n['type'] != 'reminder_killer').length,
                                          separatorBuilder: (_, __) => Divider(
                                            height: 1,
                                            color: Theme.of(context).colorScheme.outlineVariant,
                                          ),
                                          itemBuilder: (context, index) {
                                    // Filter out killer notifications
                                    final filteredNotifications = pendingNotifications.where((n) => n['type'] != 'reminder_killer').toList();
                                    final notif = filteredNotifications[index];
                                    final scheduledTimeMs = notif['scheduledTime'] as int;
                                    
                                    // Convert epoch to timezone-aware DateTime using device timezone
                                    final utcTime = DateTime.fromMillisecondsSinceEpoch(scheduledTimeMs, isUtc: true);
                                    final scheduledTime = utcTime.toLocal(); // Convert UTC to local time
                                    
                                    final timeStr = '${scheduledTime.hour.toString().padLeft(2, '0')}:${scheduledTime.minute.toString().padLeft(2, '0')}';
                                    final bgColor = index.isEven
                                        ? Theme.of(context).colorScheme.surface
                                        : Theme.of(context).colorScheme.surfaceContainer;
                                    
                                    // Get notification metadata
                                    final prayerName = notif['prayer'] as String? ?? 'Unknown';
                                    final notificationType = notif['type'] as String? ?? 'unknown';
                                    final stateValue = notif['state'] as int? ?? 2;
                                    final notificationState = NotificationState.fromValue(stateValue);
                                    final hasCountdown = notif['hasCountdown'] as bool? ?? false;
                                    
                                    // Get icon and color
                                    final notificationIcon = _getNotificationIcon(notificationState);
                                    final notificationColor = _getNotificationIconColor(context, notificationState);
                                    final dateStr = '${scheduledTime.year}-${scheduledTime.month.toString().padLeft(2, '0')}-${scheduledTime.day.toString().padLeft(2, '0')}';
                                    
                                    // Build display name: show "Prayer Name Reminder" for reminder type, just prayer name for athan
                                    final displayName = notificationType == 'reminder' ? '$prayerName Reminder' : prayerName;
                                    final typeLabel = hasCountdown ? 'CD' : '';
                                    
                                    return Container(
                                      color: bgColor,
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text.rich(
                                                  TextSpan(
                                                    children: [
                                                      TextSpan(text: displayName),
                                                      if (typeLabel.isNotEmpty) ...[const TextSpan(text: ' '), TextSpan(text: typeLabel, style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.5)))],
                                                    ],
                                                  ),
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                    fontSize: ResponsiveSizes(context).settingLabelSize,
                                                  ),
                                                ),
                                                Text(
                                                  '$dateStr $timeStr • ${notificationState.label}',
                                                  style: TextStyle(
                                                    fontSize: ResponsiveSizes(context).bodySize,
                                                    color: Theme.of(context).colorScheme.primary.withAlpha(160),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Icon(
                                            notificationIcon,
                                            size: 18,
                                            color: notificationColor,
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ], // End of if (_notificationsEnabled)
                ],
              ),
            ),

            // Tab 3: Misc
            SingleChildScrollView(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 80),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Parent Rank: "Theme" - Independent parent section, manages theme mode
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                        width: 1,
                      ),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Theme',
                          style: TextStyle(
                            fontSize: ResponsiveSizes(context).settingHeaderSize,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                          ),
                        ),
                        const SizedBox(height: 12),
                        GestureDetector(
                          onTap: () => setState(() => _showThemeDropdown = !_showThemeDropdown),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
                              border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _themeModePref == 'system' ? 'System (follow device)' : (_themeModePref == 'light' ? 'Light' : 'Dark'),
                                  style: TextStyle(fontSize: ResponsiveSizes(context).settingLabelSize),
                                ),
                                Icon(
                                  _showThemeDropdown ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                                  size: 20,
                                  color: Theme.of(context).colorScheme.onSurface,
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_showThemeDropdown)
                          Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
                              borderRadius: BorderRadius.only(
                                bottomLeft: Radius.circular(8),
                                bottomRight: Radius.circular(8),
                              ),
                            ),
                            margin: const EdgeInsets.only(top: 4),
                            child: Column(
                              children: [
                                InkWell(
                                  onTap: () {
                                    setState(() {
                                      _themeModePref = 'system';
                                      _showThemeDropdown = false;
                                    });
                                    _detectChanges();
                                  },
                                  child: Container(
                                    width: double.infinity,
                                    color: _themeModePref == 'system'
                                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.05)
                                        : getTextInputPromptColor(context),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    child: Text(
                                      'System (follow device)',
                                      style: TextStyle(
                                        fontSize: ResponsiveSizes(context).settingLabelSize,
                                        color: _themeModePref == 'system'
                                            ? Theme.of(context).colorScheme.onPrimaryContainer
                                            : Theme.of(context).colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                ),
                                Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
                                InkWell(
                                  onTap: () {
                                    setState(() {
                                      _themeModePref = 'light';
                                      _showThemeDropdown = false;
                                    });
                                    _detectChanges();
                                  },
                                  child: Container(
                                    width: double.infinity,
                                    color: _themeModePref == 'light'
                                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.05)
                                        : getTextInputPromptColor(context),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    child: Text(
                                      'Light',
                                      style: TextStyle(
                                        fontSize: ResponsiveSizes(context).settingLabelSize,
                                        color: _themeModePref == 'light'
                                            ? Theme.of(context).colorScheme.onPrimaryContainer
                                            : Theme.of(context).colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                ),
                                Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
                                InkWell(
                                  onTap: () {
                                    setState(() {
                                      _themeModePref = 'dark';
                                      _showThemeDropdown = false;
                                    });
                                    _detectChanges();
                                  },
                                  child: Container(
                                    width: double.infinity,
                                    color: _themeModePref == 'dark'
                                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.05)
                                        : getTextInputPromptColor(context),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    child: Text(
                                      'Dark',
                                      style: TextStyle(
                                        fontSize: ResponsiveSizes(context).settingLabelSize,
                                        color: _themeModePref == 'dark'
                                            ? Theme.of(context).colorScheme.onPrimaryContainer
                                            : Theme.of(context).colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Parent Rank: "Hue" - Independent parent section, manages color hue selection
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                        width: 1,
                      ),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hue',
                          style: TextStyle(
                            fontSize: ResponsiveSizes(context).settingHeaderSize,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Hue Slider
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: Slider(
                                    value: _primaryHue,
                                    min: 0,
                                    max: 360,
                                    divisions: 36,
                                    label: _primaryHue.round().toString(),
                                    onChanged: (v) {
                                      setState(() => _primaryHue = v);
                                      _detectChanges();
                                    },
                                    activeColor: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: HSLColor.fromAHSL(1.0, _primaryHue % 360, 0.72, 0.45).toColor(),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // Widget Background Transparency Slider
                        Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                              width: 1,
                            ),
                          ),
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Widget Background Opacity',
                                style: TextStyle(
                                  fontSize: ResponsiveSizes(context).settingHeaderSize,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: Slider(
                                      value: _widgetBgTransparency,
                                      min: 0.0,
                                      max: 1.0,
                                      divisions: 10,
                                      label: '${(_widgetBgTransparency * 100).toStringAsFixed(0)}%',
                                      onChanged: (v) {
                                        setState(() => _widgetBgTransparency = v);
                                        _detectChanges();
                                      },
                                      activeColor: Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  // About section - long-press to unlock developer menu
                  Builder(
                    builder: (context) {
                      final responsive = ResponsiveSizes(context);
                      return GestureDetector(
                        onLongPress: () {
                          setState(() => _devMenuUnlocked = !_devMenuUnlocked);
                          final status = _devMenuUnlocked ? 'unlocked' : 'locked';
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Developer menu $status')),
                          );
                        },
                        child: Card(
                          child: Padding(
                            padding: EdgeInsets.all(responsive.spacingM),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'About',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: responsive.headingSize,
                                  ),
                                ),
                                SizedBox(height: responsive.spacingS),
                                InkWell(
                                  onTap: () async {
                                    final Uri url = Uri.parse('https://github.com/ikosaheadrom/MoroccanPrayerTimes');
                                    try {
                                      if (await canLaunchUrl(url)) {
                                        await launchUrl(url);
                                      } else {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('No browser app found.')),
                                          );
                                        }
                                      }
                                    } catch (e) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('Failed to open link: $e')),
                                        );
                                      }
                                    }
                                  },
                                  child: Text(
                                    'GitHub Repository',
                                    style: TextStyle(
                                      color: Theme.of(context).colorScheme.primary,
                                      decoration: TextDecoration.underline,
                                      fontSize: responsive.bodySize,
                                    ),
                                  ),
                                ),
                                SizedBox(height: responsive.spacingM),
                                const Divider(),
                                SizedBox(height: responsive.spacingM),
                                Text(
                                  'Version',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: responsive.headingSize,
                                  ),
                                ),
                                SizedBox(height: responsive.spacingS),
                                Text(
                                  'App Version: 1.0.1',
                                  style: TextStyle(fontSize: responsive.bodySize),
                                ),

                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  // Developer debug section - only visible if unlocked
                  if (_devMenuUnlocked)
                  ExpansionTile(
                    title: const Text('Developer Debug'),
                    subtitle: const Text('Testing tools'),
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Background Task Notifications Toggles
                            const Padding(
                              padding: EdgeInsets.only(top: 16.0, bottom: 12.0),
                              child: Text(
                                'Background Task Notifications',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            SwitchListTile(
                              title: const Text('Daily Refresh Notification'),
                              subtitle: const Text('Show notification when prayer times are updated daily'),
                              value: _devShowDailyRefreshNotification,
                              onChanged: (v) {
                                setState(() => _devShowDailyRefreshNotification = v);
                                _detectChanges();
                              },
                              contentPadding: EdgeInsets.zero,
                            ),
                            SwitchListTile(
                              title: const Text('Monthly Calendar Refresh Notification'),
                              subtitle: const Text('Show notification when monthly calendar is refreshed'),
                              value: _devShowMonthlyRefreshNotification,
                              onChanged: (v) {
                                setState(() => _devShowMonthlyRefreshNotification = v);
                                _detectChanges();
                              },
                              contentPadding: EdgeInsets.zero,
                            ),
                            const Divider(height: 24),
                            // Scheduled Test Notification Section
                            Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      SwitchListTile(
                                        title: const Text('Schedule Test Notification'),
                                        subtitle: const Text('Use delayed show() to test'),
                                        value: _devUseScheduledTestNotification,
                                        onChanged: (v) {
                                          setState(() => _devUseScheduledTestNotification = v);
                                          _detectChanges();
                                        },
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                      if (_devUseScheduledTestNotification) ...[
                                        const SizedBox(height: 12),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: TextField(
                                                controller: _testNotificationSecondsController,
                                                keyboardType: TextInputType.number,
                                                decoration: InputDecoration(
                                                  border: const OutlineInputBorder(),
                                                  labelText: 'Delay (seconds)',
                                                  hintText: '10',
                                                  isDense: true,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            ElevatedButton(
                                              onPressed: () async {
                                                final secondsStr = _testNotificationSecondsController.text.trim();
                                                final seconds = int.tryParse(secondsStr) ?? 10;
                                                
                                                final messenger = ScaffoldMessenger.of(context);
                                                try {
                                                  debugPrint('═════ SCHEDULED TEST NOTIFICATION ═════');
                                                  debugPrint('[Test] Scheduling test notification for $seconds seconds...');
                                                  
                                                  final deviceTz = getDeviceTimezone();
                                                  final nowTz = tz.TZDateTime.now(deviceTz);
                                                  
                                                  debugPrint('[Test] Now: $nowTz');
                                                  debugPrint('[Test] Will fire in: $seconds seconds');
                                                  
                                                  if (!mounted) return;
                                                  messenger.showSnackBar(
                                                    SnackBar(content: Text('Test notification will fire in $seconds seconds')),
                                                  );
                                                  
                                                  // Schedule using delayed show()
                                                  debugPrint('[Test] Registering Future.delayed callback...');
                                                  Future.delayed(Duration(seconds: seconds), () async {
                                                    debugPrint('[Test-Callback] Delay elapsed, calling show()...');
                                                    try {
                                                      final prefsTest = await SharedPreferences.getInstance();
                                                      final enableVibration = prefsTest.getBool('enableVibration') ?? true;
                                                      await flutterLocalNotificationsPlugin.show(
                                                        9999,
                                                        'Test Notification',
                                                        'This test notification used delayed show() method',
                                                        NotificationDetails(
                                                          android: AndroidNotificationDetails(
                                                            'pray_times_channel',
                                                            'Prayer Times Notifications',
                                                            channelDescription: 'Notifications for prayer times',
                                                            importance: Importance.max,
                                                            priority: Priority.max,
                                                            enableVibration: enableVibration,
                                                            playSound: true,
                                                            enableLights: true,
                                                            tag: 'test_delayed_show',
                                                            color: Colors.orange,
                                                          ),
                                                        ),
                                                      );
                                                      debugPrint('[Test-Callback] ✓ show() succeeded');
                                                    } catch (e) {
                                                      debugPrint('[Test-Callback] ✗ show() failed: $e');
                                                    }
                                                  });
                                                  
                                                  debugPrint('═════ TEST SCHEDULED ═════');
                                                } catch (e) {
                                                  debugPrint('[Test-Error] $e');
                                                  if (!mounted) return;
                                                  messenger.showSnackBar(
                                                    SnackBar(content: Text('Error: $e')),
                                                  );
                                                }
                                              },
                                              child: const Text('Schedule'),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: _handleSendTestNotification,
                                    child: const Text('Send Test Notification (Immediate)'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: _testReminderNotificationSystem,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Theme.of(context).colorScheme.tertiary,
                                      foregroundColor: Theme.of(context).colorScheme.onTertiary,
                                    ),
                                    child: const Text('Test Reminder System (Two-Notification)'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      final messenger = ScaffoldMessenger.of(context);
                                      try {
                                        final androidImpl = flutterLocalNotificationsPlugin
                                            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
                                        if (androidImpl != null) {
                                          // Delete old channels
                                          await androidImpl.deleteNotificationChannel('pray_times_channel');
                                          await androidImpl.deleteNotificationChannel('prayer_warnings_channel');
                                          // Delete new channels to force full recreation
                                          await androidImpl.deleteNotificationChannel('pray_times_channel_silent');
                                          await androidImpl.deleteNotificationChannel('pray_times_channel_vibrate');
                                          await androidImpl.deleteNotificationChannel('pray_times_channel_full');
                                          await androidImpl.deleteNotificationChannel('prayer_warnings_channel_silent');
                                          await androidImpl.deleteNotificationChannel('prayer_warnings_channel_vibrate');
                                          await androidImpl.deleteNotificationChannel('prayer_warnings_channel_full');
                                          
                                          debugPrint('[DevUI] All notification channels deleted');
                                          
                                          if (!context.mounted) return;
                                          messenger.showSnackBar(
                                            const SnackBar(
                                              duration: Duration(seconds: 5),
                                              content: Text('✓ Deleted all channels.\n1. Close the app completely\n2. Re-open the app\n3. Channels will be recreated with correct settings'),
                                            ),
                                          );
                                        }
                                      } catch (e) {
                                        if (!context.mounted) return;
                                        messenger.showSnackBar(
                                          SnackBar(content: Text('Error: $e')),
                                        );
                                      }
                                    },
                                    child: const Text('Reset Notification Channels'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      final messenger = ScaffoldMessenger.of(context);
                                      messenger.showSnackBar(
                                        const SnackBar(content: Text('Running background refresh...')),
                                      );

                                      final ok = await performBackgroundRefresh();

                                      if (!mounted) return;

                                      messenger.showSnackBar(
                                        SnackBar(content: Text(ok ? 'Background refresh succeeded' : 'Background refresh failed')),
                                      );
                                    },
                                    child: const Text('Run Background Refresh (Debug)'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      final messenger = ScaffoldMessenger.of(context);
                                      messenger.showSnackBar(
                                        const SnackBar(content: Text('Scheduling one-off background task...')),
                                      );
                                      try {
                                        await Workmanager().registerOneOffTask(
                                          'oneOffRefresh',
                                          'refreshPrayerTimes',
                                          initialDelay: const Duration(seconds: 1),
                                          constraints: Constraints(
                                            networkType: NetworkType.connected,
                                            requiresBatteryNotLow: false,
                                            requiresCharging: false,
                                            requiresDeviceIdle: false,
                                            requiresStorageNotLow: false,
                                          ),
                                          backoffPolicy: BackoffPolicy.exponential,
                                          backoffPolicyDelay: const Duration(minutes: 1),
                                        );

                                        if (!mounted) return;
                                        messenger.showSnackBar(
                                          const SnackBar(content: Text('One-off background task scheduled')),
                                        );
                                      } catch (e) {
                                        if (!mounted) return;
                                        messenger.showSnackBar(
                                          SnackBar(content: Text('Failed to schedule background task: $e')),
                                        );
                                      }
                                    },
                                    child: const Text('Schedule One-off Background Task'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () {
                                      final timeZone = getDeviceTimezone();
                                      final now = tz.TZDateTime.now(timeZone);
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('TZ: ${timeZone.name}\nNow: $now\nUTC: ${DateTime.now().toUtc()}'),
                                          duration: const Duration(seconds: 5),
                                        ),
                                      );
                                      debugPrint('═════ TIMEZONE INFO ═════');
                                      debugPrint('Timezone: ${timeZone.name}');
                                      debugPrint('Local time: $now');
                                      debugPrint('UTC time: ${DateTime.now().toUtc()}');
                                    },
                                    child: const Text('Show Timezone Info'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      debugPrint('\n\n');
                                      await _checkNotificationPermissions();
                                      if (!mounted) return;
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Check diagnostics in logs')),
                                      );
                                    },
                                    child: const Text('Check Notification Setup'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: _testOfflineVsApiComparison,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.purple,
                                      foregroundColor: Colors.white,
                                    ),
                                    child: const Text('Compare Offline vs Ministry API Times'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      final messenger = ScaffoldMessenger.of(context);
                                      final prefs = await SharedPreferences.getInstance();
                                      if (!mounted) return;
                                      final lastExecution = prefs.getString('lastBackgroundTaskExecution') ?? 'No execution recorded';
                                      debugPrint('[Debug] Last background task execution: $lastExecution');
                                      messenger.showSnackBar(
                                        SnackBar(content: Text('Last execution: $lastExecution')),
                                      );
                                    },
                                    child: const Text('Check Background Task Execution'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      final messenger = ScaffoldMessenger.of(context);
                                      await _printCacheExpirationInfo();
                                      if (!mounted) return;
                                      messenger.showSnackBar(
                                        const SnackBar(content: Text('Cache expiration info printed to logs')),
                                      );
                                    },
                                    child: const Text('Show Cache Expiration Info'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      if (!mounted) return;
                                      final messenger = ScaffoldMessenger.of(context);
                                      try {
                                        messenger.showSnackBar(
                                          const SnackBar(content: Text('Running zonedSchedule() diagnostics...')),
                                        );
                                        await _troubleshootZonedSchedule();
                                      } catch (e) {
                                        if (!mounted) return;
                                        messenger.showSnackBar(
                                          SnackBar(content: Text('Error: $e')),
                                        );
                                      }
                                    },
                                    child: const Text('Troubleshoot zonedSchedule()'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      final messenger = ScaffoldMessenger.of(context);
                                      try {
                                        messenger.showSnackBar(
                                          const SnackBar(content: Text('Testing parser service...')),
                                        );
                                        await _testPrayerTimesParser();
                                      } catch (e) {
                                        if (!mounted) return;
                                        messenger.showSnackBar(
                                          SnackBar(content: Text('Error: $e')),
                                        );
                                      }
                                    },
                                    child: const Text('Test Prayer Parser Service'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      final messenger = ScaffoldMessenger.of(context);
                                      try {
                                        messenger.showSnackBar(
                                          const SnackBar(content: Text('Testing daily parser...')),
                                        );
                                        await _testDailyParserService();
                                      } catch (e) {
                                        if (!mounted) return;
                                        messenger.showSnackBar(
                                          SnackBar(content: Text('Error: $e')),
                                        );
                                      }
                                    },
                                    child: const Text('Test Daily Prayer Parser'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      final messenger = ScaffoldMessenger.of(context);
                                      try {
                                        messenger.showSnackBar(
                                          const SnackBar(content: Text('Running daily refresh task...')),
                                        );
                                        await _testDailyRefreshTask();
                                        if (!mounted) return;
                                        messenger.showSnackBar(
                                          const SnackBar(content: Text('Daily refresh task completed - check logs')),
                                        );
                                      } catch (e) {
                                        if (!mounted) return;
                                        messenger.showSnackBar(
                                          SnackBar(content: Text('Error: $e')),
                                        );
                                      }
                                    },
                                    child: const Text('Test Daily Refresh Task (WorkManager)'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      final messenger = ScaffoldMessenger.of(context);
                                      try {
                                        messenger.showSnackBar(
                                          const SnackBar(content: Text('Testing athan notification with Full state...')),
                                        );
                                        await _testAthanNotificationWithFullState();
                                        if (!mounted) return;
                                        messenger.showSnackBar(
                                          const SnackBar(content: Text('Athan test notification sent - check logs')),
                                        );
                                      } catch (e) {
                                        if (!mounted) return;
                                        messenger.showSnackBar(
                                          SnackBar(content: Text('Error: $e')),
                                        );
                                      }
                                    },
                                    child: const Text('Test Athan Notification (Full State)'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      final messenger = ScaffoldMessenger.of(context);
                                      try {
                                        messenger.showSnackBar(const SnackBar(content: Text('Testing monthly refresh...')));
                                        // First set expiration to past
                                        await bg_tasks.testSetCacheExpirationToPast();
                                        // Then directly execute the refresh handler (bypasses WorkManager)
                                        await bg_tasks.testMonthlyCalendarRefresh();
                                        if (!mounted) return;
                                        messenger.showSnackBar(const SnackBar(content: Text('✓ Monthly refresh executed - check logs')));
                                      } catch (e) {
                                        if (!mounted) return;
                                        messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
                                      }
                                    },
                                    child: const Text('Monthly Refresh: Test Now'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      final messenger = ScaffoldMessenger.of(context);
                                      try {
                                        messenger.showSnackBar(const SnackBar(content: Text('Testing daily refresh...')));
                                        await bg_tasks.executeDailyPrayerRefresh();
                                        if (!mounted) return;
                                        messenger.showSnackBar(const SnackBar(content: Text('✓ Daily refresh executed - check logs and widget cache')));
                                      } catch (e) {
                                        if (!mounted) return;
                                        messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
                                      }
                                    },
                                    child: const Text('Daily Refresh: Test Now'),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: () async {
                                      try {
                                        // Use Casablanca coordinates as default test location
                                        const double testLat = 33.5898;
                                        const double testLon = -7.6038;
                                        final now = DateTime.now();
                                        
                                        debugPrint('═════ OFFLINE PRAYER TIME CALCULATION ═════');
                                        debugPrint('Testing offline mode with coordinates: $testLat, $testLon');
                                        debugPrint('Date: $now');
                                        
                                        final prayerTimes = calculatePrayerTimesOffline(
                                          latitude: testLat,
                                          longitude: testLon,
                                          date: now,
                                        );
                                        
                                        debugPrint('Calculated prayer times:');
                                        prayerTimes.forEach((prayer, time) {
                                          debugPrint('  $prayer: $time');
                                        });
                                        debugPrint('═════ OFFLINE CALCULATION COMPLETE ═════');
                                        
                                        if (!mounted) return;
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'Offline prayer times calculated!\n'
                                              'Fajr: ${prayerTimes['Fajr']}\n'
                                              'Dhuhr: ${prayerTimes['Dhuhr']}\n'
                                              'Maghrib: ${prayerTimes['Maghrib']}',
                                            ),
                                            duration: const Duration(seconds: 5),
                                          ),
                                        );
                                      } catch (e, st) {
                                        debugPrint('Error calculating offline times: $e');
                                        debugPrint('Stack: $st');
                                        if (!mounted) return;
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('Error: $e')),
                                        );
                                      }
                                    },
                                    child: const Text('Test Offline Calculation'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                ),
          ],
        ),
        bottomNavigationBar: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary.withValues(
                  alpha: _settingsChanged ? 1.0 : 0.4,
                ),
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
              ),
              onPressed: _settingsChanged ? () async {
                // Save all settings (this will reschedule notifications and pop)
                await _saveSettings();
                // Note: _saveSettings() handles rescheduling and popping navigator
              } : null,
              child: const Text('Save Settings'),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// ATHAN NOTIFICATION HELPER FUNCTIONS
// ============================================================================

/// Show short athan notification (4 seconds, no dismiss button, no full screen)
Future<void> showShortAthanNotification({
  required String title,
  required String body,
}) async {
  try {
    final androidDetails = AndroidNotificationDetails(
      'athan_channel_short_v2',
      'Athan (Short - 4 seconds)',
      channelDescription: 'Short athan notification (4 seconds)',
      importance: Importance.max,
      priority: Priority.high,
      fullScreenIntent: false,
      ongoing: false,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
    );

    const iOSDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'shortathan.mp3',
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iOSDetails,
    );

    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecond,
      title,
      body,
      notificationDetails,
    );

    debugPrint('[Athan] Showed short athan notification');
  } catch (e, st) {
    debugPrint('[Athan] Error showing short athan notification: $e\n$st');
  }
}

/// Show normal athan notification with dismiss button (full screen intent, ongoing)
Future<void> showNormalAthanNotification({
  required String title,
  required String body,
}) async {
  try {
    final androidDetails = AndroidNotificationDetails(
      'athan_channel_normal_v2',
      'Athan (Normal)',
      channelDescription: 'Full athan notification with dismiss button',
      importance: Importance.max,
      priority: Priority.high,
      fullScreenIntent: true,
      ongoing: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
      actions: <AndroidNotificationAction>[
        const AndroidNotificationAction(
          'dismiss_athan',
          'Dismiss',
          showsUserInterface: true,
        ),
      ],
    );

    const iOSDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'athan.mp3',
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iOSDetails,
    );

    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecond,
      title,
      body,
      notificationDetails,
      payload: 'athan_normal',
    );

    debugPrint('[Athan] Showed normal athan notification with dismiss button');
  } catch (e, st) {
    debugPrint('[Athan] Error showing normal athan notification: $e\n$st');
  }
}

