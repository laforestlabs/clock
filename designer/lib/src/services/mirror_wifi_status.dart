// Parsing of the BLE WiFi status lines, kept free of Flutter and plugin
// imports so it is unit testable like the rest of the protocol layer.
// The wire format is defined in firmware/main/net/ble.c:
//
//   get wifi      -> wifi {"saved":bool,"ssid":"...","ip":"...","connected":bool}
//   wifi scan     -> wifi-scan start, then one
//                    wifi-net {"ssid":"...","rssi":N,"open":bool,
//                              "auth":"open"|"secured"|"unsupported"} per
//                    network, then wifi-scan done <n> | wifi-scan error <why>
//                    Older firmware sends only "open", derived from the
//                    authmode alone, so it flags enterprise APs and PMF-
//                    mandating WPA2/WPA3-Enterprise as open; "auth" carries
//                    the cipher-aware verdict and always wins when present.
//   (async)       -> wifi connect ok <ip> | wifi connect error <why>
//   wifi forget   -> wifi forget ok

import 'dart:convert';

/// A parsed `wifi {...}` status line.
class BleWifiStatus {
  const BleWifiStatus({
    required this.saved,
    required this.ssid,
    required this.ip,
    required this.connected,
  });

  /// True when credentials are saved in NVS.
  final bool saved;

  /// The saved SSID, or "" when none.
  final String ssid;

  /// The current station IP, or "0.0.0.0" before DHCP completes.
  final String ip;

  /// True when the station is associated and has an address.
  final bool connected;
}

/// Parses a "wifi {...}" status line. Returns null for anything else,
/// including the "unknown command" an older mirror answers to the new
/// command, so a newer app keeps working against it.
BleWifiStatus? parseWifiStatus(String line) {
  if (!line.startsWith('wifi ')) return null;
  Map<String, dynamic> map;
  try {
    map = jsonDecode(line.substring('wifi '.length)) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
  final saved = map['saved'];
  final ssid = map['ssid'];
  final ip = map['ip'];
  final connected = map['connected'];
  if (saved is! bool || ssid is! String || ip is! String || connected is! bool) {
    return null;
  }
  return BleWifiStatus(saved: saved, ssid: ssid, ip: ip, connected: connected);
}

/// How a scanned network authenticated, as far as the mirror can tell.
///
/// A verdict is a hint for the UI, never a lock: the password field stays
/// reachable for everything but [open].
enum WifiSecurity {
  /// No authentication; the mirror joins with no password.
  open,

  /// Authenticated. A password is likely needed, but the verdict can be
  /// wrong, so the field is always editable.
  secured,

  /// Encrypted in a mode this firmware cannot join: enterprise/802.1X,
  /// WPA3-only SAE built without SAE support, or the IDF misreport that
  /// names a PMF-mandating enterprise AP as open. A password can still be
  /// tried.
  unsupported,
}

/// One network from the mirror's scan.
class BleWifiNetwork {
  const BleWifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.security,
  });

  final String ssid;
  final int rssi;
  final WifiSecurity security;
}

/// Parses a "wifi-net {...}" status line, or null for anything else.
BleWifiNetwork? parseWifiNet(String line) {
  if (!line.startsWith('wifi-net ')) return null;
  Map<String, dynamic> map;
  try {
    map = jsonDecode(line.substring('wifi-net '.length)) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
  final ssid = map['ssid'];
  final rssi = map['rssi'];
  if (ssid is! String || rssi is! int) return null;
  final auth = map['auth'];
  final WifiSecurity security;
  if (auth is String) {
    // An unknown verdict means "assume a password is needed": a spurious
    // prompt costs a blank field, while calling an encrypted network open
    // leaves the owner no way in at all.
    if (auth == 'open') {
      security = WifiSecurity.open;
    } else if (auth == 'unsupported') {
      security = WifiSecurity.unsupported;
    } else {
      security = WifiSecurity.secured;
    }
  } else {
    // Older firmware sends only the bool, from the authmode alone.
    final open = map['open'];
    if (open is! bool) return null;
    security = open ? WifiSecurity.open : WifiSecurity.secured;
  }
  return BleWifiNetwork(ssid: ssid, rssi: rssi, security: security);
}

/// The network count from a "wifi-scan done <n>" terminator, or null for any
/// other line.
int? parseWifiScanDone(String line) {
  if (!line.startsWith('wifi-scan done ')) return null;
  return int.tryParse(line.substring('wifi-scan done '.length));
}

/// The async connect outcome after a credential push.
class BleWifiResult {
  const BleWifiResult({required this.connected, required this.detail});

  /// True when the station got an address; [detail] is the IP then.
  final bool connected;

  /// IP on success, the device's human reason on failure.
  final String detail;
}

/// Parses a "wifi connect ok/error" status line, or null for anything else.
BleWifiResult? parseWifiResult(String line) {
  if (line.startsWith('wifi connect ok ')) {
    return BleWifiResult(
        connected: true, detail: line.substring('wifi connect ok '.length));
  }
  if (line.startsWith('wifi connect error ')) {
    return BleWifiResult(
        connected: false, detail: line.substring('wifi connect error '.length));
  }
  return null;
}
