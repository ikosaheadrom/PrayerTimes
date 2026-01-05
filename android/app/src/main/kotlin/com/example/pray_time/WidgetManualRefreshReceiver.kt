package com.example.pray_time

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters

/**
 * BroadcastReceiver for manual widget refresh requests
 * Enqueues the WidgetCacheUpdateWorker to fetch new data
 */
class WidgetManualRefreshReceiver : BroadcastReceiver() {
    companion object {
        private const val DEBUG_TAG = "[WidgetManualRefreshReceiver]"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null) {
            Log.e(DEBUG_TAG, "onReceive: context is null")
            return
        }

        Log.d(DEBUG_TAG, "onReceive: action=${intent?.action}")

        if (intent?.action == "com.example.pray_time.MANUAL_WIDGET_REFRESH") {
            Log.d(DEBUG_TAG, ">>> Received MANUAL_WIDGET_REFRESH broadcast")
            Log.d(DEBUG_TAG, ">>> Enqueueing WidgetCacheUpdateWorker to fetch fresh data")

            try {
                // Enqueue the worker to fetch fresh prayer times and update widget
                val updateRequest = OneTimeWorkRequestBuilder<WidgetCacheUpdateWorker>()
                    .build()

                WorkManager.getInstance(context).enqueueUniqueWork(
                    "widget_cache_update_manual",
                    androidx.work.ExistingWorkPolicy.REPLACE,  // REPLACE to ensure fresh update
                    updateRequest
                )

                Log.d(DEBUG_TAG, ">>> Worker enqueued successfully")
            } catch (e: Exception) {
                Log.e(DEBUG_TAG, ">>> Error enqueueing worker", e)
            }
        }
    }
}
