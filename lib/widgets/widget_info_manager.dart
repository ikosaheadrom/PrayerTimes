import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/prayer_times_provider.dart';
import 'widget_cache_service.dart' show WidgetCacheService, WidgetCacheData;

/// Main widget controller that manages prayer times caching and updates
class WidgetInfoManager {
  static const String _debugTag = '[WidgetInfoManager]';
  
  /// Latin names mapping for Arabic city names
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
  
  /// Get Latin name for Arabic city name
  String _getLatinCityName(String arabicName) {
    return latinNames[arabicName] ?? arabicName;
  }
  
  final WidgetCacheService _cacheService = WidgetCacheService();

  /// SIMPLE: Fetch fresh prayer times from current source and save to cache
  /// Uses PrayerTimesProvider for unified source selection
  Future<bool> fetchAndCacheFreshPrayerTimes() async {
    try {
      debugPrint('$_debugTag Fetching FRESH prayer times from source...');
      
      // Use unified provider to get prayer times
      final provider = PrayerTimesProvider();
      final result = await provider.getPrayerTimes();
      
      debugPrint('$_debugTag ✓ Got prayer times from provider:');
      debugPrint('$_debugTag   Source: ${result.sourceUsed}');
      debugPrint('$_debugTag   Input: ${result.inputSettings}');
      debugPrint('$_debugTag   Times: ${result.times}');
      
      final prayerTimes = result.times;
      final sourceLabel = result.sourceUsed;
      
      // Check if we got valid data
      if (prayerTimes['fajr'] == 'N/A' || prayerTimes['dhuhr'] == 'N/A' || prayerTimes['maghrib'] == 'N/A') {
        debugPrint('$_debugTag ✗ Provider returned invalid times');
        return false;
      }
      
      // Convert to format expected by cache (capitalize keys)
      final capitalizedTimes = {
        'Fajr': prayerTimes['fajr'] ?? 'N/A',
        'Sunrise': prayerTimes['sunrise'] ?? 'N/A',
        'Dhuhr': prayerTimes['dhuhr'] ?? 'N/A',
        'Asr': prayerTimes['asr'] ?? 'N/A',
        'Maghrib': prayerTimes['maghrib'] ?? 'N/A',
        'Isha': prayerTimes['isha'] ?? 'N/A',
      };
      
      if (prayerTimes.isEmpty) {
        debugPrint('$_debugTag ERROR: Could not get prayer times from ANY source');
        return false;
      }
      
      // Get location from provider result
      final location = result.cityName ?? 'Unknown';
      
      // Transliterate location from Arabic to Latin if it's a city name
      final displayLocation = _getLatinCityName(location);
      
      // Get theme settings
      final prefs = await SharedPreferences.getInstance();
      final themeMode = prefs.getString('themeMode') ?? 'light';
      final isDarkMode = themeMode == 'dark';
      final primaryHue = prefs.getDouble('primaryHue') ?? 260.0;
      final bgTransparency = prefs.getDouble('widgetBgTransparency') ?? 1.0;
      
      // Save to widget cache
      final success = await _cacheService.saveWidgetCache(
        fajr: capitalizedTimes['Fajr'] ?? 'N/A',
        sunrise: capitalizedTimes['Sunrise'] ?? 'N/A',
        dhuhr: capitalizedTimes['Dhuhr'] ?? 'N/A',
        asr: capitalizedTimes['Asr'] ?? 'N/A',
        maghrib: capitalizedTimes['Maghrib'] ?? 'N/A',
        isha: capitalizedTimes['Isha'] ?? 'N/A',
        source: sourceLabel,
        location: displayLocation,
        hue: primaryHue,
        isDarkMode: isDarkMode,
        bgTransparency: bgTransparency,
      );
      
      if (success) {
        debugPrint('$_debugTag ✓ FRESH prayer times SAVED to widget cache (source=$sourceLabel)');
        debugPrint('$_debugTag   Fajr=${prayerTimes['Fajr']}, Dhuhr=${prayerTimes['Dhuhr']}, Maghrib=${prayerTimes['Maghrib']}');
      } else {
        debugPrint('$_debugTag ✗ Failed to save prayer times to cache');
      }
      
      return success;
    } catch (e, st) {
      debugPrint('$_debugTag EXCEPTION in fetchAndCacheFreshPrayerTimes: $e');
      debugPrint('$_debugTag Stack trace: $st');
      return false;
    }
  }

  /// Quick update widget cache with current prayer times from selected source
  /// This reads app settings and fetches times based on the current source selection
  /// Useful for immediate updates when settings change or user requests refresh
  /// After updating cache, triggers widget refresh via broadcast
  Future<bool> quickUpdateWidgetCache() async {
    try {
      debugPrint('$_debugTag quickUpdateWidgetCache: Starting quick widget cache update...');
      
      // Step 1: Fetch and cache fresh prayer times
      final success = await fetchAndCacheFreshPrayerTimes();
      
      if (success) {
        debugPrint('$_debugTag quickUpdateWidgetCache: ✓ Cache updated successfully');
        
        // Step 2: Trigger widget refresh via broadcast to ensure UI updates
        debugPrint('$_debugTag quickUpdateWidgetCache: Triggering widget UI update...');
        try {
          const platform = MethodChannel('com.example.pray_time/widget');
          final result = await platform.invokeMethod('sendWidgetUpdateBroadcast');
          debugPrint('$_debugTag quickUpdateWidgetCache: ✓ Widget refresh broadcast sent: $result');
        } catch (e) {
          // Widget refresh from isolate might fail, but that's OK
          // The cache was updated, and the widget will read the new data
          debugPrint('$_debugTag quickUpdateWidgetCache: ⚠ Could not send broadcast from here: $e');
          debugPrint('$_debugTag quickUpdateWidgetCache: NOTE: Widget will still use updated cache');
        }
      } else {
        debugPrint('$_debugTag quickUpdateWidgetCache: ✗ Failed to update cache');
      }
      
      return success;
    } catch (e, st) {
      debugPrint('$_debugTag quickUpdateWidgetCache: EXCEPTION: $e');
      debugPrint('$_debugTag quickUpdateWidgetCache: Stack: $st');
      return false;
    }
  }

