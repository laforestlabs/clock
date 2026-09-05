// Turning a rough human location into mirror coordinates: the lookup the
// setup wizard uses so an owner can type a ZIP code, a city, or nothing more
// precise than a name, and still end up with the decimal degrees the weather
// provider needs.
//
// Geocoding goes to Open-Meteo's free search API, the same provider the
// firmware's weather already talks to: no API key, no signup, no second
// vendor to trust, which keeps the project's zero-weather-credential stance
// intact. The response carries an IANA timezone name, so the wizard can also
// preselect the mirror's POSIX TZ instead of asking the owner to know it; the
// firmware only accepts POSIX strings (see the MIRROR_TIMEZONE Kconfig help),
// hence [posixTzForIana].
//
// The fetcher is injectable so the wizard's logic is testable without a
// network, like the rest of the protocol layer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One geocoding hit: a place, its coordinates, and what the wizard can
/// derive from it (IANA timezone for TZ preselection, country code for the
/// Fahrenheit/Celsius guess).
class GeocodeResult {
  const GeocodeResult({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.admin1,
    this.country,
    this.countryCode,
    this.timezone,
  });

  final String name;
  final double latitude;
  final double longitude;

  /// State/province/region, when the provider knows one.
  final String? admin1;

  /// Country display name, e.g. "Germany".
  final String? country;

  /// ISO 3166-1 alpha-2 code, e.g. "DE".
  final String? countryCode;

  /// IANA zone name (the geocoder's only timezone form), e.g.
  /// "America/Los_Angeles". Not what the firmware stores; run it through
  /// [posixTzForIana].
  final String? timezone;

  /// The list label: "Berlin, Germany", "San Francisco, California, US"...
  /// Disambiguates the many cities that share a name.
  String get fullLabel {
    final parts = <String>[
      name,
      if (admin1 != null && admin1!.isNotEmpty) admin1!,
      if (country != null && country!.isNotEmpty) country!,
    ];
    // Drop consecutive duplicates: for a city-state like Singapore the
    // provider repeats the name as its region.
    final deduped = <String>[];
    for (final p in parts) {
      if (deduped.isEmpty || deduped.last != p) deduped.add(p);
    }
    return deduped.join(', ');
  }

  /// A starting value for the mirror's place label: the short name, clipped
  /// to what the firmware's weather.place buffer holds (23 chars).
  String get placeDraft => name.length <= 23 ? name : name.substring(0, 23);

  static GeocodeResult? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final lat = json['latitude'];
    final lon = json['longitude'];
    if (name is! String || lat is! num || lon is! num) return null;
    return GeocodeResult(
      name: name,
      latitude: lat.toDouble(),
      longitude: lon.toDouble(),
      admin1: json['admin1'] is String ? json['admin1'] as String : null,
      country: json['country'] is String ? json['country'] as String : null,
      countryCode: json['country_code'] is String
          ? json['country_code'] as String
          : null,
      timezone: json['timezone'] is String ? json['timezone'] as String : null,
    );
  }
}

/// The HTTP seam: fetch a URL's body as text. Tests inject a fake.
typedef GeoFetcher = Future<String> Function(Uri url);

Future<String> _httpFetcher(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(url).timeout(const Duration(seconds: 10));
    req.headers.set(HttpHeaders.userAgentHeader, 'mirror-designer-setup');
    final resp = await req.close().timeout(const Duration(seconds: 10));
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw Exception('location lookup failed: HTTP ${resp.statusCode}');
    }
    return body;
  } on SocketException catch (e) {
    throw Exception('could not reach the location lookup: ${e.message}');
  } finally {
    client.close(force: true);
  }
}

/// "lat, lon" (also "; " or plain space as separators), with no other words
/// around it. The configure dialog has always accepted raw coordinates, and
/// the wizard's single location field should too.
final RegExp _coordQueryPattern = RegExp(
  r'^\s*(-?\d+(?:\.\d+)?)\s*[,;]\s*(-?\d+(?:\.\d+)?)\s*$',
);

