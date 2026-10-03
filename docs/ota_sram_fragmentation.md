# OTA `begin error unavailable` and the 8 KiB internal-SRAM ring

**Status: fixed in 0.4.8 and verified on the attached hardware.** When this was
written the mechanism was an inference from the code and the measured budget;
it is no longer a hypothesis in kind, because the same board has since been
measured with a largest free internal block of 8192 bytes after four hours and
7936 bytes seventeen seconds after a boot — at or below the old ring's size.
The fix takes the allocation out of internal SRAM entirely. What was never
directly read is the pool figure at the instant of the original failure; see
*Verified on hardware* for what replaced it.

## What happened

On 2026-10-01 a mirror reported as **Twirling Elephant** (firmware `0.3.5`,
~9 h uptime) stalled at **0%** on a BLE firmware OTA. The app never entered the
data-transfer phase: `begin firmware` was answered with an error, so no image
bytes were sent. Rebooting the mirror and retrying completed the *same* OTA in
seconds.

Both facts in that paragraph are consistent with the tree: `Twirling Elephant`
is a generated device name (`config.c:252,262` pair a verb with an animal from
the station MAC), and `0.3.5` was a real build — the tree sat at `0.3.5`
between `004131c` and `180f589`, both dated 2026-09-27. That the failing board
was still on it four days later is the app's report, not something the repo can
confirm; it does not matter, because both files below are unchanged since
`004131c` (`git log 004131c..HEAD -- firmware/main/net/ota.c
firmware/main/net/ble.c` is empty; the working tree is now at `0.4.6`,
committed as `0.4.5`).

## The mechanism

`ota_session_begin()` allocates the **8 KiB ring from internal SRAM at the
moment the update begins**, not at boot (`firmware/main/net/ota.c:210-216`):

```c
ota_session_abort_locked();
if (s_ring_storage != NULL) heap_caps_free(s_ring_storage);
s_ring_storage = heap_caps_malloc(OTA_RING_BYTES, MALLOC_CAP_INTERNAL);
if (s_ring_storage == NULL) {
    xSemaphoreGive(s_lock);
    return ESP_ERR_NO_MEM;
}
```

That failure reaches the phone as `begin error unavailable`
(`firmware/main/net/ble.c:458-466`, `unlock();` elided):

```c
const esp_err_t err = ota_session_begin((size_t)len, (size_t)offset);
if (err != ESP_OK) {
    unlock();
    send_status_to(conn, "begin error %s",
        err == ESP_ERR_INVALID_ARG ? (offset > 0 ? "bad offset" : "too large")
                                   : "unavailable");
}
```

The app renders that as *"the mirror could not start an update"*
(`designer/lib/src/services/mirror_ble.dart:768-780`, `_beginReason`), and only
`begin error unavailable` produces that sentence — the text passes through
verbatim (`BlePushException.toString()` is the sentence, and `bleErrorMessage`
forwards it, `mirror_ble.dart:37-56`). So if *that* sentence is what the app
showed, the string is identified; no raw mirror line was captured. What it does
*not* identify is which of the two producers of `unavailable` fired; see
*The other producer of `unavailable`*.

Internal SRAM is the scarce pool, and it is tight by design
(`firmware/README.md`, "Memory and storage"):

| | boot | 30 s uptime |
|---|---|---|
| internal free | 28.6 KB | 28.7 KB |
| **largest contiguous block** | **20 KB** | **18 KB** |

(Those are README's own log lines — `28607 (largest 20480)` and
`28743 (largest 18432)`. Both are printed *after* `ble_commit_init()` and
`panel_init()`, so they already exclude the DMA buffers and the commit stack.
Measured again on 2026-10-01 on the attached board, which runs the picture
display and the display API the 2026-09-19 budget predates: `internal free
20735 (largest 8192)` after four hours, and `internal_largest: 7936` seventeen
seconds after a boot. The block the ring had to fit in is now *below* the ring.)

The panel's 94 KB of DMA buffers and descriptor chains and the WiFi driver's
54 KB of static RX/TX buffers are internal and cannot move to PSRAM. The
remaining 47 KB labelled BT/httpd/mDNS/providers is what is left *after* the two
things that could move — mbedTLS's record buffers and NimBLE's host allocations
— already moved; the BLE payload buffer (`ble.c:247-252`) and the LAN layout
buffer (`api_server.c:186-189`) both try PSRAM first and only fall back to
internal. The 18–20 KB contiguous block is the headroom that absorbs every
transient internal allocation: the TLS handshake's two internal AES staging
buffers of up to 1600 bytes each (`esp_aes_dma_core`, described in the same
README section), and the OTA ring's 8 KB.

