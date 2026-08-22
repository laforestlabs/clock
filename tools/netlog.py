#!/usr/bin/env python3
"""Decode the mirror's nonvolatile network/error log (netlog.bin).

Usage:
    tools/netlog.py                          # fetch http://smart-mirror.local/api/log
    tools/netlog.py http://<host>/api/log    # fetch from a named host
    tools/netlog.py netlog.bin               # decode a local file

The firmware keeps a fixed-size ring of 8-byte entries plus a 16-byte header.
Entries carry uptime_s; absolute time is boot_epoch + uptime_s once the clock
has synced (boot_epoch becomes non-zero).
"""
import struct
import sys
import urllib.request

HEADER = struct.Struct("<4sBBHII")   # magic, version, reserved, head, count, boot_epoch
ENTRY = struct.Struct("<IBbBB")      # uptime_s, event, rssi, detail, reserved

MAGIC = b"NLOG"

EVENTS = {
    0: "BOOT",
    1: "WIFI_CONNECTING",
    2: "WIFI_CONNECTED",
    3: "WIFI_GOT_IP",
    4: "WIFI_DISCONNECTED",
    5: "PORTAL_OPENED",
    6: "PORTAL_CLOSED",
    7: "WEATHER_FETCH_OK",
    8: "WEATHER_FETCH_FAIL",
    9: "WEATHER_STALE",
    10: "CLOCK_SYNCED",
    11: "OTA_BEGIN",
    12: "OTA_OK",
}

ERR_CLASS = {
    1: "connect",
    2: "http",
    3: "parse",
    4: "nomem",
}

RESET_REASON = {
    0: "unknown", 1: "poweron", 2: "ext", 3: "sw", 4: "panic",
    5: "int_wdt", 6: "task_wdt", 7: "wdt", 8: "deepsleep",
    9: "brownout", 10: "sdio",
}

WIFI_REASON = {
    1: "unspecified", 2: "auth_expire", 3: "auth_leave", 4: "assoc_leave",
    5: "assoc_toomany", 6: "not_authed", 7: "not_assoced", 8: "assoc_leave",
    15: "4way_handshake_timeout", 200: "beacon_timeout", 201: "no_ap_found",
    202: "auth_fail", 203: "assoc_fail", 204: "handshake_timeout",
    205: "auth_timeout", 210: "no_compatible_security",
}


def read_bytes(src):
    if src.startswith("http://") or src.startswith("https://"):
        with urllib.request.urlopen(src, timeout=10) as r:
            return r.read()
    with open(src, "rb") as f:
        return f.read()


def fmt_ts(uptime, boot_epoch):
    if boot_epoch:
        return f"{boot_epoch + uptime} (+{uptime}s)"
    return f"t+{uptime}s"


def detail_str(evt, detail, rssi):
    if evt == "BOOT":
        return RESET_REASON.get(detail, str(detail))
    if evt == "WIFI_DISCONNECTED":
        return f"reason {detail} ({WIFI_REASON.get(detail, '?')})"
    if evt == "WEATHER_FETCH_FAIL":
        return ERR_CLASS.get(detail, str(detail))
    if evt == "WIFI_CONNECTING":
        return f"attempt {detail}"
    if evt == "WIFI_CONNECTED":
        return f"channel {detail}"
    if detail:
        return str(detail)
    return ""


def main(argv):
    src = argv[1] if len(argv) > 1 else "http://smart-mirror.local/api/log"
    data = read_bytes(src)

    if len(data) < HEADER.size:
        sys.exit(f"short file: {len(data)} bytes")

    magic, version, _reserved, head, count, boot_epoch = HEADER.unpack_from(data)
    if magic != MAGIC:
        sys.exit(f"not a netlog file (magic {magic!r})")

    slots = (len(data) - HEADER.size) // ENTRY.size
    print(f"version {version}, {count} events, {slots} slots, "
          f"head {head}, boot_epoch {boot_epoch}")

    total = min(count, slots)
    oldest = head if count >= slots else 0
    for i in range(total):
        slot = (oldest + i) % slots
        off = HEADER.size + slot * ENTRY.size
        uptime, evt, rssi, detail, _ = ENTRY.unpack_from(data, off)
        name = EVENTS.get(evt, f"?{evt}")
        d = detail_str(name, detail, rssi)
        suffix = f"  rssi={rssi}dBm" if rssi else ""
        suffix += f"  {d}" if d else ""
        print(f"{fmt_ts(uptime, boot_epoch):>24}  {name:<20}{suffix}")


if __name__ == "__main__":
    main(sys.argv)
