import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'dart:convert';
import 'dart:io';
import 'prayer_times_parser.dart';
import 'prayer_times_provider.dart';
import 'notifications/notifications.dart';
import '../widgets/widget_cache_updater.dart';

/// Background task names
const String dailyPrayerRefreshTaskName = 'daily_prayer_refresh';
const String monthlyCalendarRefreshTaskName = 'monthly_calendar_refresh';
const String prayerTimeAlarmTaskPrefix = 'prayer_alarm_'; // prayer_alarm_fajr, prayer_alarm_dhuhr, etc

/// Initialize WorkManager and register periodic tasks
Future<void> initializeBackgroundTasks() async {
  debugPrint('[BackgroundTasks] initializeBackgroundTasks called');
  
  final prefs = await SharedPreferences.getInstance();
  
  // Check if tasks have already been initialized
  final tasksInitialized = prefs.getBool('backgroundTasksInitialized') ?? false;
  
  if (tasksInitialized) {
    debugPrint('[BackgroundTasks] Tasks already initialized, skipping re-registration');
    return;
  }
  
  debugPrint('[BackgroundTasks] First time initialization - setting up WorkManager');
  
  await Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: true,
  );

  debugPrint('[BackgroundTasks] WorkManager initialized');

  // Register daily prayer time refresh at 12:01 AM
  await registerDailyPrayerRefresh();

  // Register monthly calendar refresh
  await registerMonthlyCalendarRefresh();
  
  // Mark tasks as initialized
  await prefs.setBool('backgroundTasksInitialized', true);
  debugPrint('[BackgroundTasks] Background tasks initialization flag set');
}

/// Callback dispatcher for WorkManager - must be a top-level function
@pragma('vm:entry-point')
void callbackDispatcher() {
  debugPrint('[BackgroundTasks] callbackDispatcher invoked!');
  Workmanager().executeTask((task, inputData) async {
    debugPrint('[BackgroundTasks] executeTask called for task: $task');
    try {
      switch (task) {
        case dailyPrayerRefreshTaskName:
          debugPrint('[BackgroundTasks] Handling daily prayer refresh...');
          await executeDailyPrayerRefresh();
          return true;

        case monthlyCalendarRefreshTaskName:
          debugPrint('[BackgroundTasks] Handling monthly calendar refresh...');
          await executeMonthlyCalendarRefresh();
          return true;

        default:
          // Check if it's a prayer time alarm task (prayer_alarm_fajr, etc)
          if (task.startsWith(prayerTimeAlarmTaskPrefix)) {
            debugPrint('[BackgroundTasks] Handling prayer time alarm: $task');
            await _handlePrayerTimeAlarm(task);
            return true;
          }
          debugPrint('[BackgroundTasks] Unknown task: $task');
          return false;
      }
    } catch (e) {
      debugPrint('[BackgroundTasks] Error executing task $task: $e');
      return false;
    }
  });
}

/// Register daily prayer time refresh task at 2:00 AM (when API is updated)
Future<void> registerDailyPrayerRefresh() async {
  try {
    debugPrint('[BackgroundTasks] Registering daily prayer refresh task for 2:00 AM...');
    await Workmanager().registerPeriodicTask(
      dailyPrayerRefreshTaskName,
      dailyPrayerRefreshTaskName,
      frequency: const Duration(days: 1),
      initialDelay: _calculateInitialDelayFor2AM(),
      tag: dailyPrayerRefreshTaskName,
      constraints: Constraints(
        networkType: NetworkType.not_required,
        requiresDeviceIdle: false,
        requiresCharging: false,
        requiresBatteryNotLow: false,
        requiresStorageNotLow: false,
      ),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 15),
    );
    debugPrint('[BackgroundTasks] Daily prayer refresh task registered successfully');
  } catch (e) {
    debugPrint('[BackgroundTasks] Failed to register daily task: $e');
  }
}

/// Register monthly calendar refresh task
/// Changed to PERIODIC (daily) but only executes when cache expires
/// This ensures the task keeps running and rescheduling automatically
Future<void> registerMonthlyCalendarRefresh() async {
  try {
    debugPrint('[BackgroundTasks] Registering monthly calendar refresh as periodic daily task...');
    final prefs = await SharedPreferences.getInstance();
    final cityId = prefs.getString('cityCityId') ?? '58';
    final cacheKey = 'calendarData_$cityId';
    
    // Calculate cache expiration date
    var expirationDate = await _calculateCacheExpirationDate(cacheKey);
    
    // If cache doesn't exist or expiration can't be determined, use a default 30-day expiration
    if (expirationDate == null) {
      debugPrint('[BackgroundTasks] Cache not found or expiration cannot be calculated, using default 30-day expiration');
      expirationDate = DateTime.now().add(const Duration(days: 30));
    }
    
    // Save expiration date to SharedPreferences so the periodic task knows when to execute
    await prefs.setString('monthlyRefreshExpiration_$cityId', expirationDate.toIso8601String());
    debugPrint('[BackgroundTasks] Saved monthly refresh expiration: ${expirationDate.toIso8601String()}');
    
    // Calculate initial delay until expiration date at 00:01 AM
    final now = DateTime.now();
    final expirationAtMidnight = DateTime(expirationDate.year, expirationDate.month, expirationDate.day, 0, 1);
    final initialDelay = expirationAtMidnight.difference(now);
    
    debugPrint('[BackgroundTasks] Scheduling monthly refresh - initial delay: ${initialDelay.inDays} days');
    
    // Register as PERIODIC task running daily instead of one-off
    // This way it keeps running even after execution and reschedules automatically
    await Workmanager().registerPeriodicTask(
      monthlyCalendarRefreshTaskName,
      monthlyCalendarRefreshTaskName,
      frequency: const Duration(days: 1),
      initialDelay: initialDelay.isNegative ? Duration.zero : initialDelay,
      tag: monthlyCalendarRefreshTaskName,
      constraints: Constraints(
        networkType: NetworkType.not_required,
        requiresDeviceIdle: false,
        requiresCharging: false,
        requiresBatteryNotLow: false,
        requiresStorageNotLow: false,
      ),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 15),
    );
    
    debugPrint('[BackgroundTasks] ✓ Monthly calendar refresh registered as periodic daily task');
  } catch (e) {
    debugPrint('[BackgroundTasks] Failed to register monthly task: $e');
  }
}

