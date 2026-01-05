package com.example.pray_time

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.drawable.GradientDrawable
import android.util.Log
import android.widget.RemoteViews
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.ExistingWorkPolicy
import androidx.work.WorkManager
import com.google.gson.Gson
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/**
 * Prayer Widget Provider Horizontal - Handles the horizontal widget UI
 * 
 * This is a horizontal variant of PrayerWidgetProvider
 * Features:
 * - Displays 6 prayer times in a 2x3 grid layout
 * - Shows last update time
 * - Highlights the next upcoming prayer
 * - Manual refresh button
 * - Automatic highlight updates via AlarmManager
 */
class PrayerWidgetProviderHorizontal : AppWidgetProvider() {

    companion object {
        private const val DEBUG_TAG = "[PrayerWidget-H]"
        const val ACTION_MANUAL_REFRESH = "com.example.pray_time.ACTION_MANUAL_REFRESH_H"
        const val ACTION_UPDATE_PRAYER_HIGHLIGHT = "com.example.pray_time.ACTION_UPDATE_PRAYER_HIGHLIGHT_H"
        const val WIDGET_CACHE_KEY = "widget_info_cache"
        const val LAST_UPDATE_TIME_KEY = "widget_last_update_time"
        
        // Prayer time keys
        const val PRAYER_FAJR = "fajr"
        const val PRAYER_SUNRISE = "sunrise"
        const val PRAYER_DHUHR = "dhuhr"
        const val PRAYER_ASR = "asr"
        const val PRAYER_MAGHRIB = "maghrib"
        const val PRAYER_ISHA = "isha"
        
        private fun logDebug(message: String) {
            Log.d(DEBUG_TAG, message)
        }
        
        private fun logError(message: String, exception: Exception? = null) {
            Log.e(DEBUG_TAG, message, exception)
        }
        
        private fun isSystemDarkMode(context: Context): Boolean {
            val nightMode = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
            return nightMode == Configuration.UI_MODE_NIGHT_YES
        }
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        logDebug("onUpdate called for ${appWidgetIds.size} widgets")
        
        try {
            for (appWidgetId in appWidgetIds) {
                updateAppWidget(context, appWidgetManager, appWidgetId)
            }
        } catch (e: Exception) {
            logError("Error in onUpdate", e)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        logDebug(">>> onReceive called: Action=${intent.action}")
        
        try {
            when (intent.action) {
                ACTION_MANUAL_REFRESH -> {
                    logDebug("Manual refresh requested for horizontal widget")
                    val updateRequest = OneTimeWorkRequestBuilder<WidgetCacheUpdateWorker>()
                        .build()
                    WorkManager.getInstance(context).enqueueUniqueWork(
                        "widget_cache_update_horizontal",  // Unique ID for horizontal widget
                        ExistingWorkPolicy.KEEP,
                        updateRequest
                    )
                    logDebug("Horizontal widget worker enqueued with ID: widget_cache_update_horizontal")
                }
                ACTION_UPDATE_PRAYER_HIGHLIGHT -> {
                    handleHighlightUpdate(context)
                }
                else -> {
                    super.onReceive(context, intent)
                }
            }
        } catch (e: Exception) {
            logError("Error in onReceive", e)
            super.onReceive(context, intent)
        }
    }

    private fun handleHighlightUpdate(context: Context) {
        try {
            logDebug("handleHighlightUpdate: Updating widget UI")
            
            val appWidgetManager = AppWidgetManager.getInstance(context)
            val componentName = ComponentName(context, PrayerWidgetProviderHorizontal::class.java)
            val appWidgetIds = appWidgetManager.getAppWidgetIds(componentName)
            
            for (appWidgetId in appWidgetIds) {
                updateAppWidget(context, appWidgetManager, appWidgetId)
            }
            
            logDebug("handleHighlightUpdate: Updated ${appWidgetIds.size} widget(s)")
        } catch (e: Exception) {
            logError("Error updating highlight", e)
        }
    }

    private fun updateAppWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        try {
            logDebug("updateAppWidget: Updating widget $appWidgetId")
            
            val remoteViews = RemoteViews(context.packageName, R.layout.prayer_widget_horizontal)
            val sharedPreferences = context.getSharedPreferences("widget_prefs", Context.MODE_PRIVATE)
            
            // Get cached prayer times
            var cacheJson = sharedPreferences.getString(WIDGET_CACHE_KEY, null)
            
            // If not found in widget_prefs, try reading from Dart's FlutterSharedPreferences
            if (cacheJson == null) {
                logDebug("updateAppWidget: Not found in widget_prefs, trying FlutterSharedPreferences")
                try {
                    val flutterPrefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    cacheJson = flutterPrefs.getString("flutter.widget_info_cache", null)
                    if (cacheJson != null) {
                        logDebug("updateAppWidget: Found in FlutterSharedPreferences")
                    }
                } catch (e: Exception) {
                    logError("updateAppWidget: Error reading from FlutterSharedPreferences", e)
                }
            }
            
            // Parse the cache JSON into proper data class
            var cacheData: WidgetCacheData? = null
            var prayerTimes: Map<String, String>? = null
            
            if (cacheJson != null) {
                try {
                    val gson = Gson()
                    cacheData = gson.fromJson(cacheJson, WidgetCacheData::class.java)
                    
                    // FIX: If bgTransparency is 0 or null, check if it should be from the JSON
                    if (cacheData.bgTransparency <= 0.0) {
                        try {
                            val jsonObj = gson.fromJson(cacheJson, com.google.gson.JsonObject::class.java)
                            val bgTransparencyFromJson = jsonObj.get("bgTransparency")
                            if (bgTransparencyFromJson != null && !bgTransparencyFromJson.isJsonNull) {
                                logDebug("updateAppWidget: bgTransparency found in JSON: ${bgTransparencyFromJson.asDouble}")
                                cacheData = WidgetCacheData(
                                    fajr = cacheData.fajr,
                                    sunrise = cacheData.sunrise,
                                    dhuhr = cacheData.dhuhr,
                                    asr = cacheData.asr,
                                    maghrib = cacheData.maghrib,
                                    isha = cacheData.isha,
                                    source = cacheData.source,
                                    location = cacheData.location,
                                    hue = cacheData.hue,
                                    isDarkMode = cacheData.isDarkMode,
                                    bgTransparency = bgTransparencyFromJson.asDouble,
                                    cacheDateDdMmYyyy = cacheData.cacheDateDdMmYyyy,
                                    cacheTimestampMs = cacheData.cacheTimestampMs
                                )
                            } else {
                                logDebug("updateAppWidget: bgTransparency NOT found in JSON, using default 1.0")
                                cacheData = WidgetCacheData(
                                    fajr = cacheData.fajr,
                                    sunrise = cacheData.sunrise,
                                    dhuhr = cacheData.dhuhr,
                                    asr = cacheData.asr,
                                    maghrib = cacheData.maghrib,
                                    isha = cacheData.isha,
                                    source = cacheData.source,
                                    location = cacheData.location,
                                    hue = cacheData.hue,
                                    isDarkMode = cacheData.isDarkMode,
                                    bgTransparency = 1.0,
                                    cacheDateDdMmYyyy = cacheData.cacheDateDdMmYyyy,
                                    cacheTimestampMs = cacheData.cacheTimestampMs
                                )
                            }
                        } catch (parseErr: Exception) {
                            logDebug("updateAppWidget: Could not parse bgTransparency separately: ${parseErr.message}")
                        }
                    }
                    
                    logDebug("updateAppWidget: Cache parsed successfully")
                    
                    // Create prayer times map for backward compatibility
                    prayerTimes = mapOf(
                        "fajr" to cacheData!!.fajr,
                        "sunrise" to cacheData!!.sunrise,
                        "dhuhr" to cacheData!!.dhuhr,
                        "asr" to cacheData!!.asr,
                        "maghrib" to cacheData!!.maghrib,
                        "isha" to cacheData!!.isha,
                        "location" to cacheData!!.location,
                        "isDarkMode" to cacheData!!.isDarkMode.toString(),
                        "hue" to cacheData!!.hue.toString()
                    )
                } catch (e: Exception) {
                    logError("updateAppWidget: Error parsing prayer times JSON: ${e.message}", e)
                    cacheData = null
                    prayerTimes = null
                }
            } else {
                logDebug("updateAppWidget: No cached prayer times found")
            }
            
            // Extract location and theme from cache
            var location = "--"
            var isDarkMode = false
            var primaryHue = 0.0
            var bgTransparency = 1.0
            
            if (cacheData != null) {
                location = cacheData.location
                isDarkMode = cacheData.isDarkMode
                primaryHue = cacheData.hue
                bgTransparency = cacheData.bgTransparency
                logDebug("updateAppWidget: [CACHE-READ] PRIMARY HUE=$primaryHue, isDarkMode=$isDarkMode, location=$location, bgTransparency=$bgTransparency")
            } else if (prayerTimes != null) {
                location = prayerTimes["location"] ?: "--"
                isDarkMode = (prayerTimes["isDarkMode"] ?: "false").toBoolean()
                primaryHue = (prayerTimes["hue"] ?: "0.0").toDoubleOrNull() ?: 0.0
                logDebug("updateAppWidget: [CACHE-READ] PRIMARY HUE=$primaryHue, isDarkMode=$isDarkMode, location=$location (from prayerTimes)")
            }
            
            // Check if theme is set to "system" mode and detect actual system dark mode
            try {
                val flutterPrefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                val themeMode = flutterPrefs.getString("flutter.themeMode", "light")
                if (themeMode == "system") {
                    isDarkMode = isSystemDarkMode(context)
                    logDebug("updateAppWidget: Theme mode is 'system', detected isDarkMode=$isDarkMode")
                }
            } catch (e: Exception) {
                logDebug("updateAppWidget: Could not detect system theme mode: ${e.message}")
            }
            
            // SAFEGUARD: If bgTransparency is still at default, try to read it directly from FlutterSharedPreferences
            if (bgTransparency <= 0.0) {
                try {
                    val flutterPrefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    val savedBgTransparency = flutterPrefs.getFloat("flutter.widgetBgTransparency", -1f)
                    if (savedBgTransparency > 0.0f) {
                        bgTransparency = savedBgTransparency.toDouble()
                        logDebug("updateAppWidget: bgTransparency read from FlutterSharedPreferences (float): $bgTransparency")
                    } else {
                        val bgTransparencyStr = flutterPrefs.getString("flutter.widgetBgTransparency", null)
                        if (!bgTransparencyStr.isNullOrEmpty()) {
                            bgTransparency = bgTransparencyStr.toDoubleOrNull() ?: 1.0
                            logDebug("updateAppWidget: bgTransparency read from FlutterSharedPreferences (string): $bgTransparency")
                        } else {
                            logDebug("updateAppWidget: bgTransparency not found in FlutterSharedPreferences, using default 1.0")
                            bgTransparency = 1.0
                        }
                    }
                } catch (e: Exception) {
                    logDebug("updateAppWidget: Could not read bgTransparency from FlutterSharedPreferences: ${e.message}, using default 1.0")
                    bgTransparency = 1.0
                }
            }
            
            logDebug("updateAppWidget: Location: $location, Dark Mode: $isDarkMode, Hue: $primaryHue, BG Transparency: $bgTransparency")
            
            // Get color scheme based on user's hue and theme preference
            val colors = ColorScheme.getColors(primaryHue, isDarkMode)
            logDebug("updateAppWidget: Colors generated - BG: ${String.format("0x%08X", colors.containerBg)}, Accent: ${String.format("0x%08X", colors.accentColor)}")
            
            // Apply dynamic colors to widget with transparency
            applyThemeColorsHorizontal(remoteViews, colors, bgTransparency)
            
            // Apply location text and date/time
            remoteViews.setTextViewText(R.id.widget_location_h, location)
            val dateTime = SimpleDateFormat("dd/MM/yyyy • HH:mm", Locale.getDefault()).format(System.currentTimeMillis())
            remoteViews.setTextViewText(R.id.widget_date_time_h, dateTime)
            logDebug("updateAppWidget: Location set to: $location, Date/Time: $dateTime")
            
            // Set prayer times from cache or use test data
            if (cacheData != null) {
                remoteViews.setTextViewText(R.id.prayer_fajr_time_h, cacheData.fajr)
                remoteViews.setTextViewText(R.id.prayer_sunrise_time_h, cacheData.sunrise)
                remoteViews.setTextViewText(R.id.prayer_dhuhr_time_h, cacheData.dhuhr)
                remoteViews.setTextViewText(R.id.prayer_asr_time_h, cacheData.asr)
                remoteViews.setTextViewText(R.id.prayer_maghrib_time_h, cacheData.maghrib)
                remoteViews.setTextViewText(R.id.prayer_isha_time_h, cacheData.isha)
            } else {
                // Use test data
                remoteViews.setTextViewText(R.id.prayer_fajr_time_h, "04:30")
                remoteViews.setTextViewText(R.id.prayer_sunrise_time_h, "06:15")
                remoteViews.setTextViewText(R.id.prayer_dhuhr_time_h, "12:45")
                remoteViews.setTextViewText(R.id.prayer_asr_time_h, "15:30")
                remoteViews.setTextViewText(R.id.prayer_maghrib_time_h, "18:20")
                remoteViews.setTextViewText(R.id.prayer_isha_time_h, "19:45")
            }
            
            // Get current time to determine which prayer is next
            val calendar = Calendar.getInstance()
            val currentTime = String.format("%02d:%02d", calendar.get(Calendar.HOUR_OF_DAY), calendar.get(Calendar.MINUTE))
            
            // Create prayer times map for highlighting calculation
            val prayerTimesMap = mapOf(
                PRAYER_FAJR to (cacheData?.fajr ?: "04:30"),
                PRAYER_SUNRISE to (cacheData?.sunrise ?: "06:15"),
                PRAYER_DHUHR to (cacheData?.dhuhr ?: "12:45"),
                PRAYER_ASR to (cacheData?.asr ?: "15:30"),
                PRAYER_MAGHRIB to (cacheData?.maghrib ?: "18:20"),
                PRAYER_ISHA to (cacheData?.isha ?: "19:45")
            )
            
            // Calculate next prayer
            val nextPrayer = calculateNextPrayer(prayerTimesMap)
            if (nextPrayer != null) {
                logDebug("updateAppWidget: Next prayer is ${nextPrayer.first} at ${nextPrayer.second}")
                highlightNextPrayerCardHorizontal(remoteViews, nextPrayer.first, colors)
                // Schedule next highlight update at prayer time
                scheduleNextHighlightUpdate(context, nextPrayer.second)
            } else {
                logDebug("updateAppWidget: Could not determine next prayer")
            }
            
            // Refresh button
            val refreshIntent = Intent(context, PrayerWidgetProviderHorizontal::class.java).apply {
                action = ACTION_MANUAL_REFRESH
                setPackage(context.packageName)  // Ensure broadcast goes to this package
            }
            val refreshPendingIntent = PendingIntent.getBroadcast(
                context,
                1002,  // Use unique ID for refresh button (horizontal)
                refreshIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            remoteViews.setOnClickPendingIntent(R.id.widget_refresh_button_h, refreshPendingIntent)
            
            appWidgetManager.updateAppWidget(appWidgetId, remoteViews)
            logDebug("updateAppWidget: Widget updated successfully")
        } catch (e: Exception) {
            logError("Error updating widget", e)
        }
    }

    private fun calculateNextPrayer(prayerTimes: Map<String, String>): Pair<String, String>? {
        try {
            logDebug("calculateNextPrayer: Calculating next prayer")
            
            val timeFormatter = SimpleDateFormat("HH:mm", Locale.getDefault())
            val now = Calendar.getInstance()
            val currentTimeInMinutes = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)
            
            logDebug("calculateNextPrayer: Current time: ${timeFormatter.format(now.time)} ($currentTimeInMinutes minutes)")
            
            // Prayer order for the day
            val prayerOrder = listOf(
                PRAYER_FAJR to "Fajr",
                PRAYER_SUNRISE to "Sunrise",
                PRAYER_DHUHR to "Dhuhr",
                PRAYER_ASR to "Asr",
                PRAYER_MAGHRIB to "Maghrib",
                PRAYER_ISHA to "Isha"
            )
            
            // Find next prayer
            var nextPrayer: Pair<String, String>? = null
            var minTimeDiff = Int.MAX_VALUE
            
            for ((key, name) in prayerOrder) {
                val timeStr = prayerTimes[key] ?: continue
                try {
                    val timeParts = timeStr.split(":")
                    if (timeParts.size != 2) {
                        logDebug("calculateNextPrayer: Invalid time format for $name: $timeStr")
                        continue
                    }
                    
                    val hour = timeParts[0].toIntOrNull() ?: continue
                    val minute = timeParts[1].toIntOrNull() ?: continue
                    val prayerTimeInMinutes = hour * 60 + minute
                    
                    val timeDiff = prayerTimeInMinutes - currentTimeInMinutes
                    
                    logDebug("calculateNextPrayer: $name at $timeStr ($prayerTimeInMinutes min), diff=$timeDiff")
                    
                    // Find the next prayer (time > current time with smallest difference)
                    if (timeDiff > 0 && timeDiff < minTimeDiff) {
                        minTimeDiff = timeDiff
                        nextPrayer = Pair(name, timeStr)
                        logDebug("calculateNextPrayer: New next prayer: $name at $timeStr")
                    }
                } catch (e: Exception) {
                    logError("calculateNextPrayer: Error parsing time for $name", e)
                }
            }
            
            // If no prayer found today, return first prayer tomorrow (Fajr)
            if (nextPrayer == null) {
                nextPrayer = Pair("Fajr", prayerTimes[PRAYER_FAJR] ?: "--:--")
                logDebug("calculateNextPrayer: No prayer found today, returning tomorrow's Fajr")
            }
            
            return nextPrayer
        } catch (e: Exception) {
            logError("calculateNextPrayer: Error calculating next prayer", e)
            return null
        }
    }

