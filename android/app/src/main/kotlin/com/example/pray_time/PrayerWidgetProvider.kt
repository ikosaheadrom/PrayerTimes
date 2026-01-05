package com.example.pray_time

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.ExistingWorkPolicy
import androidx.work.WorkManager
import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import com.google.gson.JsonObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/**
 * Prayer Widget Provider - Handles the widget UI and user interactions
 * 
 * Features:
 * - Displays 6 prayer times (Fajr, Sunrise, Dhuhr, Asr, Maghrib, Isha)
 * - Shows last update time
 * - Highlights the next upcoming prayer
 * - Manual refresh button
 * - Automatic highlight updates via AlarmManager
 */
class PrayerWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val DEBUG_TAG = "[PrayerWidget]"
        const val ACTION_MANUAL_REFRESH = "com.example.pray_time.ACTION_MANUAL_REFRESH"
        const val ACTION_UPDATE_PRAYER_HIGHLIGHT = "com.example.pray_time.ACTION_UPDATE_PRAYER_HIGHLIGHT"
        const val WIDGET_CACHE_KEY = "widget_info_cache"
        const val LAST_UPDATE_TIME_KEY = "widget_last_update_time"
        const val WIDGET_LAYOUT_KEY = "widget_layout_" // Prefix for storing layout type per widget ID
        
        // Prayer time keys
        const val PRAYER_FAJR = "fajr"
        const val PRAYER_SUNRISE = "sunrise"
        const val PRAYER_DHUHR = "dhuhr"
        const val PRAYER_ASR = "asr"
        const val PRAYER_MAGHRIB = "maghrib"
        const val PRAYER_ISHA = "isha"
        
        // Layout types
        const val LAYOUT_MINIMAL = "minimal"
        const val LAYOUT_HORIZONTAL = "horizontal"
        
        /**
         * Trigger widget refresh from Dart side (via MethodChannel)
         * Called when the app has new prayer times to display
         */
        fun triggerWidgetRefresh(context: Context) {
            logDebug("triggerWidgetRefresh: Widget refresh triggered from Dart")
            
            // Trigger the worker to save updated cache and refresh widget
            val updateRequest = OneTimeWorkRequestBuilder<WidgetCacheUpdateWorker>()
                .build()
            
            WorkManager.getInstance(context).enqueueUniqueWork(
                "widget_cache_update",
                ExistingWorkPolicy.KEEP,
                updateRequest
            )
        }
        
        private fun getCurrentTimeString(): String {
            return SimpleDateFormat("HH:mm", Locale.getDefault()).format(System.currentTimeMillis())
        }
        
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

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle
    ) {
        logDebug("onAppWidgetOptionsChanged called for widget $appWidgetId")
        
        // Detect layout based on widget dimensions
        val minWidth = newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
        val minHeight = newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)
        val maxWidth = newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH)
        val maxHeight = newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)
        
        logDebug("onAppWidgetOptionsChanged: minWidth=$minWidth, minHeight=$minHeight, maxWidth=$maxWidth, maxHeight=$maxHeight")
        
        // Determine layout: if width is significantly larger than height, it's horizontal
        val isHorizontal = maxWidth > maxHeight
        val layoutType = if (isHorizontal) LAYOUT_HORIZONTAL else LAYOUT_MINIMAL
        
        // Store layout preference for this widget
        val prefs = context.getSharedPreferences("widget_prefs", Context.MODE_PRIVATE)
        prefs.edit().putString("${WIDGET_LAYOUT_KEY}${appWidgetId}", layoutType).apply()
        
        logDebug("onAppWidgetOptionsChanged: Stored layout type '$layoutType' for widget $appWidgetId")
        
        // Update the widget with the correct layout
        updateAppWidget(context, appWidgetManager, appWidgetId)
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        super.onReceive(context, intent)
        
        if (context == null || intent == null) {
            logError("onReceive: context or intent is null")
            return
        }

        logDebug("onReceive: action=${intent.action}")

        try {
            when (intent.action) {
                ACTION_MANUAL_REFRESH -> {
                    logDebug("Manual refresh requested")
                    handleManualRefresh(context)
                }
                ACTION_UPDATE_PRAYER_HIGHLIGHT -> {
                    logDebug("Highlight update from AlarmManager")
                    handleHighlightUpdate(context)
                }
            }
        } catch (e: Exception) {
            logError("Error in onReceive", e)
        }
    }

    /**
     * Handle manual refresh button click
     * Triggers WorkManager to fetch fresh prayer times from Dart
     */
    private fun handleManualRefresh(context: Context) {
        try {
            logDebug("handleManualRefresh: Enqueuing worker with ID: widget_cache_update_vertical")
            // Enqueue worker to fetch fresh data with unique ID
            val updateRequest = OneTimeWorkRequestBuilder<WidgetCacheUpdateWorker>()
                .build()
            
            WorkManager.getInstance(context).enqueueUniqueWork(
                "widget_cache_update_vertical",  // Unique ID for vertical widget
                ExistingWorkPolicy.KEEP,  // KEEP policy - don't interfere with horizontal
                updateRequest
            )
            logDebug("handleManualRefresh: Worker enqueued successfully")
            
        } catch (e: Exception) {
            logError("[ManualRefresh] Error", e)
        }
    }

    /**
     * Comprehensive logging of widget cache status
     */
    private fun logWidgetCacheStatus(context: Context) {
        try {
            val sharedPrefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val widgetPrefs = context.getSharedPreferences("widget_prefs", Context.MODE_PRIVATE)
            
            logDebug("──── SharedPreferences Status ────")
            
            // Check flutter SharedPreferences
            logDebug("FlutterSharedPreferences keys: ${sharedPrefs.all.keys.toList()}")
            
            val flutterWidgetCache = sharedPrefs.getString("flutter.$WIDGET_CACHE_KEY", null)
            if (flutterWidgetCache != null) {
                logDebug("✓ Found 'flutter.$WIDGET_CACHE_KEY' in FlutterSharedPreferences")
                logDebug("  Value: ${flutterWidgetCache.take(200)}...")
                
                try {
                    val gson = Gson()
                    val cacheData = gson.fromJson(flutterWidgetCache, Map::class.java)
                    logDebug("  Parsed JSON keys: ${cacheData.keys.toList()}")
                    logDebug("  Fajr: ${cacheData["fajr"]}")
                    logDebug("  Sunrise: ${cacheData["sunrise"]}")
                    logDebug("  Dhuhr: ${cacheData["dhuhr"]}")
                    logDebug("  Asr: ${cacheData["asr"]}")
                    logDebug("  Maghrib: ${cacheData["maghrib"]}")
                    logDebug("  Isha: ${cacheData["isha"]}")
                    logDebug("  Source: ${cacheData["source"]}")
                    logDebug("  Location: ${cacheData["location"]}")
                    logDebug("  CacheDate: ${cacheData["cacheDateDdMmYyyy"]}")
                } catch (e: Exception) {
                    logError("Failed to parse flutter.$WIDGET_CACHE_KEY JSON", e)
                }
            } else {
                logDebug("✗ 'flutter.$WIDGET_CACHE_KEY' NOT found in FlutterSharedPreferences")
            }
            
            // Check widget_prefs
            logDebug("")
            logDebug("widget_prefs keys: ${widgetPrefs.all.keys.toList()}")
            
            val widgetCacheData = widgetPrefs.getString(WIDGET_CACHE_KEY, null)
            if (widgetCacheData != null) {
                logDebug("✓ Found '$WIDGET_CACHE_KEY' in widget_prefs")
                logDebug("  Value: ${widgetCacheData.take(200)}...")
                
                try {
                    val gson = Gson()
                    val cacheData = gson.fromJson(widgetCacheData, Map::class.java)
                    logDebug("  Parsed JSON keys: ${cacheData.keys.toList()}")
                    logDebug("  Fajr: ${cacheData["fajr"]}")
                    logDebug("  Sunrise: ${cacheData["sunrise"]}")
                    logDebug("  Dhuhr: ${cacheData["dhuhr"]}")
                    logDebug("  Asr: ${cacheData["asr"]}")
                    logDebug("  Maghrib: ${cacheData["maghrib"]}")
                    logDebug("  Isha: ${cacheData["isha"]}")
                    logDebug("  Source: ${cacheData["source"]}")
                    logDebug("  Location: ${cacheData["location"]}")
                } catch (e: Exception) {
                    logError("Failed to parse widget_prefs JSON", e)
                }
            } else {
                logDebug("✗ '$WIDGET_CACHE_KEY' NOT found in widget_prefs")
            }
            
            // widget_last_update_time is stored as Long (milliseconds), not String
            try {
                val lastUpdateTimeMs = widgetPrefs.getLong(LAST_UPDATE_TIME_KEY, 0L)
                if (lastUpdateTimeMs > 0L) {
                    val sdf = java.text.SimpleDateFormat("dd/MM/yyyy HH:mm", java.util.Locale.getDefault())
                    val formattedTime = sdf.format(java.util.Date(lastUpdateTimeMs))
                    logDebug("✓ Last update time: $formattedTime (${lastUpdateTimeMs}ms)")
                } else {
                    logDebug("✗ Last update time: NOT SET")
                }
            } catch (e: Exception) {
                logDebug("⚠ Could not read last update time: ${e.message}")
            }
            
            logDebug("──── End Status ────")
        } catch (e: Exception) {
            logError("Error logging widget cache status", e)
        }
    }

    /**
     * Handle highlight update from AlarmManager
     * Updates the UI to highlight the next prayer
     */
    private fun handleHighlightUpdate(context: Context) {
        try {
            logDebug("handleHighlightUpdate: Updating widget UI")
            
            val appWidgetManager = AppWidgetManager.getInstance(context)
            val componentName = ComponentName(context, PrayerWidgetProvider::class.java)
            val appWidgetIds = appWidgetManager.getAppWidgetIds(componentName)
            
            for (appWidgetId in appWidgetIds) {
                updateAppWidget(context, appWidgetManager, appWidgetId)
            }
            
            logDebug("handleHighlightUpdate: Updated ${appWidgetIds.size} widget(s)")
        } catch (e: Exception) {
            logError("Error updating highlight", e)
        }
    }

    /**
     * Update the widget UI with prayer times and highlighting
     */
    private fun updateAppWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        try {
            logDebug("updateAppWidget: Updating widget $appWidgetId")
            logDebug("updateAppWidget: Package name=${context.packageName}")
            logDebug("updateAppWidget: Creating RemoteViews with R.layout.prayer_widget_minimal")
            
            val remoteViews = RemoteViews(context.packageName, R.layout.prayer_widget_minimal)
            logDebug("updateAppWidget: RemoteViews created successfully with prayer_widget_minimal layout")
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
                    logDebug("updateAppWidget: DEBUG - Cache JSON before parsing: ${cacheJson.take(300)}")
                    cacheData = gson.fromJson(cacheJson, WidgetCacheData::class.java)
                    
                    // FIX: If bgTransparency is 0 or null, check if it should be from the JSON
                    // This handles the case where Gson doesn't apply default values for missing fields
                    if (cacheData.bgTransparency <= 0.0) {
                        try {
                            val jsonObj = gson.fromJson(cacheJson, com.google.gson.JsonObject::class.java)
                            val bgTransparencyFromJson = jsonObj.get("bgTransparency")
                            if (bgTransparencyFromJson != null && !bgTransparencyFromJson.isJsonNull) {
                                logDebug("updateAppWidget: DEBUG - bgTransparency found in JSON: ${bgTransparencyFromJson.asDouble}")
                                // Re-parse with default Gson to use the correct value
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
                                logDebug("updateAppWidget: DEBUG - bgTransparency NOT found in JSON, using default 1.0")
                                // bgTransparency is missing from JSON, ensure we use default 1.0
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
                            logDebug("updateAppWidget: DEBUG - Could not parse bgTransparency separately: ${parseErr.message}")
                        }
                    }
                    
                    logDebug("updateAppWidget: Cache parsed successfully")
                    logDebug("updateAppWidget: DEBUG - Final bgTransparency value: ${cacheData!!.bgTransparency}")
                    logDebug("updateAppWidget: DEBUG - All parsed values - hue:${cacheData!!.hue}, isDarkMode:${cacheData!!.isDarkMode}, location:${cacheData!!.location}, bgTransparency:${cacheData!!.bgTransparency}")
                    
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
                    logDebug("updateAppWidget: Exception details: ${e.stackTraceToString().take(500)}")
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
                // Fallback to extracting from prayerTimes map (when data comes from widget_prefs worker)
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
            // This handles the case where the cache JSON is incomplete
            if (bgTransparency <= 0.0) {
                try {
                    val flutterPrefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    // Try reading as float first (native Flutter double storage)
                    val savedBgTransparency = flutterPrefs.getFloat("flutter.widgetBgTransparency", -1f)
                    if (savedBgTransparency > 0.0f) {
                        bgTransparency = savedBgTransparency.toDouble()
                        logDebug("updateAppWidget: bgTransparency read from FlutterSharedPreferences (float): $bgTransparency")
                    } else {
                        // Try as string if float didn't work
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
            logDebug("updateAppWidget: ═══ TRANSPARENCY DEBUG ═══")
            logDebug("updateAppWidget: bgTransparency from cache: $bgTransparency")
            logDebug("updateAppWidget: bgTransparency is valid (>0): ${bgTransparency > 0.0}")
            logDebug("updateAppWidget: Alpha calculation: ${(bgTransparency * 255).toInt()}")
            logDebug("updateAppWidget: ═════════════════════════════")
            
            // Get color scheme based on user's hue and theme preference
            val colors = ColorScheme.getColors(primaryHue, isDarkMode)
            logDebug("updateAppWidget: Colors generated - BG: ${String.format("0x%08X", colors.containerBg)}, Accent: ${String.format("0x%08X", colors.accentColor)}")
            
            // Apply dynamic colors to widget with transparency
            applyThemeColors(remoteViews, colors, bgTransparency)
            
            // Apply location text and date/time
            remoteViews.setTextViewText(R.id.widget_location, location)
            val dateTime = SimpleDateFormat("dd/MM/yyyy • HH:mm", Locale.getDefault()).format(System.currentTimeMillis())
            remoteViews.setTextViewText(R.id.widget_date_time, dateTime)
            logDebug("updateAppWidget: Location set to: $location, Date/Time: $dateTime")
            
            // Use test data if no cache
            val finalPrayerTimes = prayerTimes ?: mapOf(
                "fajr" to "05:45",
                "sunrise" to "07:15",
                "dhuhr" to "12:30",
                "asr" to "15:45",
                "maghrib" to "17:30",
                "isha" to "19:00"
            )
            
            if (prayerTimes == null) {
                logDebug("updateAppWidget: Using test data")
                setPlaceholderValues(remoteViews)
            } else {
                logDebug("updateAppWidget: Setting prayer times from cache")
                setPrayerTimes(remoteViews, prayerTimes)
            }
            
            // Calculate and set next prayer
            val nextPrayer = calculateNextPrayer(finalPrayerTimes)
            if (nextPrayer != null) {
                logDebug("updateAppWidget: Setting next prayer to: ${nextPrayer.first} at ${nextPrayer.second}")
                // Highlight the next prayer card with the accent color
                highlightNextPrayerCard(remoteViews, nextPrayer.first, colors)
                logDebug("updateAppWidget: Next prayer highlighted: ${nextPrayer.first} at ${nextPrayer.second}")
                
                // Schedule next highlight update
                scheduleNextHighlightUpdate(context, nextPrayer.second)
            } else {
                logError("updateAppWidget: calculateNextPrayer returned null")
            }
            
            // Set refresh button click listener
            setRefreshButtonListener(context, remoteViews)
            
            // Update the widget
            try {
                appWidgetManager.updateAppWidget(appWidgetId, remoteViews)
                logDebug("updateAppWidget: Widget $appWidgetId updated successfully")
            } catch (e: Exception) {
                logError("updateAppWidget: Failed to update widget $appWidgetId with RemoteViews", e)
                throw e
            }
            logDebug("updateAppWidget: Widget $appWidgetId updated successfully")
            
        } catch (e: Exception) {
            logError("Error updating widget $appWidgetId", e)
        }
    }

    /**
     * Set placeholder/test values when no cache exists
     */
    private fun setPlaceholderValues(remoteViews: RemoteViews, layoutType: String = LAYOUT_MINIMAL) {
        logDebug("setPlaceholderValues: Setting test data for layout type: $layoutType")
        
        // Use test data so widget is visible
        val testPrayerTimes = mapOf(
            "fajr" to "05:45",
            "sunrise" to "07:15",
            "dhuhr" to "12:30",
            "asr" to "15:45",
            "maghrib" to "17:30",
            "isha" to "19:00"
        )
        
        setPrayerTimes(remoteViews, testPrayerTimes, layoutType)
        
        // Show actual current date and time
        val dateFormatter = SimpleDateFormat("dd/MM/yyyy • HH:mm", Locale.getDefault())
        val currentDateTimeString = dateFormatter.format(System.currentTimeMillis())
        remoteViews.setTextViewText(R.id.widget_date_time, currentDateTimeString)
    }

    /**
     * Set prayer times in the widget UI
     */
    private fun setPrayerTimes(remoteViews: RemoteViews, prayerTimes: Map<String, String>, layoutType: String = LAYOUT_MINIMAL) {
        logDebug("setPrayerTimes: Setting prayer times for layout type: $layoutType")
        
        val suffix = if (layoutType == LAYOUT_HORIZONTAL) "_h" else ""
        
        // Map prayer keys to view IDs based on layout type
        val prayerViewMap = when (layoutType) {
            LAYOUT_HORIZONTAL -> mapOf(
                PRAYER_FAJR to R.id.prayer_fajr_time_h,
                PRAYER_SUNRISE to R.id.prayer_sunrise_time_h,
                PRAYER_DHUHR to R.id.prayer_dhuhr_time_h,
                PRAYER_ASR to R.id.prayer_asr_time_h,
                PRAYER_MAGHRIB to R.id.prayer_maghrib_time_h,
                PRAYER_ISHA to R.id.prayer_isha_time_h
            )
            else -> mapOf(
                PRAYER_FAJR to R.id.prayer_fajr_time,
                PRAYER_SUNRISE to R.id.prayer_sunrise_time,
                PRAYER_DHUHR to R.id.prayer_dhuhr_time,
                PRAYER_ASR to R.id.prayer_asr_time,
                PRAYER_MAGHRIB to R.id.prayer_maghrib_time,
                PRAYER_ISHA to R.id.prayer_isha_time
            )
        }
        
        for ((prayerKey, viewId) in prayerViewMap) {
            val time = prayerTimes[prayerKey] ?: "--:--"
            remoteViews.setTextViewText(viewId, time)
            logDebug("setPrayerTimes: $prayerKey = $time")
        }
    }

    /**
     * Apply theme colors to all widget elements using the ColorPalette
     */
    private fun applyThemeColors(remoteViews: RemoteViews, colors: ColorPalette, bgTransparency: Double = 1.0) {
        logDebug("applyThemeColors: Applying colors to widget elements with bgTransparency=$bgTransparency")
        logDebug("applyThemeColors: containerBgSecondary = ${String.format("0x%08X", colors.containerBgSecondary)}")
        
        // Apply main widget root background with rounded corners and transparency
        try {
            // Apply transparency to the root background color
            val alphaValue = (bgTransparency * 255).toInt()
            val rootColorWithAlpha = (alphaValue shl 24) or (colors.containerBg and 0x00FFFFFF)
            
            logDebug("applyThemeColors: bgTransparency=$bgTransparency, alphaValue=$alphaValue, rootColorWithAlpha=${String.format("0x%08X", rootColorWithAlpha)}")
            
            // Use setImageViewBitmap with a simple colored bitmap for transparency support
            val rootBitmap = createSolidColorBitmap(rootColorWithAlpha)
            remoteViews.setImageViewBitmap(R.id.widget_root_bg, rootBitmap)
            logDebug("applyThemeColors: Root background set to ${String.format("0x%08X", rootColorWithAlpha)} with transparency=$bgTransparency")
        } catch (e: Exception) {
            logDebug("applyThemeColors: Could not set root background: ${e.message}")
            e.printStackTrace()
        }
        
        // Create background bitmaps for each card with rounded corners and colors
        val cardBackgrounds = listOf(
            R.id.card_fajr_bg to colors.containerBgSecondary,
            R.id.card_sunrise_bg to colors.containerBgSecondary,
            R.id.card_dhuhr_bg to colors.containerBgSecondary,
            R.id.card_asr_bg to colors.containerBgSecondary,
            R.id.card_maghrib_bg to colors.containerBgSecondary,
            R.id.card_isha_bg to colors.containerBgSecondary
        )
        
        for ((bgId, color) in cardBackgrounds) {
            try {
                val bitmap = createRoundedRectBitmap(color, 300, 250, 16f)
                remoteViews.setImageViewBitmap(bgId, bitmap)
                logDebug("applyThemeColors: Set card background to ${String.format("0x%08X", color)}")
            } catch (e: Exception) {
                logDebug("applyThemeColors: Error setting card background: ${e.message}")
            }
        }
        
        // Apply header background with rounded corners via overlay ImageView
        try {
            val headerBitmap = createRoundedRectBitmap(colors.headerBg, 1000, 150, 20f)
            remoteViews.setImageViewBitmap(R.id.widget_header_bg, headerBitmap)
            logDebug("applyThemeColors: Header background set to ${String.format("0x%08X", colors.headerBg)}")
        } catch (e: Exception) {
            logDebug("applyThemeColors: Could not set header background: ${e.message}")
        }
        
        // Apply text colors
        remoteViews.setTextColor(R.id.widget_location, colors.headerText)
        remoteViews.setTextColor(R.id.widget_date_time, colors.containerTextSecondary)
        remoteViews.setTextColor(R.id.widget_refresh_button, colors.headerText)
        
        // Apply prayer label colors
        val labelIds = listOf(
            R.id.label_fajr,
            R.id.label_sunrise,
            R.id.label_dhuhr,
            R.id.label_asr,
            R.id.label_maghrib,
            R.id.label_isha
        )
        
        for (labelId in labelIds) {
            remoteViews.setTextColor(labelId, colors.prayerLabelText)
        }
        
        // Apply prayer time value colors
        val timeIds = listOf(
            R.id.prayer_fajr_time,
            R.id.prayer_sunrise_time,
            R.id.prayer_dhuhr_time,
            R.id.prayer_asr_time,
            R.id.prayer_maghrib_time,
            R.id.prayer_isha_time
        )
        
        for (timeId in timeIds) {
            remoteViews.setTextColor(timeId, colors.prayerTimeText)
        }
        
        logDebug("applyThemeColors: All colors applied successfully")
    }
    
    /**
     * Create a simple solid color bitmap (1x1) that will be stretched by RemoteViews
     * This allows transparency to work correctly with RemoteViews
     */
    private fun createSolidColorBitmap(color: Int): android.graphics.Bitmap {
        val bitmap = android.graphics.Bitmap.createBitmap(1, 1, android.graphics.Bitmap.Config.ARGB_8888)
        bitmap.setPixel(0, 0, color)
        logDebug("createSolidColorBitmap: Created 1x1 bitmap with color ${String.format("0x%08X", color)}, alpha=${color ushr 24}")
        return bitmap
    }

    /**
     * Create a rounded rectangle bitmap with a solid color
     */
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

    /**
     * Apply highlight color to the next prayer card
     * Makes the next prayer prominent by changing text color and adding accent styling
     */
    private fun highlightNextPrayerCard(remoteViews: RemoteViews, nextPrayerName: String, colors: ColorPalette, layoutType: String = LAYOUT_MINIMAL) {
        logDebug("highlightNextPrayerCard: Highlighting $nextPrayerName for layout type: $layoutType")
        logDebug("highlightNextPrayerCard: highlightBg = ${String.format("0x%08X", colors.highlightBg)}")
        logDebug("highlightNextPrayerCard: highlightText = ${String.format("0x%08X", colors.highlightText)}")
        
        // Map prayer names to card background image IDs and text IDs based on layout type
        val cardMap = when (layoutType) {
            LAYOUT_HORIZONTAL -> mapOf(
                "Fajr" to Triple(R.id.card_fajr_bg_h, R.id.label_fajr_h, R.id.prayer_fajr_time_h),
                "Sunrise" to Triple(R.id.card_sunrise_bg_h, R.id.label_sunrise_h, R.id.prayer_sunrise_time_h),
                "Dhuhr" to Triple(R.id.card_dhuhr_bg_h, R.id.label_dhuhr_h, R.id.prayer_dhuhr_time_h),
                "Asr" to Triple(R.id.card_asr_bg_h, R.id.label_asr_h, R.id.prayer_asr_time_h),
                "Maghrib" to Triple(R.id.card_maghrib_bg_h, R.id.label_maghrib_h, R.id.prayer_maghrib_time_h),
                "Isha" to Triple(R.id.card_isha_bg_h, R.id.label_isha_h, R.id.prayer_isha_time_h)
            )
            else -> mapOf(
                "Fajr" to Triple(R.id.card_fajr_bg, R.id.label_fajr, R.id.prayer_fajr_time),
                "Sunrise" to Triple(R.id.card_sunrise_bg, R.id.label_sunrise, R.id.prayer_sunrise_time),
                "Dhuhr" to Triple(R.id.card_dhuhr_bg, R.id.label_dhuhr, R.id.prayer_dhuhr_time),
                "Asr" to Triple(R.id.card_asr_bg, R.id.label_asr, R.id.prayer_asr_time),
                "Maghrib" to Triple(R.id.card_maghrib_bg, R.id.label_maghrib, R.id.prayer_maghrib_time),
                "Isha" to Triple(R.id.card_isha_bg, R.id.label_isha, R.id.prayer_isha_time)
            )
        }
        
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
                
                logDebug("highlightNextPrayerCard: Reset $prayerName to ${String.format("0x%08X", colors.containerBgSecondary)}")
            } catch (e: Exception) {
                logDebug("highlightNextPrayerCard: Error resetting card for $prayerName: ${e.message}")
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
                
                logDebug("highlightNextPrayerCard: Set $nextPrayerName to ${String.format("0x%08X", colors.highlightBg)} with text ${String.format("0x%08X", colors.highlightText)}")
            } catch (e: Exception) {
                logDebug("highlightNextPrayerCard: Error highlighting $nextPrayerName: ${e.message}")
            }
        } else {
            logDebug("highlightNextPrayerCard: ERROR - $nextPrayerName not found in cardMap")
        }
    }

    /**
     * Calculate the next prayer time
     * Returns Pair of (prayer name, prayer time)
     */
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
            logError("Error calculating next prayer", e)
            return null
        }
    }

    /**
     * Highlight the next prayer container with bold text
     */
    private fun highlightNextPrayerContainer(remoteViews: RemoteViews, nextPrayerName: String) {
        try {
            logDebug("highlightNextPrayerContainer: Highlighting $nextPrayerName")
            
            val containerMap = mapOf(
                "Fajr" to R.id.prayer_fajr_time,
                "Sunrise" to R.id.prayer_sunrise_time,
                "Dhuhr" to R.id.prayer_dhuhr_time,
                "Asr" to R.id.prayer_asr_time,
                "Maghrib" to R.id.prayer_maghrib_time,
                "Isha" to R.id.prayer_isha_time
            )
            
            // Reset all to normal text style
            for ((_, viewId) in containerMap) {
                remoteViews.setTextColor(viewId, android.graphics.Color.BLACK)
                // Note: We can't set textStyle directly in RemoteViews, so we use color to highlight
            }
            
            // Highlight the next prayer with blue color
            val nextViewId = containerMap[nextPrayerName]
            if (nextViewId != null) {
                remoteViews.setTextColor(nextViewId, android.graphics.Color.parseColor("#1976D2"))
                logDebug("highlightNextPrayerContainer: Highlighted view $nextViewId with blue color")
            }
        } catch (e: Exception) {
            logError("Error highlighting prayer container", e)
        }
    }

    /**
     * Set the refresh button click listener
     */
    private fun setRefreshButtonListener(context: Context, remoteViews: RemoteViews) {
        try {
            logDebug("setRefreshButtonListener: Setting refresh button")
            
            val intent = Intent(context, PrayerWidgetProvider::class.java).apply {
                action = ACTION_MANUAL_REFRESH
                setPackage(context.packageName)  // Ensure broadcast goes to this package
            }
            
            logDebug("setRefreshButtonListener: Intent action=$ACTION_MANUAL_REFRESH, package=${context.packageName}")
            
            val pendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.getBroadcast(
                    context,
                    1001,  // Use unique ID for refresh button
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            } else {
                PendingIntent.getBroadcast(context, 1001, intent, PendingIntent.FLAG_UPDATE_CURRENT)
            }
            
            remoteViews.setOnClickPendingIntent(R.id.widget_refresh_button, pendingIntent)
            logDebug("setRefreshButtonListener: Refresh button listener set successfully")
        } catch (e: Exception) {
            logError("Error setting refresh button listener", e)
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
            
            val intent = Intent(context, PrayerWidgetProvider::class.java).apply {
                action = ACTION_UPDATE_PRAYER_HIGHLIGHT
            }
            
            val pendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.getBroadcast(
                    context,
                    100,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            } else {
                PendingIntent.getBroadcast(context, 100, intent, PendingIntent.FLAG_UPDATE_CURRENT)
            }
            
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

/**
 * Kotlin data class for WidgetCache to match the Dart WidgetCacheData structure
 */
data class WidgetCacheData(
    @SerializedName("fajr")
    val fajr: String,
    @SerializedName("sunrise")
    val sunrise: String,
    @SerializedName("dhuhr")
    val dhuhr: String,
    @SerializedName("asr")
    val asr: String,
    @SerializedName("maghrib")
    val maghrib: String,
    @SerializedName("isha")
    val isha: String,
    @SerializedName("source")
    val source: String,
    @SerializedName("location")
    val location: String,
    @SerializedName("hue")
    val hue: Double,
    @SerializedName("isDarkMode")
    val isDarkMode: Boolean,
    @SerializedName("bgTransparency")
    val bgTransparency: Double = 1.0,
    @SerializedName("cacheDateDdMmYyyy")
    val cacheDateDdMmYyyy: String,
    @SerializedName("cacheTimestampMs")
    val cacheTimestampMs: Long
)

/**
 * Color scheme manager for the prayer widget
 * Uses HSV (Hue, Saturation, Value) color space for consistent theming
 * 
 * COLOR SCHEME DOCUMENTATION:
 * ===========================
 * 
 * HSV Color Space Explanation:
 * - H (Hue): 0-360 degrees on the color wheel (user-configurable)
 * - S (Saturation): 0-100% (intensity of color)
 * - V (Value): 0-100% (brightness)
 * 
 * Light Mode Color Scheme (isDarkMode = false):
 * - Background: White (HSV: 0, 0%, 100%)
 * - Container/Card: Off-white (HSV: 0, 0%, 98%)
 * - Primary Accent: User's Hue at 70% saturation, 95% value (HSV: H, 70%, 95%)
 * - Primary Text: Dark gray (HSV: 0, 0%, 15%)
 * - Secondary Text: Medium gray (HSV: 0, 0%, 40%)
 * - Tertiary Text: Light gray (HSV: 0, 0%, 60%)
 * 
 * Dark Mode Color Scheme (isDarkMode = true):
 * - Background: Very dark gray (HSV: 0, 0%, 12%) - Almost black
 * - Container/Card: Dark gray (HSV: 0, 0%, 18%)
 * - Primary Accent: User's Hue at 80% saturation, 70% value (HSV: H, 80%, 70%)
 * - Primary Text: Bright white (HSV: 0, 0%, 100%)
 * - Secondary Text: Light gray (HSV: 0, 0%, 80%)
 * - Tertiary Text: Medium gray (HSV: 0, 0%, 60%)
 * 
 * USAGE GUIDE:
 * ============
 * Call ColorScheme.getColors(hue, isDarkMode) to get all colors for the widget:
 * - containerBg: Main widget background
 * - containerText: Primary text on main background
 * - accentColor: User's theme color (for highlighting next prayer, buttons, etc.)
 * - accentText: Text on accent color background
 * - secondaryText: Less important text (timestamps, subtitles)
 * - tertiaryText: Least important text (labels, borders)
 * 
 * Example HSV Values:
 * - Red: H=0, S=100%, V=100% (HSV: 0, 100, 100)
 * - Green: H=120, S=100%, V=100% (HSV: 120, 100, 100)
 * - Blue: H=240, S=100%, V=100% (HSV: 240, 100, 100)
 * - User's Hue: H=userHue, S=varies, V=varies
 */
object ColorScheme {
    /**
     * Get color scheme for the widget based on user's hue and theme preference
     * Returns a ColorPalette data class with all necessary colors
     */
    fun getColors(userHue: Double, isDarkMode: Boolean): ColorPalette {
        return if (isDarkMode) {
            getDarkModeColors(userHue)
        } else {
            getLightModeColors(userHue)
        }
    }

    /**
     * Light mode color scheme - Material You Design
     * Visual hierarchy: Root (lightest) < Header < Cards < Highlight (most saturated)
     * Text: Very desaturated (12-20% sat) for readability on light colored backgrounds
     */
    private fun getLightModeColors(userHue: Double): ColorPalette {
        val palette = ColorPalette(
            // Background colors - Material You hierarchy
            containerBg = hsvToArgb(userHue, 4.0, 97.0),           // Root: Very light tinted (HSV: H, 14%, 97%)
            containerBgSecondary = hsvToArgb(userHue, 10.0, 97.0),  // Cards: Intermediate tint (HSV: H, 16%, 94%)
            
            // Text colors on light background - VERY DESATURATED for excellent readability
            containerText = hsvToArgb(userHue, 15.0, 22.0),          // Dark tinted text (HSV: H, 15%, 22%)
            containerTextSecondary = hsvToArgb(userHue, 45.0, 40.0), // Medium gray-tinted (HSV: H, 12%, 35%)
            containerTextTertiary = hsvToArgb(userHue, 10.0, 50.0),  // Light gray-tinted (HSV: H, 10%, 50%)
            
            // Accent color (user's hue) - medium saturation for light backgrounds
            accentColor = hsvToArgb(userHue, 60.0, 52.0),           // User hue at 60% sat, 52% val (medium tone)
            accentText = hsvToArgb(userHue, 0.0, 98.0),                 // Near-white text on accent
            
            // Header/Title colors - distinct from root
            headerBg = hsvToArgb(userHue, 50.0, 90.0),              // Header: More tinted than root (HSV: H, 18%, 92%)
            headerText = hsvToArgb(userHue, 30.0, 30.0),            // Dark tinted header text
            
            // Prayer time colors - desaturated but with hue incorporated
            prayerTimeText = hsvToArgb(userHue, 30.0, 78.0),        // Hue-tinted dark text (HSV: H, 20%, 25%)
            prayerLabelText = hsvToArgb(userHue, 99.0, 30.0),       // Hue-tinted dark text (HSV: H, 18%, 28%)
            
            // Highlight color for next prayer - saturated for visibility
            highlightBg = hsvToArgb(userHue, 30.0, 78.0),           // Saturated medium tone (HSV: H, 60%, 52%)
            highlightText = hsvToArgb(userHue, 10.0, 97.0),              // Near-white text on highlight
            
            isDarkMode = false
        )
        return palette
    }

    /**
     * Dark mode color scheme - Material You Design
     * Visual hierarchy: Root (darkest) < Cards < Header < Highlight (brightest accent)
     * Text: Very desaturated (5-10% sat) for readability - pure white too harsh with colored backgrounds
     * OLED-friendly with low brightness values for battery efficiency
     */
    private fun getDarkModeColors(userHue: Double): ColorPalette {
        val palette = ColorPalette(
            // Background colors - OLED-friendly dark with hue tints
            containerBg = hsvToArgb(userHue, 18.0, 10.0),            // Root: Darkest (HSV: H, 18%, 20%)
            containerBgSecondary = hsvToArgb(userHue, 30.0, 20.0),   // Cards: Slightly lighter (HSV: H, 20%, 24%)
            
            // Text colors on dark background - VERY DESATURATED to avoid harshness on black
            containerText = hsvToArgb(userHue, 8.0, 95.0),           // Primary text: nearly white, minimal hue (HSV: H, 8%, 95%)
            containerTextSecondary = hsvToArgb(userHue, 24.0, 80.0),  // Secondary: slightly more gray (HSV: H, 6%, 85%)
            containerTextTertiary = hsvToArgb(userHue, 5.0, 72.0),   // Tertiary: more gray (HSV: H, 5%, 72%)
            
            // Accent color (user's hue) - bright and saturated for emphasis on dark
            accentColor = hsvToArgb(userHue, 55.0, 65.0),            // User hue at 55% sat, 65% val (bright but not harsh)
            accentText = hsvToArgb(userHue, 0.0, 98.0),                  // Near-white text on accent
            
            // Header/Title colors - distinct from root with slightly higher value
            headerBg = hsvToArgb(userHue, 45.0, 50.0),               // Header: Raised layer (HSV: H, 22%, 28%)
            headerText = hsvToArgb(userHue, 24.0, 95.0),              // Header text: nearly white (HSV: H, 8%, 95%)
            
            // Prayer time colors - desaturated but with hue to maintain theme cohesion
            prayerTimeText = hsvToArgb(userHue, 30.0, 70.0),          // Prayer times: very light, minimal sat (HSV: H, 8%, 92%)
            prayerLabelText = hsvToArgb(userHue, 10.0, 88.0),        // Prayer labels: light, minimal sat (HSV: H, 10%, 88%)
            
            // Highlight color for next prayer - highly saturated for attention
            highlightBg = hsvToArgb(userHue, 30.0, 70.0),            // Saturated bright tone (HSV: H, 55%, 65%)
            highlightText = hsvToArgb(userHue, 30.0, 20.0),               // Near-white text on highlight
            
            isDarkMode = true
        )
        return palette
    }

    /**
     * Create a GradientDrawable with rounded corners and a solid color
     * This allows dynamic colors while preserving rounded corners
     */
    fun createRoundedDrawable(color: Int, radiusDp: Float = 16f): GradientDrawable {
        return GradientDrawable().apply {
            setColor(color)
            cornerRadius = radiusDp
        }
    }
    
    /**
     * Convert HSV color values to Android ARGB color integer
     * 
     * @param hue: 0-360 degrees on the color wheel
     * @param saturation: 0-100 percent
     * @param value: 0-100 percent
     * @return ARGB color integer for Android (0xAARRGGBB)
     * 
     * Example: hsvToArgb(240.0, 100.0, 100.0) = pure blue (0xFF0000FF)
     */
    private fun hsvToArgb(hue: Double, saturation: Double, value: Double): Int {
        // Normalize values to 0-1 range
        val h = hue % 360.0
        val s = saturation / 100.0
        val v = value / 100.0
        
        val c = v * s  // Chroma
        val hPrime = h / 60.0
        val x = c * (1.0 - kotlin.math.abs((hPrime % 2.0) - 1.0))
        
        val (r1, g1, b1) = when {
            hPrime < 1.0 -> Triple(c, x, 0.0)
            hPrime < 2.0 -> Triple(x, c, 0.0)
            hPrime < 3.0 -> Triple(0.0, c, x)
            hPrime < 4.0 -> Triple(0.0, x, c)
            hPrime < 5.0 -> Triple(x, 0.0, c)
            else -> Triple(c, 0.0, x)
        }
        
        val m = v - c
        val r = ((r1 + m) * 255).toInt()
        val g = ((g1 + m) * 255).toInt()
        val b = ((b1 + m) * 255).toInt()
        
        // Return as ARGB with full alpha (0xFF)
        return 0xFF000000.toInt() or (r shl 16) or (g shl 8) or b
    }
}

/**
 * Color palette for the widget
 * Contains all color values needed to render the widget with proper theming
 */
data class ColorPalette(
    // Background colors
    val containerBg: Int,           // Main widget background
    val containerBgSecondary: Int,  // Secondary/card background
    
    // Text colors on main background
    val containerText: Int,         // Primary text color
    val containerTextSecondary: Int,// Secondary text color
    val containerTextTertiary: Int, // Tertiary text color
    
    // Accent colors (user's theme color)
    val accentColor: Int,           // Primary accent/highlight color
    val accentText: Int,            // Text on accent background
    
    // Header colors
    val headerBg: Int,              // Header background
    val headerText: Int,            // Header text
    
    // Prayer time text colors
    val prayerTimeText: Int,        // Prayer time values
    val prayerLabelText: Int,       // Prayer time labels
    
    // Highlight colors (next prayer)
    val highlightBg: Int,           // Next prayer background highlight
    val highlightText: Int,         // Next prayer text on highlight
    
    val isDarkMode: Boolean         // Theme mode indicator
)

/**
 * QUICK REFERENCE: How to Use Colors in the Widget
 * =================================================
 * 
 * EXAMPLE 1: Basic Light Mode with Blue Theme (Hue=240)
 * val colors = ColorScheme.getColors(240.0, false)
 * Result:
 * - containerBg: 0xFFFFFFFF (white background)
 * - containerText: 0xFF262626 (dark text)
 * - accentColor: 0xFF0052CC (blue accent)
 * 
 * EXAMPLE 2: Dark Mode with Red Theme (Hue=0)
 * val colors = ColorScheme.getColors(0.0, true)
 * Result:
 * - containerBg: 0xFF1F1F1F (very dark gray background)
 * - containerText: 0xFFFFFFFF (white text)
 * - accentColor: 0xFFB30000 (dark red accent for visibility)
 * 
 * EXAMPLE 3: Dark Mode with Green Theme (Hue=120)
 * val colors = ColorScheme.getColors(120.0, true)
 * Result:
 * - containerBg: 0xFF1F1F1F (very dark gray background)
 * - containerText: 0xFFFFFFFF (white text)
 * - accentColor: 0xFF009900 (dark green accent for visibility)
 * 
 * COLOR MAPPING IN updateAppWidget():
 * ====================================
 * widget_container               -> containerBg (main background)
 * widget_location                -> headerText (location/header text color)
 * widget_last_updated            -> containerTextSecondary (timestamp)
 * prayer_*_time (all prayer times) -> prayerTimeText (prayer values)
 * widget_next_prayer_name        -> accentColor (blue/user hue - highlighted)
 * widget_next_prayer_time        -> accentColor (blue/user hue - highlighted)
 * 
 * TO ADD NEW COLOR USAGES:
 * 1. Call ColorScheme.getColors(primaryHue, isDarkMode)
 * 2. Access desired color from returned ColorPalette object
 * 3. Apply with remoteViews.setTextColor() or remoteViews.setInt()
 * 4. Example: remoteViews.setTextColor(R.id.prayer_fajr_time, colors.prayerTimeText)
 */