/// Cancel all background tasks
Future<void> cancelAllBackgroundTasks() async {
  try {
    await Workmanager().cancelByTag(dailyPrayerRefreshTaskName);
    await Workmanager().cancelByTag(monthlyCalendarRefreshTaskName);
    debugPrint('[BackgroundTasks] All background tasks cancelled');
  } catch (e) {
    debugPrint('[BackgroundTasks] Failed to cancel tasks: $e');
  }
}

/// Handle daily prayer time refresh
/// This method refreshes today's prayer times, updates widget cache, and schedules prayer alarms
Future<void> _handleDailyPrayerRefresh() async {
  debugPrint('[BackgroundTasks] ═════ DAILY PRAYER REFRESH TASK ═════');
  debugPrint('[BackgroundTasks] Executing daily prayer refresh task at ${DateTime.now()}');

  try {
    final prefs = await SharedPreferences.getInstance();
    
    // Write execution log to SharedPreferences for debugging
    final executionTime = DateTime.now().toIso8601String();
    await prefs.setString('lastBackgroundTaskExecution', 'Daily refresh at $executionTime');

    // Get current city and settings
    final cityId = prefs.getString('cityCityId') ?? '58';
    final cityName = prefs.getString('cityCityName') ?? 'Casablanca';
    final useMinistry = prefs.getBool('useMinistry') ?? true;
    final isOfflineMode = prefs.getBool('isOfflineMode') ?? false;
    
    debugPrint('[BackgroundTasks] City ID: $cityId, City Name: $cityName');
    debugPrint('[BackgroundTasks] useMinistry: $useMinistry, isOfflineMode: $isOfflineMode');

    // Mark cache as stale and set flag to refresh
    await prefs.setBool('needsDailyRefresh', true);
    await prefs.setString('lastDailyRefreshTime', DateTime.now().toIso8601String());
    debugPrint('[BackgroundTasks] Set needsDailyRefresh flag');

    // Use PrayerTimesProvider to get prayer times (unified source logic)
    final provider = PrayerTimesProvider();
    final result = await provider.getPrayerTimes();
    
    debugPrint('[BackgroundTasks] Got prayer times from provider:');
    debugPrint('[BackgroundTasks]   Source: ${result.sourceUsed}');
    debugPrint('[BackgroundTasks]   Input: ${result.inputSettings}');
    
    final dailyTimes = result.times;
    final sourceUsed = result.sourceUsed;
    
    // Check if we got valid data
    final hasValidData = dailyTimes.isNotEmpty && 
                        dailyTimes['fajr'] != 'N/A' && 
                        dailyTimes['dhuhr'] != 'N/A' && 
                        dailyTimes['maghrib'] != 'N/A';
    
    if (hasValidData) {
      debugPrint('[BackgroundTasks] ✓ Successfully obtained prayer times from $sourceUsed:');
      debugPrint('[BackgroundTasks]   Fajr: ${dailyTimes['fajr']}');
      debugPrint('[BackgroundTasks]   Sunrise: ${dailyTimes['sunrise']}');
      debugPrint('[BackgroundTasks]   Dhuhr: ${dailyTimes['dhuhr']}');
      debugPrint('[BackgroundTasks]   Asr: ${dailyTimes['asr']}');
      debugPrint('[BackgroundTasks]   Maghrib: ${dailyTimes['maghrib']}');
      debugPrint('[BackgroundTasks]   Isha: ${dailyTimes['isha']}');
      
      // Update widget cache with the fetched prayer times
      try {
        await WidgetCacheUpdater.updateCacheWithPrayerTimesMap(
          dailyTimes,
          sourceOverride: sourceUsed,
        );
        debugPrint('[BackgroundTasks] ✓ Widget cache updated with prayer times');
        // Notify Android widget to refresh immediately
        await notifyWidgetToRefresh();
      } catch (e) {
        debugPrint('[BackgroundTasks] ⚠ Failed to update widget cache: $e');
      }
      
      // Schedule prayer time notifications using new NotificationManager
      try {
        final prefs = await SharedPreferences.getInstance();
        final globalStateValue = prefs.getInt('notificationState') ?? 2;
        final notificationState = NotificationState.fromValue(globalStateValue);
        final athanSoundTypeValue = prefs.getInt('athanSoundType') ?? 0;
        final athanSoundType = AthanSoundType.fromValue(athanSoundTypeValue);
        final reminderEnabled = prefs.getBool('reminderEnabled') ?? false;
        final reminderMinutes = prefs.getInt('reminderMinutes') ?? 10;
        
        final manager = NotificationManager();
        final timezone = _getDeviceTimezone();
        
        // Use PrayerTimesProvider to get times based on user's selected source
        final provider = PrayerTimesProvider();
        final result = await provider.getPrayerTimes();
        
        debugPrint('[BackgroundTasks] Using source: ${result.sourceUsed}');
        
        await manager.scheduleNotificationsForTodaysPrayers(
          prayerTimes: result.times,
          reminderEnabled: reminderEnabled,
          reminderMinutes: reminderMinutes,
          notificationState: notificationState,
          athanSoundType: athanSoundType,
          timezone: timezone,
        );
        debugPrint('[BackgroundTasks] ✓ Prayer time notifications scheduled');
      } catch (e) {
        debugPrint('[BackgroundTasks] ⚠ Failed to schedule notifications: $e');
      }
      
      // Cancel old prayer time notifications before scheduling new ones
      try {
        await _cancelOldPrayerNotifications();
        debugPrint('[BackgroundTasks] ✓ Old prayer notifications cancelled');
      } catch (e) {
        debugPrint('[BackgroundTasks] ⚠ Failed to cancel old notifications: $e');
      }
      
      // Show silent notification with the prayer times (if enabled via devtools)
      final showDailyRefreshNotification = prefs.getBool('devShowDailyRefreshNotification') ?? false;
      if (showDailyRefreshNotification) {
        try {
          final plugin = FlutterLocalNotificationsPlugin();
          
          // Initialize if needed (for background context)
          await plugin.initialize(
            const InitializationSettings(
              android: AndroidInitializationSettings('@mipmap/ic_launcher'),
              iOS: DarwinInitializationSettings(),
            ),
            onDidReceiveNotificationResponse: null,
          );
          
          final notificationBody = 'Source: $sourceUsed\n'
              'Fajr: ${dailyTimes['fajr']}\n'
              'Sunrise: ${dailyTimes['sunrise']}\n'
              'Dhuhr: ${dailyTimes['dhuhr']}\n'
              'Asr: ${dailyTimes['asr']}\n'
              'Maghrib: ${dailyTimes['maghrib']}\n'
              'Isha: ${dailyTimes['isha']}';
          
          await plugin.show(
            999, // Unique ID for this notification
            '🕌 Prayer Times Updated',
            notificationBody,
            NotificationDetails(
              android: AndroidNotificationDetails(
                'pray_times_channel_silent',
                'Prayer Times',
                channelDescription: 'Silent notification for prayer times',
                importance: Importance.low,
                priority: Priority.low,
                silent: true,
                playSound: false,
                enableVibration: false,
              ),
              iOS: const DarwinNotificationDetails(
                presentAlert: false,
                presentBadge: false,
                presentSound: false,
              ),
            ),
          );
          debugPrint('[BackgroundTasks] ✓ Sent notification with prayer times');
        } catch (e) {
          debugPrint('[BackgroundTasks] Could not send notification: $e');
        }
      } else {
        debugPrint('[BackgroundTasks] Daily refresh notification disabled via devtools');
      }
    } else {
      debugPrint('[BackgroundTasks] Daily times returned invalid data (N/A values or empty)');
      debugPrint('[BackgroundTasks] Times received: $dailyTimes');
    }
    
    // Set flag to reschedule notifications when app opens (in case of app background)
    await prefs.setBool('needsNotificationReschedule', true);
    debugPrint('[BackgroundTasks] Set needsNotificationReschedule flag for app');

    debugPrint('[BackgroundTasks] ✓ Daily prayer refresh completed at ${DateTime.now()}');
    debugPrint('[BackgroundTasks] ═════ END DAILY REFRESH ═════');
  } catch (e, st) {
    debugPrint('[BackgroundTasks] ✗ Error in daily refresh: $e');
    debugPrint('[BackgroundTasks] Stack: $st');
    
    // Still set the reschedule flag so app can handle it
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('needsNotificationReschedule', true);
  }
}