    private fun highlightNextPrayerCardHorizontal(remoteViews: RemoteViews, nextPrayerName: String, colors: ColorPalette) {
        logDebug("highlightNextPrayerCardHorizontal: Highlighting $nextPrayerName")
        logDebug("highlightNextPrayerCardHorizontal: highlightBg = ${String.format("0x%08X", colors.highlightBg)}")
        logDebug("highlightNextPrayerCardHorizontal: highlightText = ${String.format("0x%08X", colors.highlightText)}")
        
        // Map prayer names to card background image IDs and text IDs
        val cardMap = mapOf(
            "Fajr" to Triple(R.id.card_fajr_bg_h, R.id.label_fajr_h, R.id.prayer_fajr_time_h),
            "Sunrise" to Triple(R.id.card_sunrise_bg_h, R.id.label_sunrise_h, R.id.prayer_sunrise_time_h),
            "Dhuhr" to Triple(R.id.card_dhuhr_bg_h, R.id.label_dhuhr_h, R.id.prayer_dhuhr_time_h),
            "Asr" to Triple(R.id.card_asr_bg_h, R.id.label_asr_h, R.id.prayer_asr_time_h),
            "Maghrib" to Triple(R.id.card_maghrib_bg_h, R.id.label_maghrib_h, R.id.prayer_maghrib_time_h),
            "Isha" to Triple(R.id.card_isha_bg_h, R.id.label_isha_h, R.id.prayer_isha_time_h)
        )
        
        // Reset all cards to regular color
        for ((prayerName, ids) in cardMap) {
            try {
                val bgId = ids.first
                val labelId = ids.second
                val timeId = ids.third
                
                val bitmap = createRoundedRectBitmap(colors.containerBgSecondary, 300, 250, 16f)
                remoteViews.setImageViewBitmap(bgId, bitmap)
                remoteViews.setTextColor(labelId, colors.prayerLabelText)
                remoteViews.setTextColor(timeId, colors.prayerTimeText)
                
                logDebug("highlightNextPrayerCardHorizontal: Reset $prayerName to ${String.format("0x%08X", colors.containerBgSecondary)}")
            } catch (e: Exception) {
                logDebug("highlightNextPrayerCardHorizontal: Error resetting card for $prayerName: ${e.message}")
            }
        }
        
        // Highlight the next prayer
        val nextCardIds = cardMap[nextPrayerName]
        if (nextCardIds != null) {
            try {
                val bgId = nextCardIds.first
                val labelId = nextCardIds.second
                val timeId = nextCardIds.third
                
                val bitmap = createRoundedRectBitmap(colors.highlightBg, 300, 250, 16f)
                remoteViews.setImageViewBitmap(bgId, bitmap)
                remoteViews.setTextColor(labelId, colors.highlightText)
                remoteViews.setTextColor(timeId, colors.highlightText)
                
                logDebug("highlightNextPrayerCardHorizontal: Set $nextPrayerName to ${String.format("0x%08X", colors.highlightBg)} with text ${String.format("0x%08X", colors.highlightText)}")
            } catch (e: Exception) {
                logDebug("highlightNextPrayerCardHorizontal: Error highlighting $nextPrayerName: ${e.message}")
            }
        } else {
            logDebug("highlightNextPrayerCardHorizontal: ERROR - $nextPrayerName not found in cardMap")
        }
    }

