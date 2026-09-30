#!/usr/bin/env python3
"""Journal every write to the font art, so a lost edit can be explained and undone.

The art in fonts/ is hand-edited in Font Designer, repaired by fontreview,
redrawn from the vector face by fontraster, and compiled by fontgen -- four
things that write the same files, two of them languages apart. Nothing recorded
which of them wrote what. So when a glyph came back as a solid block, the only
evidence was a modification time: no writer, no reason, and no copy of what the
file held a second earlier, which is why an overwritten edit could not be
recovered.

Every write now goes through record(). It notes the file, the tool, the process
that made the write, and the glyph rows before and after, and it keeps the
previous bytes in a content-addressed store. The journal lives beside the other
tool output, in out/font-journal/ (out/ is gitignored, so this never shows up in
a diff):

    out/font-journal/writes.jsonl      one JSON object per write, oldest first
    out/font-journal/blobs/<digest>    a file's bytes as they were before

The digest is FNV-1a 64, the same one the golden images use: it names content,
it does not protect it.

Reporting a write must never fail a write. A journal that cannot be updated
says so on stderr and returns; the save it was describing still happens.

Usage:
    python3 tools/fontjournal.py log [--file PATH] [--tail N] [--json]
    python3 tools/fontjournal.py restore (--entry N | --digest D) [--file PATH]
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import socket
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JOURNAL = Path("out") / "font-journal"
LOG_NAME = "writes.jsonl"
BLOB_DIR = "blobs"

# A rewrite that touches more glyphs than this is a regeneration rather than an
# edit; the blob holds it, and a wall of rows in the log helps nobody.
GLYPH_DETAIL_MAX = 24


def digest(text: str) -> str:
    """FNV-1a 64 of the text, as hex. Same digest the golden images use."""
    return digest_bytes(text.encode("utf-8"))


def digest_bytes(data: bytes) -> str:
    """FNV-1a 64 of `data`, as hex: it names content, it does not protect it."""
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


def rows_by_codepoint(text: str) -> dict[int, list[str]]:
    """Every glyph's rows, as the source spells them. Lenient on purpose: this
    reads art that may be half-written or mid-edit, and must not raise."""
    out: dict[int, list[str]] = {}
    cp: int | None = None
    rows: list[str] = []

    def close() -> None:
        nonlocal cp, rows
        if cp is not None:
            out[cp] = rows
        cp, rows = None, []

    for line in text.splitlines():
        s = line.strip()
        if s.startswith("|"):
            if cp is not None:
                rows.append(s.strip("|"))
        elif not s or s.startswith("#"):
            close()
        elif s.startswith("@"):
            continue
        else:
            close()
            parts = s.split(None, 1)
            try:
                codepoint = int(parts[0], 0)
            except ValueError:
                continue
            if len(parts) == 2:
                out[codepoint] = parts[1].split("/")
            else:
                cp, rows = codepoint, []
    close()
    return out


def glyph_diff(before: str, after: str) -> list[dict]:
    """The glyphs whose rows differ, with what they held on both sides."""
    b, a = rows_by_codepoint(before), rows_by_codepoint(after)
    changed = []
    for cp in sorted(set(b) | set(a)):
        if b.get(cp) != a.get(cp):
            changed.append({"cp": cp, "before": b.get(cp), "after": a.get(cp)})
    return changed


def who() -> dict:
    """The process making the write, and the one that asked for it.

    The parent matters: fontgen run by Font Designer is the app's write, not
    fontgen's, and that is the question a log like this is asked.
    """
    info: dict[str, object] = {
        "pid": os.getpid(),
        "ppid": os.getppid(),
        "cwd": os.getcwd(),
        "argv": sys.argv,
        "user": getpass.getuser(),
        "host": socket.gethostname(),
    }
    try:
        # NUL-separated argv, exactly as /proc spells it.
        info["parent"] = (Path(f"/proc/{os.getppid()}/cmdline")
                          .read_bytes().replace(b"\0", b" ").decode().strip())
    except OSError:
        pass
    return info


def journal_dir(root: Path | None = None) -> Path:
    return (root or ROOT) / JOURNAL


def relpath(path, root: Path | None = None) -> str:
    """How the log spells a path: repository-relative where it can be.

    fontreview is run with both absolute and relative --dir values, and a
    path outside the checkout has no relative form; neither may raise here,
    because the caller is in the middle of a save.
    """
    p = Path(path)
    try:
        return str(p.resolve().relative_to(Path(root or ROOT).resolve()))
    except (ValueError, OSError):
        return str(p)


def entries(root: Path | None = None):
    """Every recorded write, oldest first."""
    log = journal_dir(root) / LOG_NAME
    if not log.exists():
        return
    for line in log.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue


def record(file: str, before: str, after: str, tool: str, reason: str,
           root: Path | None = None, detail: bool = True) -> bool:
    """Note one write to `file`, keeping the bytes it had before.

    `file` is repository-relative, so the log reads the same whichever
    directory the writer was started from. Returns whether an entry was
    written; never raises.
    """
    if before == after:
        return False
    try:
        d = journal_dir(root)
        (d / BLOB_DIR).mkdir(parents=True, exist_ok=True)
        before_digest, after_digest = digest(before), digest(after)
        blob = d / BLOB_DIR / before_digest
        if not blob.exists():
            blob.write_text(before)
        entry: dict[str, object] = {
            "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
            "file": file,
            "tool": tool,
            "reason": reason,
            "before": before_digest,
            "after": after_digest,
            "bytes": [len(before), len(after)],
        }
        entry.update(who())
        if detail:
            changed = glyph_diff(before, after)
            entry["glyphs"] = (changed if len(changed) <= GLYPH_DETAIL_MAX
                               else {"changed": len(changed)})
        with (d / LOG_NAME).open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")
        return True
    except Exception as exc:  # noqa: BLE001 - a log must not break a save
        print(f"fontjournal: could not record {file}: {exc}", file=sys.stderr)
        return False


def record_run(tool: str, reason: str, root: Path | None = None,
               **detail: object) -> bool:
    """Note a write that is not one file's bytes -- a table rebuild, say.

    The entry carries whatever the caller measured; fontgen records the
    sources' digest, which is what ties a rebuilt table to the art it came
    from.
    """
    try:
        d = journal_dir(root)
        d.mkdir(parents=True, exist_ok=True)
        entry: dict[str, object] = {
            "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
            "tool": tool,
            "reason": reason,
        }
        entry.update(detail)
        entry.update(who())
        with (d / LOG_NAME).open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")
        return True
    except Exception as exc:  # noqa: BLE001
        print(f"fontjournal: could not record {tool} run: {exc}", file=sys.stderr)
        return False


# ------------------------------------------------------------------- reading


def _describe(entry: dict) -> str:
    out = [f"{entry.get('ts', '?')}  {entry.get('tool', '?'):<12} "
           f"{entry.get('reason', ''):<10} {entry.get('file', '?')}"]
    who = entry.get("parent") or entry.get("argv")
    if isinstance(who, list):
        who = " ".join(str(a) for a in who)
    if who:
        out.append(f"    by pid {entry.get('pid', '?')} ({who})")
    if "bytes" in entry:
        before, after = entry["bytes"]
        out.append(f"    bytes {before} -> {after}  "
                   f"digest {entry.get('before')} -> {entry.get('after')}")
    detail = {k: v for k, v in entry.items()
              if k not in {"ts", "file", "tool", "reason", "before", "after",
                           "bytes", "glyphs", "pid", "ppid", "cwd", "argv",
                           "user", "host", "parent"}}
    if detail:
        out.append("    " + "  ".join(f"{k}={v}" for k, v in detail.items()))
    glyphs = entry.get("glyphs")
    if isinstance(glyphs, dict):
        out.append(f"    {glyphs.get('changed', '?')} glyphs rewritten")
    elif isinstance(glyphs, list):
        names = ", ".join(f"{g['cp']} {chr(g['cp']) if 32 < g['cp'] < 127 else ''}".strip()
                          for g in glyphs)
        out.append(f"    glyphs: {names}")
        for g in glyphs:
            for label, rows in (("before", g.get("before")), ("after", g.get("after"))):
                if rows:
                    out.append(f"      {label:<6} {' / '.join(rows)}")
    return "\n".join(out)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("log", help="show what wrote what")
    p.add_argument("--file", help="only writes to this repository-relative file")
    p.add_argument("--tail", type=int, default=0, help="only the last N entries")
    p.add_argument("--json", action="store_true", help="raw entries")

    p = sub.add_parser("restore", help="write a recorded version back")
    p.add_argument("--entry", type=int, help="entry number as `log` numbers them")
    p.add_argument("--digest", help="the digest to restore")
    p.add_argument("--file", help="destination (with --digest)")
    p.add_argument("--dry-run", action="store_true", help="say it, do not write")

    args = ap.parse_args(argv)

    if args.cmd == "log":
        found = [e for e in entries()
                 if not args.file or e.get("file") == args.file]
        if args.tail:
            found = found[-args.tail:]
        for i, entry in enumerate(found):
            if args.json:
                print(json.dumps(entry))
            else:
                print(f"[{i}] " + _describe(entry))
        if not found:
            print(f"fontjournal: nothing recorded yet in {journal_dir()}/{LOG_NAME}")
        return 0

    # restore
    if args.entry is not None:
        found = list(entries())
        if args.entry < 0 or args.entry >= len(found):
            print(f"fontjournal: no entry {args.entry}", file=sys.stderr)
            return 1
        entry = found[args.entry]
        target, want = entry.get("file"), entry.get("before")
    else:
        if not args.digest or not args.file:
            print("fontjournal: restore needs --entry, or --digest with --file",
                  file=sys.stderr)
            return 1
        target, want = args.file, args.digest

    blob = journal_dir() / BLOB_DIR / str(want)
    if not blob.exists():
        print(f"fontjournal: no blob for {want}", file=sys.stderr)
        return 1
    text = blob.read_text()
    dest = ROOT / str(target)
    print(f"restore {target}: {blob} -> {dest} "
          f"({len(text)} bytes, digest {want})")
    if args.dry_run:
        return 0
    before = dest.read_text() if dest.exists() else ""
    dest.write_text(text)
    record(str(target), before, text, "fontjournal", "restore")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