/// PUBLIC: Execute monthly calendar refresh
/// Called by both WorkManager (periodic task) and test button
/// This is the single entry point for all monthly refresh execution
Future<void> executeMonthlyCalendarRefresh() async {
  try {
    await _handleMonthlyCalendarRefresh();
  } catch (e, st) {
    debugPrint('[BackgroundTasks] ✗ Error in monthly calendar refresh: $e');
    debugPrint('[BackgroundTasks] Stack: $st');
  }
}

/// Handle monthly calendar refresh
/// This method fetches fresh calendar data from Ministry website, parses it using the prayer_times_parser service,
/// saves to cache, and schedules next refresh
Future<void> _handleMonthlyCalendarRefresh() async {
  debugPrint('[BackgroundTasks] ═════ MONTHLY CALENDAR REFRESH TASK ═════');
  debugPrint('[BackgroundTasks] Executing monthly calendar refresh task at ${DateTime.now()}');

  try {
    final prefs = await SharedPreferences.getInstance();
    final cityId = prefs.getString('cityCityId') ?? '58';
    
    // CHECK IF CACHE HAS ACTUALLY EXPIRED
    // Since this is now a periodic daily task, we should only execute if cache has expired
    final expirationStr = prefs.getString('monthlyRefreshExpiration_$cityId');
    if (expirationStr != null) {
      try {
        final expirationDate = DateTime.parse(expirationStr);
        final now = DateTime.now();
        
        debugPrint('[BackgroundTasks] ═══ CACHE EXPIRATION CHECK ═══');
        debugPrint('[BackgroundTasks] Current time: ${now.toIso8601String()}');
        debugPrint('[BackgroundTasks] Expiration time: ${expirationDate.toIso8601String()}');
        debugPrint('[BackgroundTasks] Days until expiration: ${expirationDate.difference(now).inDays}');
        
        // Only execute if expiration date has been reached
        if (now.isBefore(expirationDate)) {
          debugPrint('[BackgroundTasks] ⚠ Cache has NOT expired yet');
          debugPrint('[BackgroundTasks] Status: SKIPPING monthly refresh (will retry tomorrow)');
          debugPrint('[BackgroundTasks] ═══════════════════════════════');
          return; // Don't execute, try again tomorrow
        }
        debugPrint('[BackgroundTasks] ✓ Cache HAS expired - proceeding with refresh');
        debugPrint('[BackgroundTasks] ═══════════════════════════════');
      } catch (e) {
        debugPrint('[BackgroundTasks] ✗ ERROR parsing expiration date: $e');
        debugPrint('[BackgroundTasks] Proceeding with refresh anyway (as fallback)');
      }
    } else {
      debugPrint('[BackgroundTasks] ⚠ No expiration date found in cache, forcing refresh');
    }
    
    final executionTime = DateTime.now().toIso8601String();
    await prefs.setString('lastBackgroundTaskExecution', 'Monthly refresh at $executionTime');
    
    final cacheKey = 'calendarData_$cityId';
    final lastCityKey = 'calendarLastCity_$cityId';
    debugPrint('[BackgroundTasks] City ID: $cityId');

    // Save previous cache as backup
    final previousKey = 'calendarData_${cityId}_previous';
    final currentCache = prefs.getString(cacheKey);
    String? monthNameLatin;
    
    if (currentCache != null) {
      try {
        final cacheData = jsonDecode(currentCache) as Map<String, dynamic>;
        monthNameLatin = cacheData['_monthLabelLatin'] as String?;
        debugPrint('[BackgroundTasks] Extracted current month name: "$monthNameLatin"');
      } catch (e) {
        debugPrint('[BackgroundTasks] Could not extract month name from cache: $e');
      }
      await prefs.setString(previousKey, currentCache);
      debugPrint('[BackgroundTasks] ✓ Saved previous calendar cache as backup');
    }

    // FETCH HTML FROM MINISTRY
    debugPrint('[BackgroundTasks] Fetching fresh calendar HTML...');
    String htmlBody = '';
    try {
      var ministryUrl = prefs.getString('ministryUrl') ?? 'https://habous.gov.ma/prieres/horaire_hijri_2.php';
      
      // FIX: Replace old incorrect URL with correct working URL
      if (ministryUrl.contains('/fr/horaire-des-prieres/horaire')) {
        ministryUrl = 'https://habous.gov.ma/prieres/horaire_hijri_2.php';
        debugPrint('[BackgroundTasks] ✓ Detected old URL format, using correct URL');
        await prefs.setString('ministryUrl', ministryUrl);
      }
      
      final separator = ministryUrl.contains('?') ? '&' : '?';
      final uri = Uri.parse('$ministryUrl${separator}ville=$cityId');
      
      debugPrint('[BackgroundTasks] Fetching from: $uri');
      
      final httpClient = HttpClient();
      httpClient.badCertificateCallback = (cert, host, port) => true; // Dev only
      final request = await httpClient.getUrl(uri);
      final response = await request.close();
      htmlBody = await response.transform(utf8.decoder).join();
      httpClient.close();
      
      if (response.statusCode != 200) {
        throw Exception('Failed to fetch HTML: ${response.statusCode}');
      }
      
      debugPrint('[BackgroundTasks] ✓ HTML fetched successfully (${htmlBody.length} bytes)');
    } catch (e) {
      debugPrint('[BackgroundTasks] ✗ Error fetching HTML: $e');
      rethrow;
    }

    // PARSE HTML USING PRAYER TIMES PARSER SERVICE
    debugPrint('[BackgroundTasks] Parsing HTML with PrayerTimesParser service...');
    final parsedCalendar = await parseMonthlyCalendarFromHtml(htmlBody, cityId: int.tryParse(cityId) ?? 58);
    
    if (parsedCalendar.isEmpty || parsedCalendar['days'] == null) {
      throw Exception('Failed to parse calendar from HTML');
    }

    final allDays = getAllPrayerDays(parsedCalendar);
    debugPrint('[BackgroundTasks] ✓ Parsed ${allDays.length} days from HTML');

    // BUILD CACHE FROM PARSED DATA
    final Map<String, dynamic> toSave = {};

    for (final dayData in allDays) {
      final gregorianDateStr = dayData['gregorianDate_ISO'] ?? '';
      if (gregorianDateStr.isNotEmpty) {
        try {
          final dateKey = '${gregorianDateStr}T00:00:00.000';
          
          toSave[dateKey] = {
            'Fajr': dayData['fajr_HHmm'] ?? 'N/A',
            'Sunrise': dayData['sunrise_HHmm'] ?? 'N/A',
            'Dhuhr': dayData['dhuhr_HHmm'] ?? 'N/A',
            'Asr': dayData['asr_HHmm'] ?? 'N/A',
            'Maghrib': dayData['maghrib_HHmm'] ?? 'N/A',
            'Isha': dayData['isha_HHmm'] ?? 'N/A',
            'DayOfWeek': dayData['dayOfWeek_TEXT'] ?? 'N/A',
            'Hijri': dayData['hijriDay'] ?? '',
            'Solar': dayData['solarDay'] ?? '',
            'HijriMonth': dayData['hijriMonth_TEXT'] ?? '',
            'SolarMonth': dayData['solarMonth_TEXT'] ?? '',
          };
        } catch (e) {
          debugPrint('[BackgroundTasks] Error processing day ${dayData['hijriDay']}: $e');
        }
      }
    }

    // GET CACHE EXPIRATION FROM PARSER
    final expiresAtStr = parsedCalendar['expiresAt_ISO'] as String?;
    DateTime? cacheExpiresAt;
    if (expiresAtStr != null) {
      try {
        cacheExpiresAt = DateTime.parse(expiresAtStr);
        debugPrint('[BackgroundTasks] ✓ Cache expiration from parser: $expiresAtStr');
      } catch (e) {
        debugPrint('[BackgroundTasks] Error parsing expiration date: $e');
      }
    }

    // SAVE METADATA
    monthNameLatin = parsedCalendar['hijriMonthLatin'] as String? ?? 'Islamic Month';
    final hijriMonthArabic = parsedCalendar['hijriMonth'] as String? ?? '';
    final parsedCityId = parsedCalendar['cityId'] as int?;
    final firstDateISO = parsedCalendar['firstDate_ISO'] as String?;
    final lastDateISO = parsedCalendar['lastDate_ISO'] as String?;
    final expiresAtISO = parsedCalendar['expiresAt_ISO'] as String?;
    
    toSave['_monthLabelArabic'] = hijriMonthArabic;
    toSave['_monthLabelLatin'] = monthNameLatin;
    toSave['_cityId'] = parsedCityId ?? cityId;
    
    // Store parser's expiration date
    if (expiresAtISO != null) {
      toSave['_expiresAt_ISO'] = expiresAtISO;
      cacheExpiresAt = DateTime.parse(expiresAtISO);
      debugPrint('[BackgroundTasks] ✓ Cache will expire on: $expiresAtISO (from parser)');
    }
    
    if (firstDateISO != null) {
      toSave['_firstDate_ISO'] = firstDateISO;
    }
    if (lastDateISO != null) {
      toSave['_lastDate_ISO'] = lastDateISO;
    }

    // PERSIST CACHE
    await prefs.setString(cacheKey, jsonEncode(toSave));
    final currentCity = prefs.getString('selectedCityName') ?? 'Casablanca';
    await prefs.setString(lastCityKey, currentCity);
    debugPrint('[BackgroundTasks] ✓ Saved ${toSave.length - 4} prayer time entries to cache');
    debugPrint('[BackgroundTasks] ✓ City ID verified: $parsedCityId');

    // Update widget cache with today's prayer times from the calendar
    try {
      // Get today's entry from the calendar
      final today = DateTime.now();
      final todayKey = '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}T00:00:00.000';
      
      if (toSave.containsKey(todayKey)) {
        final todayEntry = toSave[todayKey] as Map<String, dynamic>?;
        if (todayEntry != null) {
          final todayTimes = {
            'fajr': (todayEntry['Fajr'] as String?) ?? 'N/A',
            'sunrise': (todayEntry['Sunrise'] as String?) ?? 'N/A',
            'dhuhr': (todayEntry['Dhuhr'] as String?) ?? 'N/A',
            'asr': (todayEntry['Asr'] as String?) ?? 'N/A',
            'maghrib': (todayEntry['Maghrib'] as String?) ?? 'N/A',
            'isha': (todayEntry['Isha'] as String?) ?? 'N/A',
          };
          
          await WidgetCacheUpdater.updateCacheWithPrayerTimesMap(todayTimes);
          debugPrint('[BackgroundTasks] ✓ Widget cache updated with today\'s prayer times from calendar');
          // Notify Android widget to refresh immediately
          await notifyWidgetToRefresh();
        }
      } else {
        debugPrint('[BackgroundTasks] ⚠ Today\'s entry not found in calendar (key: $todayKey)');
      }
    } catch (e) {
      debugPrint('[BackgroundTasks] ⚠ Failed to update widget cache: $e');
    }

    // UPDATE EXPIRATION DATE FOR NEXT PERIODIC CHECK
    // Since this is now a periodic daily task, we update the expiration date
    // The task will check this date every day and only execute when date is reached
    if (cacheExpiresAt != null) {
      final cityId = prefs.getString('cityCityId') ?? '58';
      await prefs.setString('monthlyRefreshExpiration_$cityId', cacheExpiresAt.toIso8601String());
      final expirationDate = cacheExpiresAt.toIso8601String().split('T')[0];
      final daysFromNow = cacheExpiresAt.difference(DateTime.now()).inDays;
      debugPrint('[BackgroundTasks] ✓ REFRESH COMPLETED - Cache will expire on: $expirationDate');
      debugPrint('[BackgroundTasks] ✓ Next refresh will trigger in approximately $daysFromNow days');
      debugPrint('[BackgroundTasks] ✓ Periodic task will check daily and execute when date is reached');
    } else {
      debugPrint('[BackgroundTasks] ⚠ Could not determine expiration date');
    }
    
    // SEND NOTIFICATION (if enabled via devtools)
    final showMonthlyRefreshNotification = prefs.getBool('devShowMonthlyRefreshNotification') ?? false;
    if (monthNameLatin.isNotEmpty && showMonthlyRefreshNotification) {
      await _sendMonthlyRefreshNotification(monthNameLatin);
      debugPrint('[BackgroundTasks] ✓ Notification shown successfully');
    } else if (!showMonthlyRefreshNotification) {
      debugPrint('[BackgroundTasks] Monthly refresh notification disabled via devtools');
    }
    
    debugPrint('[BackgroundTasks] ✓ Monthly calendar refresh completed');

  } catch (e, st) {
    debugPrint('[BackgroundTasks] ✗ Error in monthly refresh: $e');
    debugPrint('[BackgroundTasks] Stack: $st');
    
    // Clear cache on error so app knows to retry
    final prefs = await SharedPreferences.getInstance();
    final cityId = prefs.getString('cityCityId') ?? '58';
    await prefs.remove('calendarData_$cityId');
    await prefs.setBool('needsMonthlyRefresh', true);
  }
}