    private fun applyThemeColorsHorizontal(
        remoteViews: RemoteViews,
        colors: ColorPalette,
        bgTransparency: Double
    ) {
        try {
            logDebug("applyThemeColorsHorizontal: Applying colors to widget elements with bgTransparency=$bgTransparency")
            
            // Apply main widget root background with transparency
            try {
                val alphaValue = (bgTransparency * 255).toInt()
                val rootColorWithAlpha = (alphaValue shl 24) or (colors.containerBg and 0x00FFFFFF)
                
                val rootBitmap = createSolidColorBitmap(rootColorWithAlpha)
                remoteViews.setImageViewBitmap(R.id.widget_root_bg_h, rootBitmap)
                logDebug("applyThemeColorsHorizontal: Root background set to ${String.format("0x%08X", rootColorWithAlpha)} with transparency=$bgTransparency")
            } catch (e: Exception) {
                logDebug("applyThemeColorsHorizontal: Could not set root background: ${e.message}")
            }
            
            // Create background bitmaps for each card with rounded corners and colors
            val cardBackgrounds = listOf(
                R.id.card_fajr_bg_h to colors.containerBgSecondary,
                R.id.card_sunrise_bg_h to colors.containerBgSecondary,
                R.id.card_dhuhr_bg_h to colors.containerBgSecondary,
                R.id.card_asr_bg_h to colors.containerBgSecondary,
                R.id.card_maghrib_bg_h to colors.containerBgSecondary,
                R.id.card_isha_bg_h to colors.containerBgSecondary
            )
            
            for ((bgId, color) in cardBackgrounds) {
                try {
                    val bitmap = createRoundedRectBitmap(color, 300, 250, 16f)
                    remoteViews.setImageViewBitmap(bgId, bitmap)
                    logDebug("applyThemeColorsHorizontal: Set card background to ${String.format("0x%08X", color)}")
                } catch (e: Exception) {
                    logDebug("applyThemeColorsHorizontal: Error setting card background: ${e.message}")
                }
            }
            
            // Apply header background with rounded corners
            try {
                val headerBitmap = createRoundedRectBitmap(colors.headerBg, 1000, 150, 20f)
                remoteViews.setImageViewBitmap(R.id.widget_header_bg_h, headerBitmap)
                logDebug("applyThemeColorsHorizontal: Header background set to ${String.format("0x%08X", colors.headerBg)}")
            } catch (e: Exception) {
                logDebug("applyThemeColorsHorizontal: Could not set header background: ${e.message}")
            }
            
            // Apply text colors
            remoteViews.setTextColor(R.id.widget_location_h, colors.headerText)
            remoteViews.setTextColor(R.id.widget_date_time_h, colors.containerTextSecondary)
            remoteViews.setTextColor(R.id.widget_refresh_button_h, colors.headerText)
            
            // Apply prayer label colors
            val labelIds = listOf(
                R.id.label_fajr_h,
                R.id.label_sunrise_h,
                R.id.label_dhuhr_h,
                R.id.label_asr_h,
                R.id.label_maghrib_h,
                R.id.label_isha_h
            )
            
            for (labelId in labelIds) {
                remoteViews.setTextColor(labelId, colors.prayerLabelText)
            }
            
            // Apply prayer time value colors
            val timeIds = listOf(
                R.id.prayer_fajr_time_h,
                R.id.prayer_sunrise_time_h,
                R.id.prayer_dhuhr_time_h,
                R.id.prayer_asr_time_h,
                R.id.prayer_maghrib_time_h,
                R.id.prayer_isha_time_h
            )
            
            for (timeId in timeIds) {
                remoteViews.setTextColor(timeId, colors.prayerTimeText)
            }
            
            logDebug("applyThemeColorsHorizontal: All colors applied successfully")
        } catch (e: Exception) {
            logError("Error applying theme colors", e)
        }
    }