/// The raw-coordinates form of a location query: "51.5074, -0.1278". Returns
/// null when the text is not a pair of numbers in coordinate range.
GeocodeResult? parseCoordinateQuery(String query) {
  final m = _coordQueryPattern.firstMatch(query);
  if (m == null) return null;
  final lat = double.tryParse(m.group(1)!);
  final lon = double.tryParse(m.group(2)!);
  if (lat == null || lon == null) return null;
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
  return GeocodeResult(
    name: 'Pinned location',
    latitude: lat,
    longitude: lon,
  );
}

/// Look up [query]: a postal/ZIP code ("94105"), a city ("Berlin"), a
/// "city, region" pair, or raw "lat, lon". Returns best-first hits (the
/// provider orders by population/relevance), empty when nothing matched.
///
/// The Open-Meteo geocoder indexes GeoNames, whose postal-code data makes a
/// ZIP query resolve to its city, so an owner can be as imprecise as they
/// like as long as they are roughly right.
///
/// Throws [Exception] with a human message on transport or API failure.
Future<List<GeocodeResult>> geocodeSearch(
  String query, {
  GeoFetcher fetcher = _httpFetcher,
}) async {
  final direct = parseCoordinateQuery(query);
  if (direct != null) return <GeocodeResult>[direct];

  final q = query.trim();
  if (q.isEmpty) return const <GeocodeResult>[];

  final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
    'name': q,
    'count': '8',
    'language': 'en',
    'format': 'json',
  });
  final body = await fetcher(uri);
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) return const <GeocodeResult>[];
  final results = decoded['results'];
  if (results is! List) return const <GeocodeResult>[];
  return results
      .whereType<Map<String, dynamic>>()
      .map(GeocodeResult.fromJson)
      .whereType<GeocodeResult>()
      .toList(growable: false);
}

