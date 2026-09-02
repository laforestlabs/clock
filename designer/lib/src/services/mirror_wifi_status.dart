// Parsing of the BLE WiFi status lines, kept free of Flutter and plugin
// imports so it is unit testable like the rest of the protocol layer.
// The wire format is defined in firmware/main/net/ble.c:
//
//   get wifi      -> wifi {"saved":bool,"ssid":"...","ip":"...","connected":bool}
//   wifi scan     -> wifi-scan start, then one
//                    wifi-net {"ssid":"...","rssi":N,"open":bool} per network,
//                    then wifi-scan done <n> | wifi-scan error <why>
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

/// One network from the mirror's scan.
class BleWifiNetwork {
  const BleWifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.open,
  });

  final String ssid;
  final int rssi;
  final bool open;
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
  final open = map['open'];
  if (ssid is! String || rssi is! int || open is! bool) return null;
  return BleWifiNetwork(ssid: ssid, rssi: rssi, open: open);
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