    private fun createSolidColorBitmap(color: Int): android.graphics.Bitmap {
        val bitmap = android.graphics.Bitmap.createBitmap(1, 1, android.graphics.Bitmap.Config.ARGB_8888)
        bitmap.setPixel(0, 0, color)
        logDebug("createSolidColorBitmap: Created 1x1 bitmap with color ${String.format("0x%08X", color)}, alpha=${color ushr 24}")
        return bitmap
    }

    private fun createRoundedRectBitmap(color: Int, width: Int, height: Int, radiusDp: Float): android.graphics.Bitmap {
        val bitmap = android.graphics.Bitmap.createBitmap(width, height, android.graphics.Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        
        val alpha = (color shr 24) and 0xFF
        logDebug("createRoundedRectBitmap: Creating bitmap with color=${String.format("0x%08X", color)}, alpha=$alpha, width=$width, height=$height")
        
        val drawable = GradientDrawable()
        drawable.shape = GradientDrawable.RECTANGLE
        drawable.cornerRadius = radiusDp
        drawable.setColor(color)
        
        drawable.setBounds(0, 0, width, height)
        drawable.draw(canvas)
        
        logDebug("createRoundedRectBitmap: Bitmap created successfully")
        return bitmap
    }

    private fun isNextPrayer(currentTime: String, prayerTime: String): Boolean {
        return try {
            val sdf = SimpleDateFormat("HH:mm", Locale.getDefault())
            val current = sdf.parse(currentTime) ?: return false
            val prayer = sdf.parse(prayerTime) ?: return false
            current.before(prayer)
        } catch (e: Exception) {
            logError("Error comparing times", e)
            false
        }
    }

    /**
     * Schedule the next highlight update via AlarmManager
     */
    private fun scheduleNextHighlightUpdate(context: Context, nextPrayerTime: String) {
        try {
            logDebug("scheduleNextHighlightUpdate: Scheduling for $nextPrayerTime")
            
            val timeParts = nextPrayerTime.split(":")
            if (timeParts.size != 2) {
                logError("scheduleNextHighlightUpdate: Invalid time format: $nextPrayerTime")
                return
            }
            
            val hour = timeParts[0].toIntOrNull()
            val minute = timeParts[1].toIntOrNull()
            
            if (hour == null || minute == null) {
                logError("scheduleNextHighlightUpdate: Could not parse hour/minute")
                return
            }
            
            val calendar = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, hour)
                set(Calendar.MINUTE, minute)
                set(Calendar.SECOND, 0)
            }
            
            // If the time has already passed today, schedule for tomorrow
            if (calendar.timeInMillis < System.currentTimeMillis()) {
                calendar.add(Calendar.DAY_OF_MONTH, 1)
                logDebug("scheduleNextHighlightUpdate: Time passed, scheduling for tomorrow")
            }
            
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            if (alarmManager == null) {
                logError("scheduleNextHighlightUpdate: AlarmManager not available")
                return
            }
            
            val intent = Intent(context, PrayerWidgetProviderHorizontal::class.java).apply {
                action = ACTION_UPDATE_PRAYER_HIGHLIGHT
            }
            
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                101,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            
            try {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    calendar.timeInMillis,
                    pendingIntent
                )
                logDebug("scheduleNextHighlightUpdate: Alarm scheduled for ${calendar.time}")
            } catch (e: SecurityException) {
                logError("scheduleNextHighlightUpdate: SCHEDULE_EXACT_ALARM permission denied", e)
                // Fallback to inexact alarm
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    calendar.timeInMillis,
                    pendingIntent
                )
                logDebug("scheduleNextHighlightUpdate: Using inexact alarm as fallback")
            }
        } catch (e: Exception) {
            logError("Error scheduling highlight update", e)
        }
    }
}