/// Send silent notification for monthly calendar refresh completion
Future<void> _sendMonthlyRefreshNotification(String monthNameLatin) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    
    debugPrint('[BackgroundTasks] Initializing notification plugin...');
    // Initialize if needed (for background context)
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: null,
    );
    debugPrint('[BackgroundTasks] Notification plugin initialized');
    
    // Send silent notification (no sound, no vibration)
    debugPrint('[BackgroundTasks] Showing notification for: $monthNameLatin');
    await plugin.show(
      999, // Notification ID for monthly refresh
      'Calendar Updated',
      'Fetched $monthNameLatin calendar',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'silent_channel',
          'Silent Updates',
          channelDescription: 'Silent notifications for background updates',
          importance: Importance.min,
          priority: Priority.min,
          silent: true,
          playSound: false,
          enableVibration: false,
          showWhen: false,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: false,
          presentBadge: false,
          presentSound: false,
        ),
      ),
    );
    debugPrint('[BackgroundTasks] Notification shown successfully');
  } catch (e) {
    debugPrint('[BackgroundTasks] Error sending notification: $e');
  }
}

/// Calculate initial delay for daily task to run at 12:01 AM
Duration _calculateInitialDelayFor2AM() {
  final now = DateTime.now();
  var twoAM = DateTime(now.year, now.month, now.day, 2, 0, 0);
  
  // If it's already past 2 AM, schedule for tomorrow at 2 AM
  if (now.isAfter(twoAM)) {
    twoAM = twoAM.add(const Duration(days: 1));
  }
  
  final delay = twoAM.difference(now);

  debugPrint('[BackgroundTasks] Daily task will first run in ${delay.inHours}h ${delay.inMinutes % 60}m (at 2:00 AM)');
  return delay;
}

