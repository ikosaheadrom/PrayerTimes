# Gson rules
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep public class * implements java.lang.reflect.Type
-keep class com.google.gson.stream.** { *; }

# Ignore Google Play Core classes (not needed for this app)
-dontwarn com.google.android.play.core.**

# Keep data classes used with Gson
-keep class com.example.pray_time.** { *; }
-keep class com.example.pray_time.*.** { *; }

# Keep WidgetCacheData and related classes - IMPORTANT FOR WIDGETS
-keepclassmembers class com.example.pray_time.WidgetCacheData {
    public <init>(...);
    public <init>();
    public java.lang.String fajr;
    public java.lang.String sunrise;
    public java.lang.String dhuhr;
    public java.lang.String asr;
    public java.lang.String maghrib;
    public java.lang.String isha;
    public java.lang.String source;
    public java.lang.String location;
    public double hue;
    public boolean isDarkMode;
    public double bgTransparency;
    public java.lang.String cacheDateDdMmYyyy;
    public long cacheTimestampMs;
}

# Keep enum classes
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep custom application classes
-keep class * extends android.app.Activity
-keep class * extends android.app.Service
-keep class * extends android.content.BroadcastReceiver
-keep class * extends android.content.ContentProvider
-keep class * extends android.app.backup.BackupAgentHelper
-keep class * extends android.preference.Preference
-keep class * extends android.view.View
-keep class * extends android.widget.BaseAdapter

# Keep Flutter related classes
-keep class io.flutter.** { *; }
-keep class androidx.work.** { *; }

# Keep AppWidgetProvider and related widget classes
-keep class * extends android.appwidget.AppWidgetProvider { *; }
-keep class com.example.pray_time.PrayerWidgetProvider { *; }
-keep class com.example.pray_time.PrayerWidgetProviderHorizontal { *; }
-keep class com.example.pray_time.WidgetCacheUpdateWorker { *; }

# Keep reflection methods used for widget updates
-keepclassmembers class com.example.pray_time.PrayerWidgetProvider {
    public void onUpdate(...);
    public void onReceive(...);
    private void updateAppWidget(...);
}

-keepclassmembers class com.example.pray_time.PrayerWidgetProviderHorizontal {
    public void onUpdate(...);
    public void onReceive(...);
    private void updateAppWidget(...);
}
