#!/usr/bin/env python3
"""Check a mirror's Bluetooth control protocol against the contract it
promises.

Every command in firmware/main/net/ble.c answers on the status
characteristic, and the phone waits for that answer. A command that stops
answering, or a multi-line reply that loses its terminator, is invisible to
the app's own tests: those check Dart against a Dart re-implementation of the
firmware rules, which agrees with itself while both sides drift from the
board. The only place the contract can be checked is the board, so this is
that check. Send `wifi scan` to a build that forgot its `wifi-scan done <n>`
line and this fails; the app instead sat through a 15 s timeout and showed an
empty network list.

Read-only by default: nothing here changes the device. The destructive
commands (`wifi forget`, `reboot`, `factory reset`, `begin`/`commit`/`abort`,
`game start`/`game stop`) are deliberately never sent - a conformance run
must not cost the owner their credentials. `--allow-writes` adds
`set brightness`, which is put back where it was found.

    python3 tools/ble_check.py                          # sole mirror advertising
    python3 tools/ble_check.py --address DC:DA:0C:6B:CA:E6
    python3 tools/ble_check.py --allow-writes

Exit status is 0 only when every checked command answered to contract.
Requires `bleak` (python3 -m pip install bleak) and a working Bluetooth
adapter; the mirror must be advertising.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import sys
import time
from dataclasses import dataclass
from typing import Callable, Optional

SERVICE_UUID = "5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a01"
CMD_UUID = "5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a02"
STATUS_UUID = "5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a04"

# Broadcast to every link: a game notification, or the outcome of a credential
# apply from the portal or the other phone. One can land between a request and
# its reply, so the reader skips these; anything else that arrives where a
# reply belongs is the failure being looked for.
UNSOLICITED = ("game ", "wifi connect ")

SCAN_START = re.compile(r"^wifi-scan start$")
SCAN_ITEM = re.compile(r"^wifi-net \{.*\}$")
SCAN_DONE = re.compile(r"^wifi-scan done (\d+)$")
SCAN_ERROR = re.compile(r"^wifi-scan error (.+)$")


def _re(pattern: str) -> Callable[[str], Optional[str]]:
    rx = re.compile(pattern)

    def judge(line: str) -> Optional[str]:
        if rx.match(line):
            return None
        return "does not match %s: %s" % (pattern, shorten(repr(line)))

    return judge


def _json_reply(prefix: str) -> Callable[[str], Optional[str]]:
    """`<prefix> {json}` with the body actually parsed, so a malformed or
    truncated payload fails here instead of in the app's parser."""

    head = prefix + " "

    def judge(line: str) -> Optional[str]:
        if not line.startswith(head):
            return "expected a '%s' reply, got %s" % (prefix, shorten(repr(line)))
        body = line[len(head):]
        try:
            json.loads(body)
        except json.JSONDecodeError as e:
            # A reply cut off by a fixed buffer is the failure mode worth
            # naming: the prefix and the keys look right, so the break is at
            # the end, and the app's own parser is wrapped in a try/catch that
            # discards it silently.
            if not body.rstrip().endswith("}"):
                return ("reply truncated at %d bytes, before its closing brace: "
                        "%s" % (len(line), shorten(body)))
            return "JSON body does not parse: %s" % e
        return None

    return judge


@dataclass(frozen=True)
class Check:
    command: str
    judge: Callable[[str], Optional[str]]  # None = answered to contract
    what: str


# The read-only half of the command set, each with the single status line the
# firmware answers it with. Kept in step with handle_cmd() in ble.c.
CHECKS = [
    Check("ping", _re(r"^pong \S+ \S+ \S+ \d+ \d+$"),
          "firmware version, IP, layout name, panel size"),
    Check("get config", _json_reply("config"),
          "name, timezone, location, units, routes"),
    Check("get device", _json_reply("device"),
          "identity, display mode, picture availability"),
    Check("get ota", _re(r"^ota \d+ \d+ (idle|active)$"),
          "OTA session state"),
    Check("get memory", _re(r"^memory \d+ \d+ \d+ \d+$"),
          "internal and PSRAM readings"),
    Check("get brightness", _re(r"^brightness \d+ (auto|manual)$"),
          "panel brightness and its source"),
    Check("get wifi", _json_reply("wifi"),
          "saved network and station IP"),
    Check("get latency", _re(r"^latency \d+ \d+$"),
          "event-loop and render latency"),
    Check("game list", _re(r"^games( [A-Za-z0-9_]+(?:,[A-Za-z0-9_]+)*)?$"),
          "the game registry"),
]