/// Get last daily refresh time
Future<DateTime?> getLastDailyRefreshTime() async {
  final prefs = await SharedPreferences.getInstance();
  final timeStr = prefs.getString('lastDailyRefreshTime');
  if (timeStr != null) {
    return DateTime.parse(timeStr);
  }
  return null;
}

/// Get last monthly refresh time
Future<DateTime?> getLastMonthlyRefreshTime() async {
  final prefs = await SharedPreferences.getInstance();
  final timeStr = prefs.getString('lastMonthlyRefreshTime');
  if (timeStr != null) {
    return DateTime.parse(timeStr);
  }
  return null;
}

/// Check if daily refresh is pending
Future<bool> isDailyRefreshPending() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('needsDailyRefresh') ?? false;
}

/// Check if monthly refresh is pending
Future<bool> isMonthlyRefreshPending() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('needsMonthlyRefresh') ?? false;
}

/// Clear daily refresh flag
Future<void> clearDailyRefreshFlag() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('needsDailyRefresh');
}

/// Clear monthly refresh flag
Future<void> clearMonthlyRefreshFlag() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('needsMonthlyRefresh');
}

/// Calculate cache expiration date based on current cache state
/// Returns null if cache cannot be analyzed
Future<DateTime?> _calculateCacheExpirationDate(String cacheKey) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final cachedDataStr = prefs.getString(cacheKey);
    
    if (cachedDataStr == null) {
      debugPrint('[BackgroundTasks] No cache found, cannot calculate expiration');
      return null;
    }

    debugPrint('[BackgroundTasks] Parsing cache to find expiration date...');
    // Parse cache to find expiration
    final cachedDataMap = jsonDecode(cachedDataStr) as Map<String, dynamic>;
    
    // Try to parse Gregorian date keys first (new format: "2025-12-01T00:00:00.000")
    DateTime? maxDate;
    int dateKeysFound = 0;
    for (final key in cachedDataMap.keys) {
      if (key.startsWith('_')) continue;
      
      // Try to parse as ISO8601 datetime
      try {
        final parsedDate = DateTime.tryParse(key);
        if (parsedDate != null) {
          dateKeysFound++;
          debugPrint('[BackgroundTasks] Found Gregorian date key: $key -> $parsedDate');
          if (maxDate == null || parsedDate.isAfter(maxDate)) {
            maxDate = parsedDate;
          }
        }
      } catch (e) {
        // Not a date, continue
      }
    }
    
    if (maxDate != null) {
      debugPrint('[BackgroundTasks] ✓ Using Gregorian format - found $dateKeysFound date keys, max date: ${maxDate.year}-${maxDate.month}-${maxDate.day}');
      return maxDate;
    }
    
    debugPrint('[BackgroundTasks] No Gregorian dates found (found $dateKeysFound date keys)');
    
    // Fallback to Hijri day format (legacy)
    final now = DateTime.now();
    int hijriDayCount = 0;
    int? currentHijriDay;
    
    currentHijriDay = cachedDataMap['_currentHijriDay'] as int?;
    
    for (final key in cachedDataMap.keys) {
      if (key.startsWith('_')) continue;
      final dayNum = int.tryParse(key);
      if (dayNum != null && dayNum > 0 && dayNum < 32) {
        hijriDayCount++;
      }
    }

    if (hijriDayCount > 0 && currentHijriDay != null) {
      // Calculate based on Hijri days
      // Creation date = today - (currentHijriDay - 1)
      final daysBeforeToday = currentHijriDay - 1;
      final cacheCreationDate = now.subtract(Duration(days: daysBeforeToday));
      
      // Expiration = creation date + total days
      final expirationDate = cacheCreationDate.add(Duration(days: hijriDayCount));
      
      debugPrint('[BackgroundTasks] ✓ Using Hijri format - day $currentHijriDay of $hijriDayCount, expires ${expirationDate.year}-${expirationDate.month}-${expirationDate.day}');
      return expirationDate;
    }

    debugPrint('[BackgroundTasks] Could not determine cache expiration format (found $hijriDayCount hijri days)');
    return null;
  } catch (e) {
    debugPrint('[BackgroundTasks] Error calculating cache expiration: $e');
    return null;
  }
}

