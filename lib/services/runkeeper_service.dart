import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';
import 'data_cache.dart';

class RunkeeperService {
  static const _storage = FlutterSecureStorage();
  static const _cookiesKey = 'runkeeper_cookies';
  static const _lastImportKey = 'runkeeper_last_import';

  static Future<bool> isLoggedIn() async {
    final cookies = await _storage.read(key: _cookiesKey);
    return cookies != null && cookies.isNotEmpty;
  }

  static Future<void> saveCookies(List<Cookie> cookies) async {
    final list = cookies.map((c) => {
      'name': c.name,
      'value': c.value,
      'domain': c.domain,
      'path': c.path,
    }).toList();
    await _storage.write(key: _cookiesKey, value: jsonEncode(list));
  }

  static Future<String?> _cookieHeader() async {
    final raw = await _storage.read(key: _cookiesKey);
    if (raw == null) return null;
    final list = jsonDecode(raw) as List;
    return list.map((c) => '${c['name']}=${c['value']}').join('; ');
  }

  static Future<DateTime?> lastImportDate() async {
    final s = await _storage.read(key: _lastImportKey);
    if (s == null) return null;
    return DateTime.tryParse(s);
  }

  static Future<void> _setLastImport(DateTime dt) async {
    await _storage.write(key: _lastImportKey, value: dt.toIso8601String());
  }

  /// Returns true if an import was performed.
  static Future<bool> importIfNeeded({bool force = false}) async {
    if (!await isLoggedIn()) return false;

    final last = await lastImportDate();
    final today = DateTime.now();
    final isToday = last != null &&
        last.year == today.year &&
        last.month == today.month &&
        last.day == today.day;

    if (isToday && !force) return false;

    await _doExportAndDownload();
    await _setLastImport(DateTime.now());
    DataCache.clearPrefix('runkeeper_hr');
    return true;
  }

  static Future<void> _doExportAndDownload() async {
    final cookieHeader = await _cookieHeader();
    if (cookieHeader == null) throw Exception('No Runkeeper cookies');

    // ignore: avoid_print
    print('Runkeeper: submitting portability export');
    final exportRes = await http.post(
      Uri.parse('https://runkeeper.com/exportData'),
      headers: {
        'Cookie': cookieHeader,
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'Mozilla/5.0',
      },
      body: {
        '_eventName': 'handleExport',
        'exportType': 'PORTABILITY',
      },
    );

    if (exportRes.statusCode != 200 && exportRes.statusCode != 302) {
      throw Exception('Export submit failed: ${exportRes.statusCode}');
    }

    String? zipUrl;
    for (var i = 0; i < 36; i++) {
      await Future.delayed(const Duration(seconds: 5));
      final page = await http.get(
        Uri.parse('https://runkeeper.com/exportData'),
        headers: {'Cookie': cookieHeader, 'User-Agent': 'Mozilla/5.0'},
      );

      final packageMatch = RegExp(
        r'href="(https://s3\.amazonaws\.com/hrmfile\.runkeeper\.com/export/[^"]+\.zip)"[^>]*>Download Package',
      ).firstMatch(page.body);
      if (packageMatch != null) {
        zipUrl = packageMatch.group(1);
        // ignore: avoid_print
        print('Runkeeper: found Download Package link');
        break;
      }

      final anyMatch = RegExp(
        r'href="(https://s3\.amazonaws\.com/hrmfile\.runkeeper\.com/export/[^"]+\.zip)"',
      ).firstMatch(page.body);
      if (anyMatch != null && i > 2) {
        zipUrl = anyMatch.group(1);
        // ignore: avoid_print
        print('Runkeeper: using first available S3 link');
        break;
      }
      // ignore: avoid_print
      print('Runkeeper: waiting for package link... (${(i + 1) * 5}s)');
    }

    if (zipUrl == null) throw Exception('No download link appeared');

    // ignore: avoid_print
    print('Runkeeper: downloading $zipUrl');
    final zipRes = await http.get(Uri.parse(zipUrl));
    if (zipRes.statusCode != 200) {
      throw Exception('ZIP download failed: ${zipRes.statusCode}');
    }

    final bytes = zipRes.bodyBytes;
    // ignore: avoid_print
    print('Runkeeper: ZIP size ${bytes.length} bytes');

    final dir = await getApplicationDocumentsDirectory();
    final zipFile = File('${dir.path}/runkeeper-latest.zip');
    await zipFile.writeAsBytes(bytes);

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      // ignore: avoid_print
      print('Runkeeper: ZIP decode failed: $e');
      return;
    }

