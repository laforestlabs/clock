// Owner-settable device configuration: timezone, coordinates, place label.
//
// These are the fields the firmware keeps in NVS and the phone pushes over
// Bluetooth. The validation rules here mirror firmware/main/config.c exactly:
// a push that passes here is accepted by the device, and one that fails here
// would be rejected there, so the phone never fights the mirror.

/// One device-config field set. A null field means "leave it unchanged" on
/// push, which is how a partial update (e.g. coordinates only) is expressed.
class MirrorConfig {
  const MirrorConfig({
    this.timezone,
    this.latitude,
    this.longitude,
    this.place,
  });

  final String? timezone;
  final String? latitude;
  final String? longitude;
  final String? place;

  /// Only the non-null fields, which is exactly what the firmware accepts.
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (timezone != null) 'timezone': timezone,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (place != null) 'place': place,
      };

  /// Parse a decoded JSON object. Returns null when the object carries none
  /// of the four known fields.
  static MirrorConfig? fromJson(Map<String, dynamic> json) {
    String? str(String key) => json[key] is String ? json[key] as String : null;

    final timezone = str('timezone');
    final latitude = str('latitude');
    final longitude = str('longitude');
    final place = str('place');
    if (timezone == null &&
        latitude == null &&
        longitude == null &&
        place == null) {
      return null;
    }
    return MirrorConfig(
      timezone: timezone,
      latitude: latitude,
      longitude: longitude,
      place: place,
    );
  }

  /// Null when valid, otherwise a human message naming the first offending
  /// field. Mirrors the firmware rules: timezone non-empty and at most 63
  /// chars, latitude a number in [-90, 90], longitude a number in [-180,
  /// 180], place at most 23 chars (fits the firmware's weather.place[24]).
  String? validate() {
    if (timezone != null) {
      final tz = timezone!;
      if (tz.isEmpty) return 'Timezone must not be empty';
      if (tz.length > 63) return 'Timezone is too long (max 63)';
    }
    if (latitude != null) {
      final lat = double.tryParse(latitude!);
      if (lat == null || lat < -90 || lat > 90) {
        return 'Latitude must be a number in [-90, 90]';
      }
    }
    if (longitude != null) {
      final lon = double.tryParse(longitude!);
      if (lon == null || lon < -180 || lon > 180) {
        return 'Longitude must be a number in [-180, 180]';
      }
    }
    if (place != null && place!.length > 23) {
      return 'Place is too long (max 23)';
    }
    return null;
  }
}

/// A named timezone option for the configure dialog.
class TzPreset {
  const TzPreset(this.label, this.tz);

  final String label;
  final String tz;
}

/// The POSIX TZ strings the firmware understands (see the MIRROR_TIMEZONE
/// Kconfig help). A "Custom..." entry in the dialog covers anything else.
const List<TzPreset> kTimezonePresets = <TzPreset>[
  TzPreset('UTC', 'UTC0'),
  TzPreset('London', 'GMT0BST,M3.5.0/1,M10.5.0'),
  TzPreset('Berlin', 'CET-1CEST,M3.5.0,M10.5.0/3'),
  TzPreset('New York', 'EST5EDT,M3.2.0,M11.1.0'),
  TzPreset('Chicago', 'CST6CDT,M3.2.0,M11.1.0'),
  TzPreset('Denver', 'MST7MDT,M3.2.0,M11.1.0'),
  TzPreset('Phoenix (no DST)', 'MST7'),
  TzPreset('Los Angeles', 'PST8PDT,M3.2.0,M11.1.0'),
  TzPreset('Tokyo', 'JST-9'),
  TzPreset('Sydney', 'AEST-10AEDT,M10.1.0,M4.1.0/3'),
];