def shorten(line: str, width: int = 96) -> str:
    return line if len(line) <= width else line[: width - 1] + "\u2026"


class Runner:
    """One connected link with a queue of status lines arriving on it."""

    def __init__(self, client, timeout: float):
        self._client = client
        self.timeout = timeout
        self._lines: asyncio.Queue = asyncio.Queue()

    def on_notify(self, _characteristic, data: bytearray) -> None:
        self._lines.put_nowait(bytes(data).decode("utf-8", "replace"))

    def drain(self) -> None:
        while not self._lines.empty():
            self._lines.get_nowait()

    async def write(self, command: str) -> None:
        # Drain first: the reply can arrive before write_gatt_char returns
        # (Android delivers the notification first), and a stale line from the
        # previous command must never be read as this one's answer.
        self.drain()
        await self._client.write_gatt_char(CMD_UUID, command.encode("ascii"),
                                           response=True)

    async def next_line(self, deadline: float) -> Optional[str]:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        try:
            return await asyncio.wait_for(self._lines.get(), remaining)
        except asyncio.TimeoutError:
            return None

    async def simple(self, check: Check) -> tuple[bool, str]:
        """Send one command and require its reply to be the next real line."""
        await self.write(check.command)
        deadline = time.monotonic() + self.timeout
        while True:
            line = await self.next_line(deadline)
            if line is None:
                return False, "no reply within %.0fs" % self.timeout
            if line.startswith(UNSOLICITED):
                continue  # someone else's notification, not this answer
            reason = check.judge(line)
            if reason is None:
                return True, line
            return False, "%s (this reply carries %s)" % (reason, check.what)

    async def scan(self) -> tuple[bool, str]:
        """`wifi scan` is a stream: start, one line per network, then the
        terminator. Order matters, and the count in the terminator must match
        the lines that preceded it."""
        await self.write("wifi scan")
        deadline = time.monotonic() + self.timeout

        while True:
            line = await self.next_line(deadline)
            if line is None:
                if deadline - time.monotonic() <= 0:
                    return False, ("no 'wifi-scan start' within %.0fs"
                                   % self.timeout)
                continue
            if line.startswith(UNSOLICITED):
                continue
            if SCAN_START.match(line):
                break
            if SCAN_ERROR.match(line):
                return False, "device refused the scan: %s" % line
            return False, "unexpected reply %s" % shorten(repr(line))

        networks = 0
        while True:
            line = await self.next_line(deadline)
            if line is None:
                return False, ("no 'wifi-scan done' within %.0fs; %d network "
                               "line(s) arrived first - the app waits for the "
                               "terminator" % (self.timeout, networks))
            if SCAN_ERROR.match(line):
                return False, "device failed the scan: %s" % line
            if SCAN_ITEM.match(line):
                networks += 1
                continue
            m = SCAN_DONE.match(line)
            if m:
                reported = int(m.group(1))
                if reported != networks:
                    return False, ("terminator says %d networks but %d "
                                   "'wifi-net' line(s) arrived"
                                   % (reported, networks))
                return True, "wifi-scan done %d" % reported
            if line.startswith(UNSOLICITED):
                continue
            return False, "unexpected reply %s" % shorten(repr(line))


async def find_mirror(address: Optional[str], name: Optional[str],
                      timeout: float):
    from bleak import BleakScanner

    seen: dict[str, object] = {}

    def cb(device, adv) -> None:
        seen[device.address] = (device, adv)

    async with BleakScanner(detection_callback=cb,
                            service_uuids=[SERVICE_UUID]):
        await asyncio.sleep(timeout)

    if not seen:
        sys.exit("no mirror advertising the service was found; is it powered "
                 "and in range?")

    if address:
        hit = seen.get(address)
        if hit is None:
            sys.exit("no mirror at %s; saw %s" % (address, ", ".join(seen)))
        return hit[0]

    matches = [(d, a) for d, a in seen.values()
               if name is None or name.lower() in (a.local_name or "").lower()]
    if len(matches) != 1:
        listing = ", ".join("%s (%s)" % (a.local_name or d.address, d.address)
                            for d, a in seen.values())
        sys.exit("%d mirrors advertising; pass --address or --name: %s"
                 % (len(matches), listing))
    return matches[0][0]