/// Reset background tasks initialization flag (for debugging/testing)
Future<void> resetBackgroundTasksInitializationFlag() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('backgroundTasksInitialized');
  debugPrint('[BackgroundTasks] Initialization flag reset - tasks will re-initialize on next app launch');
}

/// PUBLIC: Execute daily prayer refresh
/// Called by both WorkManager (periodic task) and test button
/// This is the single entry point for all daily refresh execution
Future<void> executeDailyPrayerRefresh() async {
  try {
    await _handleDailyPrayerRefresh();
  } catch (e, st) {
    debugPrint('[BackgroundTasks] ✗ Error in daily prayer refresh: $e');
    debugPrint('[BackgroundTasks] Stack: $st');
  }
}

/// Public wrapper to run the daily refresh task for testing purposes
/// Allows manual testing of the WorkManager daily refresh logic
@Deprecated('Use executeDailyPrayerRefresh() instead')
Future<void> handleDailyRefreshForTesting() async {
  return await executeDailyPrayerRefresh();
}

/// Schedule prayer time alarms for today's prayer times
/// Alarms are scheduled for prayer time + 1 minute for punctuality
/// This is called after fetching/calculating prayer times

/// Schedule prayer time alarms for today's prayer times
/// Alarms are scheduled for prayer time + 1 minute for punctuality
/// This is called after fetching/calculating prayer times
/// 
/// DEPRECATED: Use NotificationManager instead
@Deprecated('Use NotificationManager.scheduleNotificationsForTodaysPrayers() instead')
Future<void> schedulePrayerTimeAlarms(Map<String, String> prayerTimes) async {
  // This function is deprecated. Use NotificationManager instead.
  // Keeping for backwards compatibility if needed.
}