  /// Update widget information cache
  /// This should be called regularly (from background tasks, etc.)
  /// 
  /// Returns true if successful, false otherwise
  Future<bool> updateWidgetInfo() async {
    try {
      debugPrint('$_debugTag Updating widget information...');
      
      final success = await fetchAndCacheFreshPrayerTimes();
      
      if (success) {
        debugPrint('$_debugTag Widget information updated successfully');
      } else {
        debugPrint('$_debugTag ERROR: Failed to update widget information');
      }
      
      return success;
    } catch (e, st) {
      debugPrint('$_debugTag EXCEPTION updating widget info: $e');
      debugPrint('$_debugTag Stack trace: $st');
      return false;
    }
  }

  /// Get current widget cache data
  /// 
  /// Returns WidgetCacheData if valid cache exists, null otherwise
  Future<WidgetCacheData?> getWidgetData() async {
    try {
      debugPrint('$_debugTag Retrieving widget data...');
      
      final cache = await _cacheService.getWidgetCache();
      
      if (cache == null) {
        debugPrint('$_debugTag Widget cache is empty or expired');
      } else {
        debugPrint('$_debugTag Widget data retrieved: ${cache.location}');
      }
      
      return cache;
    } catch (e, st) {
      debugPrint('$_debugTag ERROR retrieving widget data: $e');
      debugPrint('$_debugTag Stack trace: $st');
      return null;
    }
  }

  /// Check if widget cache is valid and not expired
  /// 
  /// Returns true if cache exists and is still valid
  Future<bool> isWidgetCacheValid() async {
    try {
      return await _cacheService.hasCacheAndValid();
    } catch (e) {
      debugPrint('$_debugTag ERROR checking cache validity: $e');
      return false;
    }
  }

  /// Force refresh widget cache
  /// Clears old cache and fetches new prayer times
  /// 
  /// Returns true if successful
  Future<bool> forceRefreshWidget() async {
    try {
      debugPrint('$_debugTag Force refreshing widget cache...');
      
      // Clear old cache
      await _cacheService.clearWidgetCache();
      
      // Fetch and cache new data
      final success = await fetchAndCacheFreshPrayerTimes();
      
      if (success) {
        debugPrint('$_debugTag Widget cache force refresh successful');
      } else {
        debugPrint('$_debugTag ERROR: Force refresh failed');
      }
      
      return success;
    } catch (e, st) {
      debugPrint('$_debugTag EXCEPTION during force refresh: $e');
      debugPrint('$_debugTag Stack trace: $st');
      return false;
    }
  }

  /// Get cache age in hours
  /// 
  /// Returns null if no cache exists
  Future<double?> getCacheAgeInHours() async {
    try {
      return await _cacheService.getCacheAgeInHours();
    } catch (e) {
      debugPrint('$_debugTag ERROR getting cache age: $e');
      return null;
    }
  }

  /// Clear widget cache completely
  /// 
  /// Returns true if successful
  Future<bool> clearCache() async {
    try {
      debugPrint('$_debugTag Clearing widget cache...');
      
      final success = await _cacheService.clearWidgetCache();
      
      if (success) {
        debugPrint('$_debugTag Widget cache cleared successfully');
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

  /// Get widget cache statistics for debugging
  /// 
  /// Returns a debug string with cache information
  Future<String> getCacheDebugInfo() async {
    try {
      final cache = await _cacheService.getWidgetCache();
      
      if (cache == null) {
        return 'No widget cache found';
      }
      
      final age = await _cacheService.getCacheAgeInHours();
      final ageStr = age != null ? '${age.toStringAsFixed(2)} hours' : 'Unknown';
      
      return '''
Widget Cache Debug Info:
- Location: ${cache.location}
- Source: ${cache.source}
- Theme: ${cache.isDarkMode ? 'Dark' : 'Light'}
- Hue: ${cache.hue.toStringAsFixed(1)}
- Cache Date: ${cache.cacheDateDdMmYyyy}
- Cache Age: $ageStr
- Prayer Times:
  - Fajr: ${cache.fajr}
  - Sunrise: ${cache.sunrise}
  - Dhuhr: ${cache.dhuhr}
  - Asr: ${cache.asr}
  - Maghrib: ${cache.maghrib}
  - Isha: ${cache.isha}
''';
    } catch (e, st) {
      debugPrint('$_debugTag ERROR getting cache debug info: $e');
      debugPrint('$_debugTag Stack trace: $st');
      return 'Error retrieving cache debug info';
    }
  }
}
