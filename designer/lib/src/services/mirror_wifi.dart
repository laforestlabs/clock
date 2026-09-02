// WiFi credentials for the mirror, pushed over Bluetooth.
//
// The firmware (firmware/main/net/provision.c) stores these in NVS, separate
// from the owner config in mirror_config.dart. The validation rules here
// mirror provision_apply_json's apply_creds_and_connect exactly: a push that
// passes here is accepted by the device, and one that fails here would be
// rejected there, so the phone never fights the mirror.

/// One WiFi credential set. An empty [pass] means an open network.
class WifiConfig {
  const WifiConfig({required this.ssid, this.pass = ''});

  final String ssid;
  final String pass;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ssid': ssid,
        'pass': pass,
      };

  /// Null when valid, otherwise a human message naming the first offending
  /// field. Mirrors the firmware rules: SSID non-empty and at most 31 chars
  /// (the WPA2 limit minus one for the portal's storage buffer), pass at most
  /// 63 chars.
  String? validate() {
    if (ssid.isEmpty) return 'SSID is required';
    if (ssid.length > 31) return 'SSID too long';
    if (pass.length > 63) return 'password too long';
    return null;
  }
}
