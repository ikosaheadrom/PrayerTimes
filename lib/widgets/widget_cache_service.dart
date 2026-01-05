import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Widget info cache model containing all prayer times and metadata
class WidgetCacheData {
  final String fajr;
  final String sunrise;
  final String dhuhr;
  final String asr;
  final String maghrib;
  final String isha;
  final String source; // 'ministry', 'adhan', or 'offline'
  final String location; // City name or coordinates
  final double hue; // Color hue (0-360)
  final bool isDarkMode; // Theme mode
  final double bgTransparency; // Background opacity (0.0-1.0)
  final String cacheDateDdMmYyyy; // Cache date in dd/mm/yyyy format
  final int cacheTimestampMs; // Cache creation timestamp for 24-hour expiry

  WidgetCacheData({
    required this.fajr,
    required this.sunrise,
    required this.dhuhr,
    required this.asr,
    required this.maghrib,
    required this.isha,
    required this.source,
    required this.location,
    required this.hue,
    required this.isDarkMode,
    this.bgTransparency = 1.0,
    required this.cacheDateDdMmYyyy,
    required this.cacheTimestampMs,
  });

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'fajr': fajr,
      'sunrise': sunrise,
      'dhuhr': dhuhr,
      'asr': asr,
      'maghrib': maghrib,
      'isha': isha,
      'source': source,
      'location': location,
      'hue': hue,
      'isDarkMode': isDarkMode,
      'bgTransparency': bgTransparency,
      'cacheDateDdMmYyyy': cacheDateDdMmYyyy,
      'cacheTimestampMs': cacheTimestampMs,
    };
  }

  /// Create from JSON
  factory WidgetCacheData.fromJson(Map<String, dynamic> json) {
    return WidgetCacheData(
      fajr: json['fajr'] as String? ?? 'N/A',
      sunrise: json['sunrise'] as String? ?? 'N/A',
      dhuhr: json['dhuhr'] as String? ?? 'N/A',
      asr: json['asr'] as String? ?? 'N/A',
      maghrib: json['maghrib'] as String? ?? 'N/A',
      isha: json['isha'] as String? ?? 'N/A',
      source: json['source'] as String? ?? 'unknown',
      location: json['location'] as String? ?? 'Unknown',
      hue: json['hue'] as double? ?? 0.0,
      isDarkMode: json['isDarkMode'] as bool? ?? false,
      bgTransparency: json['bgTransparency'] as double? ?? 1.0,
      cacheDateDdMmYyyy: json['cacheDateDdMmYyyy'] as String? ?? '',
      cacheTimestampMs: json['cacheTimestampMs'] as int? ?? 0,
    );
  }

  /// Check if cache is expired (older than 24 hours)
  bool isExpired() {
    final now = DateTime.now().millisecondsSinceEpoch;
    const twentyFourHoursMs = 24 * 60 * 60 * 1000;
    final isExpired = (now - cacheTimestampMs) > twentyFourHoursMs;
    
    if (isExpired) {
      debugPrint('[WidgetCache] Cache expired! Age: ${(now - cacheTimestampMs) ~/ 1000} seconds');
    }
    
    return isExpired;
  }

  @override
  String toString() {
    return 'WidgetCacheData('
        'fajr=$fajr, sunrise=$sunrise, dhuhr=$dhuhr, asr=$asr, maghrib=$maghrib, isha=$isha, '
        'source=$source, location=$location, hue=$hue, isDarkMode=$isDarkMode, '
        'cacheDateDdMmYyyy=$cacheDateDdMmYyyy, age=${(DateTime.now().millisecondsSinceEpoch - cacheTimestampMs) ~/ 1000}s)';
  }
}

/// Service to manage widget cache with 24-hour expiry
class WidgetCacheService {
  static const String _cacheKey = 'widget_info_cache';
  static const String _debugTag = '[WidgetCacheService]';

