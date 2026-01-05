package com.example.pray_time

import android.content.Context
import android.content.Intent
import android.appwidget.AppWidgetManager
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.google.gson.Gson
import com.google.gson.JsonObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * WorkManager for updating widget cache
 * 
 * This worker:
 * 1. Fetches prayer times using the Dart widget cache system
 * 2. Saves them to SharedPreferences for widget access
 * 3. Updates the last update time
 * 4. Triggers widget UI update
 */
class WidgetCacheUpdateWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        private const val DEBUG_TAG = "[WidgetCacheUpdateWorker]"
        const val WIDGET_CACHE_KEY = "widget_info_cache"
        const val LAST_UPDATE_TIME_KEY = "widget_last_update_time"
    }

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        return@withContext try {
            logDebug("Worker started - fetching prayer times")
            
            // Request Dart to fetch fresh prayer times
            val prayerTimesMap = fetchPrayerTimesFromDart()
            
            if (prayerTimesMap.isEmpty()) {
                logDebug("Worker: Failed to get prayer times - will retry")
                return@withContext Result.retry()
            }
            
            logDebug("Worker: Got prayer times successfully")
            
            // Save to SharedPreferences for widget to read
            savePrayerTimesToPrefs(prayerTimesMap)
            
            // Update widget UI
            triggerWidgetUpdate()
            
            logDebug("Worker: Complete - prayer times updated")
            Result.success()
            
        } catch (e: Exception) {
            logDebug("Worker: Error - ${e.message}")
            Result.retry()
        }
    }

    /**
     * Fetch prayer times from Dart widget cache system
     */
    private suspend fun fetchPrayerTimesFromDart(): Map<String, String> {
        return withContext(Dispatchers.IO) {
            try {
                // Request Dart to fetch fresh times
                try {
                    val intent = Intent("com.example.pray_time.REFRESH_WIDGET_CACHE")
                    intent.setPackage(applicationContext.packageName)
                    applicationContext.sendBroadcast(intent)
                    Thread.sleep(3000)  // Wait for Dart to update cache
                } catch (e: Exception) {
                    // Continue anyway
                }
                
                // Read cached widget data from Dart's SharedPreferences
                val sharedPreferences = applicationContext.getSharedPreferences(
                    "FlutterSharedPreferences",
                    Context.MODE_PRIVATE
                )
                
                val cacheJson = sharedPreferences.getString("flutter.widget_info_cache", null)
                    ?: return@withContext emptyMap()
                
                // Parse the JSON
                val gson = Gson()
                val jsonObject = gson.fromJson(cacheJson, JsonObject::class.java)
                
                // Extract prayer times
                val prayerTimes = mutableMapOf<String, String>()
                
                val prayerKeys = listOf("fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha")
                for (key in prayerKeys) {
                    prayerTimes[key] = jsonObject.get(key)?.asString ?: "N/A"
                }
                
                // Extract metadata
                prayerTimes["source"] = jsonObject.get("source")?.asString ?: "unknown"
                prayerTimes["location"] = jsonObject.get("location")?.asString ?: "Unknown"
                prayerTimes["hue"] = jsonObject.get("hue")?.asDouble?.toString() ?: "0.0"
                prayerTimes["isDarkMode"] = jsonObject.get("isDarkMode")?.asBoolean?.toString() ?: "false"
                prayerTimes["bgTransparency"] = jsonObject.get("bgTransparency")?.asDouble?.toString() ?: "1.0"
                prayerTimes["cacheDateDdMmYyyy"] = jsonObject.get("cacheDateDdMmYyyy")?.asString ?: ""
                
                return@withContext prayerTimes
                
            } catch (e: Exception) {
                return@withContext emptyMap()
            }
        }
    }

    /**
     * Save prayer times to SharedPreferences for widget access
     */
    private fun savePrayerTimesToPrefs(prayerTimesMap: Map<String, String>) {
        try {
            val widgetPrefs = applicationContext.getSharedPreferences(
                "widget_prefs",
                Context.MODE_PRIVATE
            )
            
            val gson = Gson()
            val jsonString = gson.toJson(prayerTimesMap)
            
            val editor = widgetPrefs.edit()
            editor.putString(WIDGET_CACHE_KEY, jsonString)
            editor.putLong(LAST_UPDATE_TIME_KEY, System.currentTimeMillis())
            editor.apply()
            
            logDebug("Worker: Saved ${prayerTimesMap.size} items to widget_prefs")
            
        } catch (e: Exception) {
            logDebug("Worker: Error saving prefs - ${e.message}")
        }
    }

    /**
     * Trigger widget UI update
     */
    private fun triggerWidgetUpdate() {
        try {
            logDebug("──── triggerWidgetUpdate START ────")
            
            val widgetManager = AppWidgetManager.getInstance(applicationContext)
            
            // Get vertical widget IDs
            val componentNameVertical = android.content.ComponentName(
                applicationContext,
                PrayerWidgetProvider::class.java
            )
            val verticalWidgetIds = widgetManager.getAppWidgetIds(componentNameVertical)
            
            // Get horizontal widget IDs
            val componentNameHorizontal = android.content.ComponentName(
                applicationContext,
                PrayerWidgetProviderHorizontal::class.java
            )
            val horizontalWidgetIds = widgetManager.getAppWidgetIds(componentNameHorizontal)
            
            // Send broadcast to trigger onUpdate for vertical widgets
            if (verticalWidgetIds.isNotEmpty()) {
                val intentVertical = Intent(applicationContext, PrayerWidgetProvider::class.java).apply {
                    action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, verticalWidgetIds)
                    setPackage(applicationContext.packageName)
                }
                applicationContext.sendBroadcast(intentVertical)
            }
            
            // Send broadcast to trigger onUpdate for horizontal widgets
            if (horizontalWidgetIds.isNotEmpty()) {
                val intentHorizontal = Intent(applicationContext, PrayerWidgetProviderHorizontal::class.java).apply {
                    action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, horizontalWidgetIds)
                    setPackage(applicationContext.packageName)
                }
                applicationContext.sendBroadcast(intentHorizontal)
            }
            
            logDebug("Worker: Broadcasts sent to update widgets")
            logDebug("──── triggerWidgetUpdate COMPLETE ────")
            
        } catch (e: Exception) {
            logError("triggerWidgetUpdate: ✗ Exception while sending broadcast", e)
        }
    }

    private fun logDebug(message: String) {
        Log.d(DEBUG_TAG, message)
    }
    
    private fun logError(message: String, exception: Exception? = null) {
        Log.e(DEBUG_TAG, message, exception)
    }
}