Two 8 KB internal allocations matter here, and only one is vulnerable:

1. The BLE commit worker's stack — claimed **at boot** (`main.c:259` calls
   `ble_commit_init()`), before `panel_init()` takes the DMA buffers, so the
   block is still whole. The comment in `ble.c:1350-1365` says exactly why. It
   always succeeds.
2. The OTA ring — allocated **on demand** at `begin firmware`. If the largest
   free block has fallen below 8 KB by then, the allocation fails even though
   *total* free memory is ample.

Checked and ruled out as an explanation: the ring is not leaked. Every session
end frees it — abort (`ota.c:54`), the 120 s resume-grace expiry (`ota.c:152`),
and the next `begin` (`ota.c:211`) — so a stalled session can hold it for at
most `OTA_RESUME_GRACE_MS`. The redundant-looking free at `ota.c:211` is a
no-op after `ota_session_abort_locked()`, not a double free.

This is the same pool, and the same failure class, the README already records
for the TLS handshake: *"When the pool runs dry the handshake fails, and from
the provider's side that is indistinguishable from the network being down."*
The OTA case is a larger allocation and a different symptom, but the root cause
is the same: a request for a contiguous internal block late in the boot.

### The other producer of `unavailable`

`ota_session_begin()` returns exactly two errors that `ble.c` turns into
`unavailable`:

- `ESP_ERR_NO_MEM`, from the ring allocation above — the hypothesis.
- `ESP_ERR_INVALID_STATE`, from either
  - `ota_submit_locked()` → `flash_write_submit()` failing (`ota.c:232-237`),
    which happens when the flash writer's mutex cannot be taken with a **zero**
    timeout (`flash_write.c:70-84`) — i.e. any synchronous flash job in flight,
    such as a `netlog_record` from a weather fetch or a layout write to SPIFFS;
    or
  - `esp_ota_get_next_update_partition()` returning `NULL` (`ota.c:181-182`).
    This is *not* "a stuck OTA partition state", and a reboot would not clear
    it: the function returns `NULL` only when the partition table has no
    alternative OTA app slot. With `ota_0` and `ota_1` both present
    (`firmware/partitions.csv`), it cannot happen on this board.

This matters for the inference. The busy-writer failure is also transient and
also cleared by a reboot — and its window is milliseconds against an OTA-start
round trip, versus a whole-fetch-lifetime allocation — so "a reboot fixed it"
does not by itself discriminate between the two. It is only fair to the
hypothesis to say the ring allocation is *much* more likely, not proven.

## Is it still an issue?

**Yes.** Nothing in the code has changed: the ring is still 8 KB, still internal,
still allocated on demand, and still the only `ESP_ERR_NO_MEM` path into
`begin error unavailable`. Any mirror whose largest internal block falls below
8 KB can hit it. It is latent, not fixed.

### Evidence, and its limits

- **Observed:** stall at 0% with no data writes; a reboot fixes it; the OTA then
  completes in seconds. The app's failure sentence, if that is what was shown,
  identifies `begin error unavailable`.
- **The failure class is real and measured elsewhere:** the README records this
  board at ESP-IDF defaults landing at *"5 KB free with a 1.6 KB largest block"*,
  where *"the first weather fetch after a boot failed its TLS handshake about
  half the time."* A largest block under the allocation size is exactly this
  symptom.
- **The 18–20 KB block is already thin against the eventual demand:** the README
  says *"Roughly 14 KB of new contiguous internal demand is what the current
  margin absorbs"* before those TLS failures return. The OTA ring asks for 8 KB
  of that same margin, and it can be live while a weather fetch's handshake runs.
- **What was not measured, at the time this was written:** nothing sampled the
  largest block after hours of uptime, so "the block drifts below 8 KB after
  hours" was a hypothesis consistent with the observation, not a reading. Since
  then the same board has been read after 4.4 hours (largest 8192) and seconds
  after a boot (largest 7936): the block does not drift, it simply sits at or
  below the ring's size, which is enough for the failure and for a fix that does
  not depend on it.