  /// Save widget cache data
  /// Uses settings cache to determine what to write (source, location, theme, etc.)
  /// Also saves to Android widget_prefs for the native widget to access
  Future<bool> saveWidgetCache({
    required String fajr,
    required String sunrise,
    required String dhuhr,
    required String asr,
    required String maghrib,
    required String isha,
    required String source,
    required String location,
    required double hue,
    required bool isDarkMode,
    double bgTransparency = 1.0,
  }) async {
    try {
      debugPrint('$_debugTag Saving widget cache...');
      
      // Get current date in dd/mm/yyyy format
      final now = DateTime.now();
      final cacheDateDdMmYyyy = 
          '${now.day.toString().padLeft(2, '0')}/'
          '${now.month.toString().padLeft(2, '0')}/'
          '${now.year}';
      
      final cacheData = WidgetCacheData(
        fajr: fajr,
        sunrise: sunrise,
        dhuhr: dhuhr,
        asr: asr,
        maghrib: maghrib,
        isha: isha,
        source: source,
        location: location,
        hue: hue,
        isDarkMode: isDarkMode,
        bgTransparency: bgTransparency,
        cacheDateDdMmYyyy: cacheDateDdMmYyyy,
        cacheTimestampMs: now.millisecondsSinceEpoch,
      );

      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(cacheData.toJson());
      
      // Log what we're saving
      debugPrint('$_debugTag [JSON-SAVE] Saving cache with: hue=${cacheData.hue}, isDarkMode=${cacheData.isDarkMode}');
      debugPrint('$_debugTag [JSON-SAVE] JSON string: $jsonString');
      debugPrint('$_debugTag [JSON-SAVE] Prayer times: Fajr=$fajr, Dhuhr=$dhuhr, Maghrib=$maghrib');
      
      // Save to Dart's cache
      final dartSuccess = await prefs.setString(_cacheKey, jsonString);
      debugPrint('$_debugTag Saved to Dart cache: $dartSuccess');
      
      // Also save to widget_prefs for Android native widget access
      // This uses the same SharedPreferences but with widget_prefs instance name
      try {
        // Save with a key that Android can access easily
        await prefs.setString('widget_info_cache', jsonString);
        debugPrint('$_debugTag Also saved to widget_info_cache key for Android');
      } catch (e) {
        debugPrint('$_debugTag Warning: Could not save to widget_info_cache: $e');
      }
      
      if (dartSuccess) {
        debugPrint('$_debugTag Cache saved successfully');
        debugPrint('$_debugTag Cache details: $cacheData');
      } else {
        debugPrint('$_debugTag ERROR: Failed to save cache to SharedPreferences');
      }
      
      return dartSuccess;
    } catch (e, st) {
      debugPrint('$_debugTag ERROR saving cache: $e');
      debugPrint('$_debugTag Stack trace: $st');
      return false;
    }
  }

  /// Retrieve widget cache data
  /// Returns null if cache is expired or not found
  Future<WidgetCacheData?> getWidgetCache() async {
    try {
      debugPrint('$_debugTag Retrieving widget cache...');
      
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_cacheKey);
      
      if (jsonString == null) {
        debugPrint('$_debugTag No cache found in SharedPreferences');
        return null;
      }

      try {
        final jsonData = jsonDecode(jsonString) as Map<String, dynamic>;
        final cacheData = WidgetCacheData.fromJson(jsonData);
        
        debugPrint('$_debugTag Cache retrieved: $cacheData');
        
        // Check if cache is expired
        if (cacheData.isExpired()) {
          debugPrint('$_debugTag Cache has expired, clearing it');
          await clearWidgetCache();
          return null;
        }
        
        return cacheData;
      } catch (parseError, parseSt) {
        debugPrint('$_debugTag ERROR parsing cache JSON: $parseError');
        debugPrint('$_debugTag Stack trace: $parseSt');
        debugPrint('$_debugTag Clearing corrupted cache');
        await clearWidgetCache();
        return null;
      }
    } catch (e, st) {
      debugPrint('$_debugTag ERROR retrieving cache: $e');
      debugPrint('$_debugTag Stack trace: $st');
      return null;
    }
  }

  /// Clear the widget cache
  Future<bool> clearWidgetCache() async {
    try {
      debugPrint('$_debugTag Clearing widget cache...');
      
      final prefs = await SharedPreferences.getInstance();
      final success = await prefs.remove(_cacheKey);
      
      if (success) {
        debugPrint('$_debugTag Cache cleared successfully');
      } else {
        debugPrint('$_debugTag ERROR: Failed to clear cache');
      }
      
      return success;
    } catch (e, st) {
      debugPrint('$_debugTag ERROR clearing cache: $e');
      debugPrint('$_debugTag Stack trace: $st');
      return false;
    }
  }

  /// Check if cache exists and is valid
  Future<bool> hasCacheAndValid() async {
    try {
      final cache = await getWidgetCache();
      return cache != null && !cache.isExpired();
    } catch (e) {
      debugPrint('$_debugTag ERROR checking cache validity: $e');
      return false;
    }
  }

  /// Get cache age in hours
  Future<double?> getCacheAgeInHours() async {
    try {
      final cache = await getWidgetCache();
      if (cache == null) return null;
      
      final now = DateTime.now().millisecondsSinceEpoch;
      final ageMs = now - cache.cacheTimestampMs;
      return ageMs / (1000 * 60 * 60);
    } catch (e) {
      debugPrint('$_debugTag ERROR getting cache age: $e');
      return null;
    }
  }
}