/// Handle prayer time alarm - triggers widget update
Future<void> _handlePrayerTimeAlarm(String taskName) async {
  try {
    final prayerName = taskName.replaceFirst(prayerTimeAlarmTaskPrefix, '');
    debugPrint('[BackgroundTasks:PrayerAlarm] ═════ PRAYER ALARM TRIGGERED: $prayerName ═════');
    debugPrint('[BackgroundTasks:PrayerAlarm] Time: ${DateTime.now()}');
    
    // Update widget to highlight this prayer time
    // The widget receives the prayer name and highlights it
    try {
      await WidgetCacheUpdater.updateCurrentPrayerHighlight(prayerName);
      debugPrint('[BackgroundTasks:PrayerAlarm] ✓ Widget updated to highlight: $prayerName');
    } catch (e) {
      debugPrint('[BackgroundTasks:PrayerAlarm] ⚠ Failed to update widget highlight: $e');
    }
    
    // Show optional notification for this prayer time
    try {
      await _showPrayerTimeNotification(prayerName);
      debugPrint('[BackgroundTasks:PrayerAlarm] ✓ Prayer time notification shown for $prayerName');
    } catch (e) {
      debugPrint('[BackgroundTasks:PrayerAlarm] ⚠ Failed to show notification: $e');
    }
    
    debugPrint('[BackgroundTasks:PrayerAlarm] ═════ END PRAYER ALARM ═════');
  } catch (e, st) {
    debugPrint('[BackgroundTasks:PrayerAlarm] ✗ Error in prayer alarm handler: $e');
    debugPrint('[BackgroundTasks:PrayerAlarm] Stack: $st');
  }
}

/// Show notification for prayer time alarm
/// DEPRECATED: Use NotificationManager instead
@Deprecated('Use NotificationManager instead')
Future<void> _showPrayerTimeNotification(String prayerName) async {
  // This function is deprecated. Use NotificationManager instead.
}

