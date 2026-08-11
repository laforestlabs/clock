// Owner-settable device configuration: timezone, coordinates, place label,
// brightness, clock format and temperature unit.
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
    this.brightness,
    this.clock12h,
    this.tempF,
  });

  final String? timezone;
  final String? latitude;
  final String? longitude;
  final String? place;

  /// Manual brightness override 0..255, or null to leave the device's current
  /// setting unchanged (which includes "auto"). The device's own "auto" value
  /// (-1) is read as null: there is no way to push "auto" through the config
  /// object, only through the BLE "set brightness auto" command.
  final int? brightness;

  /// True for a 12-hour clock ("03:41 PM"), false for 24-hour ("15:41").
  /// Null leaves the device's setting unchanged.
  final bool? clock12h;

  /// True for Fahrenheit, false for Celsius. Null leaves the device's setting
  /// unchanged.
  final bool? tempF;

  /// Only the non-null fields, which is exactly what the firmware accepts.
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (timezone != null) 'timezone': timezone,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (place != null) 'place': place,
        if (brightness != null) 'brightness': brightness,
        if (clock12h != null) 'clock12h': clock12h,
        if (tempF != null) 'temp_unit': tempF! ? 'F' : 'C',
      };

  /// Parse a decoded JSON object. Returns null when the object carries none
  /// of the seven known fields.
  static MirrorConfig? fromJson(Map<String, dynamic> json) {
    String? str(String key) => json[key] is String ? json[key] as String : null;

    final timezone = str('timezone');
    final latitude = str('latitude');
    final longitude = str('longitude');
    final place = str('place');
    final brightness = json['brightness'] is int
        ? (json['brightness'] as int == -1
            ? null /* device auto; see the field comment */
            : json['brightness'] as int)
        : null;
    final clock12h = json['clock12h'] is bool ? json['clock12h'] as bool : null;
    final tempUnit = str('temp_unit');
    final tempF = tempUnit == 'F' ? true : (tempUnit == 'C' ? false : null);
    if (timezone == null &&
        latitude == null &&
        longitude == null &&
        place == null &&
        brightness == null &&
        clock12h == null &&
        tempF == null) {
      return null;
    }
    return MirrorConfig(
      timezone: timezone,
      latitude: latitude,
      longitude: longitude,
      place: place,
      brightness: brightness,
      clock12h: clock12h,
      tempF: tempF,
    );
  }

  /// Null when valid, otherwise a human message naming the first offending
  /// field. Mirrors the firmware rules: timezone non-empty, at most 63 chars
  /// and shaped like a POSIX TZ string (the only form the firmware's newlib
  /// tzset parses), latitude a number in [-90, 90], longitude a number in
  /// [-180, 180], place at most 23 chars (fits the firmware's
  /// weather.place[24]), brightness an integer in [0, 255].
  String? validate() {
    if (timezone != null) {
      final tz = timezone!;
      if (tz.isEmpty) return 'Timezone must not be empty';
      if (tz.length > 63) return 'Timezone is too long (max 63)';
      if (!_isPosixTz(tz)) return 'Timezone must be a POSIX TZ string';
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
    if (brightness != null && (brightness! < 0 || brightness! > 255)) {
      return 'Brightness must be an integer in [0, 255]';
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

/// True when [tz] has the shape newlib's tzset understands: a standard name
/// of three or more ASCII letters, then a numeric UTC offset, then only the
/// POSIX TZ alphabet (letters, digits, + - . , : /) for the DST name and the
/// transition rules. Mirrors tz_is_posix in firmware config.c loop for loop;
/// keep the two in step.
bool _isPosixTz(String tz) {
  var i = 0;

  var letters = 0;
  while (i < tz.length && _isAsciiLetter(tz.codeUnitAt(i))) {
    letters++;
    i++;
  }
  if (letters < 3) return false;

  if (i < tz.length && (tz[i] == '+' || tz[i] == '-')) i++;

  var digits = 0;
  while (i < tz.length && _isDigit(tz.codeUnitAt(i))) {
    digits++;
    i++;
  }
  if (digits < 1 || digits > 2) return false;

  // Optional :mm[:ss] after the hours.
  if (i < tz.length && tz[i] == ':') {
    i++;
    digits = 0;
    while (i < tz.length && _isDigit(tz.codeUnitAt(i))) {
      digits++;
      i++;
    }
    if (digits != 2) return false;
    if (i < tz.length && tz[i] == ':') {
      i++;
      digits = 0;
      while (i < tz.length && _isDigit(tz.codeUnitAt(i))) {
        digits++;
        i++;
      }
      if (digits != 2) return false;
    }
  }

  // The remainder (dst name and rules) uses only the POSIX TZ alphabet.
  for (; i < tz.length; i++) {
    final c = tz.codeUnitAt(i);
    if (!_isAsciiLetter(c) &&
        !_isDigit(c) &&
        c != 0x2b && // '+'
        c != 0x2d && // '-'
        c != 0x2e && // '.'
        c != 0x2c && // ','
        c != 0x3a && // ':'
        c != 0x2f) {
      // '/'
      return false;
    }
  }
  return true;
}

bool _isAsciiLetter(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a); // A-Z, a-z

bool _isDigit(int c) => c >= 0x30 && c <= 0x39; // 0-9