- **Nothing is logged on the failing branch**, and the netlog cannot represent
  it: `NETLOG_EVT_OTA_BEGIN` is declared (`netlog.h:37`) but never recorded by
  any call site, and there is no OTA-failure code at all — only `OTA_OK` is
  written (`ble.c:550`). So the failure left no persisted trace.
- **The nearest contemporaneous reading that does exist** is the provider
  failure log line: *"failed …, attempt N, retry in Ns (internal RAM free X,
  largest Y; DMA-capable X/Y)"* (`provider.c:174-182`), whose comment says the
  figures are "the ones that matter and the ones nothing else reports". If the
  console around the stall was captured, that line is where the pool state is.
  Otherwise the answer needs the instrumentation in *How it was fixed* #4.

## How it was fixed (0.4.8)

1. **Operationally:** reboot the mirror, then OTA. Unchanged, and still the
   answer for a mirror on an older build.
2. **The ring moved to PSRAM** (`firmware/main/net/ota.c`, `ring_alloc()`):
   `MALLOC_CAP_SPIRAM` first, internal SRAM only as the fallback, and the pool
   the ring landed in is logged when the session begins. The ring is only ever
   touched with the cache enabled — the flash writer copies each chunk into its
   own internal-DRAM stack before `esp_ota_write` (`ota.c:90-101`) — so nothing
   else had to change, including the phone side. This removes the failure mode
   rather than budgeting for it: PSRAM has ~8 MB free on this board.
3. **Not done: claiming the ring at boot.** With the ring in PSRAM there is
   nothing to claim, and reserving 8 KB of the ~14 KB contiguous margin
   permanently would spend over half of it on an allocation that no longer
   needs to be internal. `ble_commit_init()`'s boot-claim pattern stays the
   precedent for allocations that really must live here.
4. **The refusal is observable.** The ring-allocation failure branch logs
   `internal free` / `largest`; a refused begin writes `OTA_FAIL` with the
   cause in its detail byte (`nomem`, `busy`, `no_part`, `other`), and a
   successful begin writes `OTA_BEGIN` — declared since the log existed,
   recorded by nothing until now. `tools/netlog.py` decodes both.
   `esp_ota_get_next_update_partition()` returning NULL got its own code
   (`ESP_ERR_NOT_FOUND`) so "no app slot" can never be logged as a memory
   failure.

   **The `OTA_BEGIN` entry is written *before* the session opens, and that
   ordering is load-bearing.** `ota_session_begin()` submits a flash-writer job
   that holds the writer's mutex for the whole session, and `netlog_record()`
   writes through that same writer with an unbounded wait — so recording the
   entry after the begin blocked the BLE host task on the mutex while the
   writer waited for the data only that task can deliver. The first build did
   exactly that, and every update into it died of starvation with nothing
   written (`stream stalled at 0 of …`), which the hardware check below caught.
   Before the begin the writer is free, so the entry lands and the pair reads
   BEGIN, then OK or FAIL.
5. **The app stops stalling.** `begin error <reason>` is a decision, not a
   dropped link, so `pushFirmwareOverBleWithProgress` no longer spends its
   three attempts and two 90 s reboot waits on it: it fails at once with the
   mirror's sentence. `begin error unavailable` also appends the pool reading
   (via `get memory`, when the mirror is new enough to answer), so the owner
   sees "largest free internal block 7 KB" rather than a bare refusal.
6. **The pool is readable remotely.** BLE `get memory` answers
   `memory <internal_free> <internal_largest> <dma_largest> <psram_free>`, and
   `/api/status` carries `internal_free` / `internal_largest`.