async def brightness_writes(runner: Runner, results: list) -> None:
    """The reversible half of the write surface: set the brightness, then put
    it back to the value and mode it had."""
    await runner.write("get brightness")
    deadline = time.monotonic() + runner.timeout
    before = None
    while before is None:
        line = await runner.next_line(deadline)
        if line is None:
            results.append(("set brightness", False,
                            "could not read the current brightness"))
            return
        m = re.match(r"^brightness (\d+) (auto|manual)$", line)
        if m:
            before = m
        elif not line.startswith(UNSOLICITED):
            results.append(("set brightness", False,
                            "unexpected reply %s" % shorten(repr(line))))
            return

    value, mode = int(before.group(1)), before.group(2)
    probe = 100 if value != 100 else 120

    await runner.write("set brightness %d" % probe)
    deadline = time.monotonic() + runner.timeout
    while True:
        line = await runner.next_line(deadline)
        if line is None:
            results.append(("set brightness %d" % probe, False,
                            "no reply within %.0fs" % runner.timeout))
            break
        if line.startswith(UNSOLICITED):
            continue
        results.append(("set brightness %d" % probe,
                        line == "brightness ok %d" % probe,
                        shorten(line)))
        break

    restore = "set brightness auto" if mode == "auto" else "set brightness %d" % value
    await runner.write(restore)
    deadline = time.monotonic() + runner.timeout
    while True:
        line = await runner.next_line(deadline)
        if line is None:
            results.append((restore + " (restore)", False,
                            "no reply within %.0fs" % runner.timeout))
            break
        if line.startswith(UNSOLICITED):
            continue
        want = "brightness ok auto" if mode == "auto" else "brightness ok %d" % value
        results.append((restore + " (restore)", line == want, shorten(line)))
        break


async def run(args) -> int:
    from bleak import BleakClient

    device = await find_mirror(args.address, args.name, args.discover_timeout)
    print("mirror %s (%s)" % (device.address, device.name or "?"))

    results: list = []

    async with BleakClient(device) as client:
        runner = Runner(client, args.timeout)
        await client.start_notify(STATUS_UUID, runner.on_notify)
        await asyncio.sleep(0.5)  # let the subscription settle

        for check in CHECKS:
            ok, detail = await runner.simple(check)
            results.append((check.command, ok, detail))

        ok, detail = await runner.scan()
        results.append(("wifi scan", ok, detail))

        if args.allow_writes:
            await brightness_writes(runner, results)

        await client.stop_notify(STATUS_UUID)

    version = "?"
    failures = 0
    for command, ok, detail in results:
        if not ok:
            failures += 1
        print("%-4s %-22s %s" % ("ok" if ok else "FAIL", command, detail))
        if command == "ping" and ok:
            version = detail.split()[1]

    print("\n%d command(s), %d failure(s), firmware %s"
          % (len(results), failures, version))
    return 1 if failures else 0


def main(argv) -> int:
    parser = argparse.ArgumentParser(
        description="Check the mirror's Bluetooth control protocol on real "
                    "hardware.")
    parser.add_argument("--address", help="BLE address, when more than one "
                                          "mirror is advertising")
    parser.add_argument("--name", help="substring of the advertised name")
    parser.add_argument("--timeout", type=float, default=15.0,
                        help="seconds to wait for each reply (default 15)")
    parser.add_argument("--discover-timeout", type=float, default=8.0,
                        help="seconds to scan for the mirror (default 8)")
    parser.add_argument("--allow-writes", action="store_true",
                        help="also check `set brightness`, restoring the "
                             "previous value afterwards")
    args = parser.parse_args(argv)

    # `wifi scan` dwells on every channel; it needs longer than a query.
    if args.timeout < 20:
        args.timeout = 20.0
    return asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