/// Cancel all old prayer time notifications
/// Prevents duplicate notifications when daily refresh reschedules prayer times
Future<void> _cancelOldPrayerNotifications() async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    
    // Get all pending notifications
    final pending = await plugin.pendingNotificationRequests();
    
    if (pending.isEmpty) {
      debugPrint('[BackgroundTasks] No pending notifications to cancel');
      return;
    }
    
    // Prayer names used to generate notification IDs
    final prayerNames = ['Fajr', 'Sunrise', 'Dhuhr', 'Asr', 'Maghrib', 'Isha'];
    
    int cancelledCount = 0;
    
    // Cancel notifications for each prayer
    for (final notification in pending) {
      // Check if this is a prayer notification (contains prayer name in title or is generated from prayer name hash)
      bool isPrayerNotification = false;
      
      for (final prayerName in prayerNames) {
        if (notification.title?.contains(prayerName) ?? false) {
          isPrayerNotification = true;
          break;
        }
      }
      
      if (isPrayerNotification) {
        try {
          await plugin.cancel(notification.id);
          debugPrint('[BackgroundTasks] ✓ Cancelled prayer notification ID: ${notification.id}');
          cancelledCount++;
        } catch (e) {
          debugPrint('[BackgroundTasks] Could not cancel notification ${notification.id}: $e');
        }
      }
    }
    
    debugPrint('[BackgroundTasks] Total prayer notifications cancelled: $cancelledCount');
  } catch (e, st) {
    debugPrint('[BackgroundTasks] Error cancelling old notifications: $e');
    debugPrint('[BackgroundTasks] Stack: $st');
  }
}

/// Get device timezone
tz.Location _getDeviceTimezone() {
  try {
    // Try to get system timezone
    final timeZoneName = DateTime.now().timeZoneName;
    try {
      return tz.getLocation(timeZoneName);
    } catch (e) {
      debugPrint('[BackgroundTasks] Could not find timezone "$timeZoneName", using UTC');
      return tz.UTC;
    }
  } catch (e) {
    debugPrint('[BackgroundTasks] Error getting device timezone: $e, using UTC');
    return tz.UTC;
  }
}

/// Get human-readable prayer label
/// DEPRECATED: No longer used - NotificationManager handles this
@Deprecated('No longer used')
String _getPrayerLabel(String prayerName) {
  switch (prayerName.toLowerCase()) {
    case 'fajr':
      return 'Fajr';
    case 'sunrise':
      return 'Sunrise';
    case 'dhuhr':
      return 'Dhuhr';
    case 'asr':
      return 'Asr';
    case 'maghrib':
      return 'Maghrib';
    case 'isha':
      return 'Isha';
    default:
      return prayerName;
  }
}

/// Get notification ID for prayer (ensures uniqueness)
/// DEPRECATED: No longer used - NotificationManager handles this
@Deprecated('No longer used')
int _getPrayerNotificationId(String prayerName) {
  switch (prayerName.toLowerCase()) {
    case 'fajr':
      return 1001;
    case 'sunrise':
      return 1002;
    case 'dhuhr':
      return 1003;
    case 'asr':
      return 1004;
    case 'maghrib':
      return 1005;
    case 'isha':
      return 1006;
    default:
      return 1099;
  }
}

/// TEST FUNCTION: Manually trigger monthly calendar refresh to test logic
/// Call this from UI or test code to simulate a monthly refresh cycle
Future<void> testMonthlyCalendarRefresh() async {
  debugPrint('[BackgroundTasks] [TEST] Starting manual monthly calendar refresh test...');
  await executeMonthlyCalendarRefresh();
}

/// TEST FUNCTION: Check current cache expiration date
Future<String> testGetCacheExpirationDate() async {
  final prefs = await SharedPreferences.getInstance();
  final expirationDateStr = prefs.getString('monthlyCalendarCacheExpirationDate') ?? 'NOT SET';
  debugPrint('[BackgroundTasks] [TEST] Current cache expiration date: $expirationDateStr');
  return expirationDateStr;
}

/// TEST FUNCTION: Manually set cache expiration to a past date to test refresh
/// This will make the periodic task execute the refresh logic on next run
Future<void> testSetCacheExpirationToPast() async {
  final prefs = await SharedPreferences.getInstance();
  final pastDate = DateTime.now().subtract(const Duration(days: 1)).toString();
  await prefs.setString('monthlyCalendarCacheExpirationDate', pastDate);
  debugPrint('[BackgroundTasks] [TEST] Cache expiration set to past date: $pastDate');
  debugPrint('[BackgroundTasks] [TEST] Next periodic task run will execute the refresh logic');
}

/// Notify Android widget to refresh after cache update
/// Sends a broadcast intent that reaches ALL registered widget instances
/// NOTE: This must work from background isolate, so we use a different approach
Future<void> notifyWidgetToRefresh() async {
  try {
    debugPrint('[BackgroundTasks] Triggering widget refresh via WorkManager...');
    
    // Since we're in a background isolate, we can't use MethodChannel.
    // Instead, we trigger the WidgetCacheUpdateWorker which will read the updated
    // cache from FlutterSharedPreferences and update the Android widgets.
    
    // Get the native method channel to call Android code
    try {
      const platform = MethodChannel('com.example.pray_time/widget');
      await platform.invokeMethod('enqueueWidgetUpdateWorker');
      debugPrint('[BackgroundTasks] ✓ Widget update worker enqueued via MethodChannel');
    } catch (e) {
      debugPrint('[BackgroundTasks] ⚠ MethodChannel failed: $e');
      // The worker may still run via other mechanisms, but log the failure
    }
    
  } catch (e) {
    debugPrint('[BackgroundTasks] ✗ FAILED to notify widgets: $e');
  }
}