**Where this departs from the plan (item 6's preflight).** The plan proposed
refusing an update when the largest internal block is under ~10 KB "before
starting an upload". With the ring in PSRAM that gate would refuse updates that
now work, and the measured state of the attached board makes it worse than
theoretical: its largest free internal block sat at exactly **8192 bytes** for
hours — permanently, not transiently — so the gate would have refused *every*
update on it, including the one that then completed. The reading is exposed and
used to diagnose a refusal; it is deliberately not a gate.

## Verified on hardware (2026-10-01)

Developer 1, the attached mirror, with the Pixel 2 app:

- **The state that produced the incident, measured.** Before the change the
  mirror had been up 4.4 hours and reported `internal free 20735 (largest
  8192)` on its 30 s console line — the largest free block *exactly* the size of
  the old ring. Its `/api/status` had no pool fields to read. After the fix was
  flashed, a 17-second-old boot read `internal_largest: 7936` — *below* the old
  ring size, which is the incident class caught live.
- **A phone-driven update completed, 0.4.6 → 0.4.7.** The app streamed the
  bundled image; the console shows `ble: begin firmware, 1370448 bytes at offset
  0` and `ota: update started, 1370448 bytes`, the netlog shows `OTA_OK`
  immediately before the new boot, and the mirror came back as `0.4.7` with
  `app marked valid, rollback cancelled` in its log. Note that this attempt did
  *not* fail: with the block at exactly 8192 bytes, an 8192-byte request is on
  the boundary rather than over it, which is why the field failure is
  intermittent and why the fix removes the class instead of tuning the margin.
- **The ring is in PSRAM.** Every session since logs
  `ota: ring: 8192 bytes in PSRAM` at `begin firmware`, followed by
  `update started`.
- **The hardware check earned its keep.** The first build recorded `OTA_BEGIN`
  *after* opening the session, which blocked the BLE host task on the
  flash-writer mutex the new session already held; every update into that build
  starved at zero bytes (`stream stalled at 0 of 1370448 bytes`, `get ota`
  reporting `written 0` indefinitely). Moving the entry before the begin fixed
  it. That failure is invisible in a unit test and would have shipped.
- **A complete update on the fixed build, twice.** With the entry recorded,
  the netlog shows `OTA_BEGIN` … `OTA_OK` pairs each followed by a fresh boot,
  and the mirror comes back on `0.4.8` (`pong 0.4.8 …`) with
  `app marked valid, rollback cancelled`. The 1.37 MB stream and the ring drain
  are visible through the mirror's own `get ota` counter, which had to reach
  the image size for the client's pacing to advance.
- **The pool is readable remotely.** `get memory` answered
  `memory 20831 8192 8192 8256740`, and `/api/status` carries
  `"internal_free":20587,"internal_largest":8192`. On 0.4.6 the same command
  answered `unknown command`, which is the old-firmware case both the app and
  the parser handle.
- **`OTA_BEGIN` is recorded.** The netlog decodes it by name
  (`1790909306 (+599s) OTA_BEGIN`). `OTA_FAIL` could not be produced on this
  board: it needs PSRAM to be exhausted or the flash writer to be busy at the
  instant of `begin`, and neither is reachable on demand. Its wiring — the
  error-to-detail mapping in `ota_fail_detail()` and the decoder in
  `tools/netlog.py` — is covered by the app-side test for a refused begin and
  by inspection.
- **The panel.** The app's device preview is the mirror's own framebuffer read
  back over the LAN; it showed the same clock the panel was driving before,
  between and after each reboot.

## How similar issues are protected against in the future

- **Watch the pool by name, from anywhere.** The boot and 30 s console lines
  are joined by `get memory` over BLE and `internal_free` / `internal_largest`
  in `/api/status`, so the figures no longer require a serial cable. The netlog
  now carries the OTA pair (`OTA_BEGIN`/`OTA_OK`) and the refusal with its
  cause (`OTA_FAIL`), so the next occurrence is a reading rather than a guess.
- **Never write a netlog entry after handing the flash writer a long job.**
  `netlog_record()` blocks on the writer's mutex, and an OTA session holds that
  mutex for its whole life, so an entry written after `begin firmware` waits on
  the very task that is waiting for the phone's data. The entry goes in first.
  A unit test cannot see this; the hardware check did, within minutes.
- **"Claim at boot" for internal allocations.** The commit worker already does
  this, with a comment explaining why (the block must be claimed before
  `panel_init()` takes the DMA buffers). Any future on-demand internal
  allocation of a few KB should follow the same pattern — allocate at boot, or
  explicitly justify why it must be on-demand.
- **Keep the contiguous block named.** The README's "Memory and storage"
  section names it and ties it to the TLS-handshake failure; it now also records
  the 2026-10-01 reading (largest free block 8192 bytes on this board) and the
  OTA ring's move to PSRAM, so the next person who tunes buffers knows what the
  margin is for and what is already out of it.
- **Test after simulated uptime.** An OTA tested only against a freshly-flashed
  board is exactly the case that hides this bug. That is now bring-up step 4 in
  `firmware/README.md`, with the console and the netlog as the evidence.