/// IANA zone names the wizard can translate into a POSIX TZ string the
/// firmware accepts, and the exact POSIX strings the firmware presets ship
/// (see kTimezonePresets). Zones missing here simply leave the timezone step
/// unset; the owner still picks from the preset list or types a custom
/// string. Only include an entry when its DST rules are current and the
/// resulting string passes the firmware's POSIX shape check.
const Map<String, String> _posixTzByIana = <String, String>{
  // UTC.
  'UTC': 'UTC0',

  // United States and Canada (DST since 2007: 2nd Sunday Mar, 1st Sunday Nov).
  'America/New_York': 'EST5EDT,M3.2.0,M11.1.0',
  'America/Detroit': 'EST5EDT,M3.2.0,M11.1.0',
  'America/Toronto': 'EST5EDT,M3.2.0,M11.1.0',
  'America/Montreal': 'EST5EDT,M3.2.0,M11.1.0',
  'America/Chicago': 'CST6CDT,M3.2.0,M11.1.0',
  'America/Winnipeg': 'CST6CDT,M3.2.0,M11.1.0',
  'America/Denver': 'MST7MDT,M3.2.0,M11.1.0',
  'America/Edmonton': 'MST7MDT,M3.2.0,M11.1.0',
  'America/Boise': 'MST7MDT,M3.2.0,M11.1.0',
  'America/Phoenix': 'MST7',
  'America/Los_Angeles': 'PST8PDT,M3.2.0,M11.1.0',
  'America/Vancouver': 'PST8PDT,M3.2.0,M11.1.0',
  'America/Anchorage': 'AKST9AKDT,M3.2.0,M11.1.0',
  'America/Halifax': 'AST4ADT,M3.2.0,M11.1.0',
  'Pacific/Honolulu': 'HST10',

  // Mexico (no DST since 2022; Baja California follows the US rules).
  'America/Mexico_City': 'CST6',
  'America/Tijuana': 'PST8PDT,M3.2.0,M11.1.0',

  // Europe (EU-wide transitions; strings match the shipped presets).
  'Europe/London': 'GMT0BST,M3.5.0/1,M10.5.0',
  'Europe/Berlin': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Paris': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Madrid': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Rome': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Amsterdam': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Brussels': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Vienna': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Warsaw': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Prague': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Stockholm': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Copenhagen': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Oslo': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Athens': 'EET-2EEST,M3.5.0/3,M10.5.0/3',
  'Europe/Helsinki': 'EET-2EEST,M3.5.0/3,M10.5.0/3',
  'Europe/Bucharest': 'EET-2EEST,M3.5.0/3,M10.5.0/3',
  'Europe/Riga': 'EET-2EEST,M3.5.0/3,M10.5.0/3',
  'Europe/Tallinn': 'EET-2EEST,M3.5.0/3,M10.5.0/3',
  'Europe/Vilnius': 'EET-2EEST,M3.5.0/3,M10.5.0/3',
  'Europe/Moscow': 'MSK-3',
  'Europe/Lisbon': 'WET0WEST,M3.5.0/1,M10.5.0/1',

  // Africa.
  'Africa/Lagos': 'WAT-1',
  'Africa/Johannesburg': 'SAST-2',
  'Africa/Cairo': 'EET-2',
  'Africa/Nairobi': 'EAT-3',

  // Asia.
  'Asia/Tokyo': 'JST-9',
  'Asia/Seoul': 'KST-9',
  'Asia/Shanghai': 'CST-8',
  'Asia/Hong_Kong': 'HKT-8',
  'Asia/Singapore': 'SGT-8',
  'Asia/Kuala_Lumpur': 'MYT-8',
  'Asia/Jakarta': 'WIB-7',
  'Asia/Bangkok': 'ICT-7',
  'Asia/Ho_Chi_Minh': 'ICT-7',
  'Asia/Manila': 'PHT-8',
  'Asia/Dubai': 'GST-4',
  'Asia/Karachi': 'PKT-5',
  'Asia/Kolkata': 'IST-5:30',

  // Australia (strings match the shipped Sydney preset).
  'Australia/Sydney': 'AEST-10AEDT,M10.1.0,M4.1.0/3',
  'Australia/Melbourne': 'AEST-10AEDT,M10.1.0,M4.1.0/3',
  'Australia/Brisbane': 'AEST-10',
  'Australia/Perth': 'AWST-8',
  'Australia/Adelaide': 'ACST-9:30ACDT,M10.1.0,M4.1.0/3',
  'Australia/Darwin': 'ACST-9:30',

  // South America (Buenos Aires and Santiago omitted: their DST rules have
  // changed repeatedly, and a wrong one would put the clock an hour out).
  'America/Sao_Paulo': 'BRT3',
  'America/Bogota': 'COT5',
  'America/Lima': 'PET5',
  'America/Caracas': 'VET4:30',
};

/// The POSIX TZ string for an IANA zone name, or null when the name is
/// unknown. Unknown is not an error: the wizard leaves the timezone dropdown
/// unselected and the owner picks.
String? posixTzForIana(String? iana) =>
    iana == null ? null : _posixTzByIana[iana];

/// Countries where everyday weather is spoken in Fahrenheit. The wizard uses
/// this to preselect the display unit from the chosen location's country
/// code; it only ever prefills a choice the owner still sees.
const Set<String> _fahrenheitCountries = <String>{
  'US', 'PR', 'GU', 'VI', 'AS', // US and territories
  'BS', 'BB', 'BZ', 'KY', 'TC', 'VG', 'AI', // Caribbean / Central America
  'LR', 'MM', // Liberia, Myanmar
  'FJ', 'VU', 'WS', 'TO', 'CK', // Pacific islands
};

/// True for Fahrenheit, false for Celsius. Null only when the geocoder gave
/// no country code at all (raw pin, manual coordinates): leave the factory
/// default standing. Known countries outside the Fahrenheit set are Celsius.
bool? tempFForCountry(String? countryCode) {
  if (countryCode == null) return null;
  return _fahrenheitCountries.contains(countryCode.toUpperCase());
}