    final gpxDir = Directory('${dir.path}/runkeeper-gpx');
    if (await gpxDir.exists()) await gpxDir.delete(recursive: true);
    await gpxDir.create();

    int gpxCount = 0;
    for (final file in archive) {
      if (file.isFile && file.name.toLowerCase().endsWith('.gpx')) {
        final out = File('${gpxDir.path}/${file.name.split('/').last}');
        await out.writeAsBytes(file.content as List<int>);
        gpxCount++;
      }
    }
    // ignore: avoid_print
    print('Runkeeper: extracted $gpxCount GPX files');
  }

  /// Extract date from GPX filename like "2026-10-20-142717.gpx" → DateTime(2026,10,20)
  static DateTime? _dateFromFilename(String name) {
    final match = RegExp(r'(\d{4})-(\d{2})-(\d{2})').firstMatch(name);
    if (match == null) return null;
    return DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  /// Load HR samples. Optionally filter to files whose date is near [windowStart]/[windowEnd].
  /// Results are cached per window so the same run doesn't re-parse GPX files.
  static Future<List<Map<String, dynamic>>> loadHeartRateSamples({
    DateTime? windowStart,
    DateTime? windowEnd,
  }) async {
    final cacheKey = 'runkeeper_hr|${windowStart?.toIso8601String() ?? "all"}|${windowEnd?.toIso8601String() ?? "all"}';
    final cached = DataCache.get<List<Map<String, dynamic>>>(cacheKey);
    if (cached != null) return cached;

    final dir = await getApplicationDocumentsDirectory();
    final gpxDir = Directory('${dir.path}/runkeeper-gpx');
    if (!await gpxDir.exists()) return [];

    final samples = <Map<String, dynamic>>[];
    int filesParsed = 0;

    await for (final entity in gpxDir.list()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.gpx')) continue;

      final fileName = entity.path.split('/').last;
      final fileDate = _dateFromFilename(fileName);

      // Pre-filter by filename date if a window is given (±1 day tolerance)
      if (windowStart != null && windowEnd != null && fileDate != null) {
        final windowStartDay = DateTime(windowStart.year, windowStart.month, windowStart.day);
        final windowEndDay = DateTime(windowEnd.year, windowEnd.month, windowEnd.day);
        if (fileDate.isBefore(windowStartDay.subtract(const Duration(days: 1))) ||
            fileDate.isAfter(windowEndDay.add(const Duration(days: 1)))) {
          continue;
        }
      }

      filesParsed++;
      final xml = await entity.readAsString();
      samples.addAll(heartRateSamplesFromGpxXml(xml));
    }

    samples.sort((a, b) => (a['time'] as DateTime).compareTo(b['time'] as DateTime));
    // ignore: avoid_print
    print('Runkeeper: parsed $filesParsed GPX files → ${samples.length} HR samples (cached)');
    DataCache.set(cacheKey, samples);
    return samples;
  }
}

/// Heart-rate samples from one Runkeeper GPX file.
///
/// Track points use the GPX namespace and the strap rate lives in a Garmin
/// `gpxtpx:hr` extension, so matching is by local name. Decimal values such as
/// `149.5` are kept; the old `int.tryParse` dropped them.
List<Map<String, dynamic>> heartRateSamplesFromGpxXml(String xml) {
  final doc = XmlDocument.parse(xml);
  final samples = <Map<String, dynamic>>[];

  for (final pt in doc.descendants.whereType<XmlElement>()) {
    if (pt.name.local != 'trkpt') continue;

    String? timeText;
    String? hrText;
    for (final el in pt.descendants.whereType<XmlElement>()) {
      final local = el.name.local;
      if (local == 'time' && timeText == null) {
        timeText = el.innerText;
      } else if (local == 'hr' && hrText == null) {
        hrText = el.innerText;
      }
      if (timeText != null && hrText != null) break;
    }
    if (timeText == null || hrText == null) continue;

    final time = DateTime.tryParse(timeText.trim());
    final hr = double.tryParse(hrText.trim());
    if (time == null || hr == null) continue;
    samples.add({'time': time, 'hr': hr});
  }

  return samples;
}
