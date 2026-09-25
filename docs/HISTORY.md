# History and dead ends

How the plugin got to its current shape: the approaches that didn't work, the
bugs worth remembering, and the reasoning behind fixes whose code no longer
shows it. The current design is in [`HANDOFF.md`](HANDOFF.md); release-level
changes are in [`changelog.md`](../changelog.md).

---

## Dead ends

Don't re-try these.

| Attempt | Result |
|---|---|
| `hciattach ... bcm43xx` (upstream default) | `Initialization timed out` — wrong vendor protocol |
| `setkeycodes` for the scancodes | Wrong tool; legacy AT/PS2 table, can't express `0x70051`-scale HID values |
| udev hwdb rule (`KEYBOARD_KEY_*`) | `udevadm` on this firmware has no `hwdb` subcommand; no `hwdb.d` dirs exist |
| Mutating `ev.type`/`ev.code` in the adjust hook to synthesise `EV_KEY`, then mapping via `settings/event_map.lua` to `BTLeft`/`BTRight` | Never fired. Dispatch to `handleKeyBoardEv` vs `handleMiscEv` appears to be decided before the hook runs, so rewriting `ev.type` afterwards is too late |
| Remapping onto existing keycodes 103/108 (`Up`/`Down`) | Those are `Cursor` group keys with nothing useful bound in reader view |
| Believing `evtest` and KOReader disagree on scancodes | They don't. `evtest` prints `70051`/`70052` in **hex**; `458833`/`458834` are the same values in decimal. The constants are written in hex |
| Debouncing by time — against the last accepted action, or a 0.5 s window per code | No window separates the two remotes. See [press pairing](#from-debounce-to-press-pairing-31) |
| Using the Kobo Remote's empty reports while held to keep a press open | `evtest` shows them, but they never reach KOReader's event hook (`last empty report never` in the log) |
| `hcitool lescan` while `bluetoothd` is running | `Set scan parameters failed: Connection timed out` — fights bluetoothd for the raw HCI socket. Use `bluetoothctl` |
| Killing the child luajit process | Killed BT input while leaving touch working. Two processes is normal on this build |
| Range-based `sed -i '/start/,/end/c\...'` for multi-line edits on the device | Misfired twice; once destroyed ~200 lines of `main.lua` because the closing pattern `^end)$` didn't match the indented `    end)`. **Edit the file locally and transfer it** |
| Adding HOGP (`00001812-…`) to `[Policy] ReconnectUUIDs` to get auto-reconnect | **Structurally impossible.** The policy plugin matches the device and starts its ladder — `disconnect_cb() identified for auto-reconnection`, `reconnect_set_timer() attempt 1/10` — then dies with `Reconnecting services failed: Operation not supported (95)`. It reconnects by calling a profile's `connect` method, and LE profiles like HoG have none. That is why the stock list holds only classic HID and A2DP sink. The plugin dials the remotes itself |
| `sed -i` on the rootfs when `/` is full | Writes a temp file and renames it over the target, so it silently replaced `/etc/bluetooth/main.conf` with a **0-byte file**. The `cp` backup taken first had already failed the same way. Check `df -h /` before editing anything on `/` |
| Leaving a mock `bluetoothctl` earlier in `PATH` after a test | Poisoned three rounds of diagnosis in the same shell: it exits 0 with no output for anything it doesn't implement, which produced a whole wrong theory about BlueZ storage. `command -v bluetoothctl` when a result is surprisingly empty |
| Reading `bluetoothctl info` immediately after `connect` to check the bond | Races encryption; reports `Paired: no` for a bond about to be fine. On the menu path that meant `exec repair.sh`, destroying a working bond to rebuild it. Poll instead (`wait_for_bond`) |
| Trapper's invisible trap widget (`true`, or `false`) for background runs | Any tap dismisses it, and at startup both background runs were cancelled together (#30). Pass an unshown table instead |
| `Input:close(path)` on a device that has gone away | KOReader already closed the fd, and the number may now belong to the other remote (#48). Check `/proc/self/fd/<fd>` first |
| Checking `hci0` before `bluetoothd` starts | `hci0` is routinely not UP until `bluetoothd` powers it, so every start retried (#49) |
| Fixed `sleep`s in `on.sh` and `repair.sh` | Too short on a slow attach (the retry then killed an attach about to succeed), wasted time otherwise. Poll for the state instead |
| Retrying a failed Free3 pair within seconds, or with a power cycle in between | The Free3 ignores pages for ~45 s after being dropped. Retrying sooner changes nothing; power cycles could miss its own page. Retry for long enough instead |
| `l2ping` or `hcitool name` as a test that the Free3 is really there | The Free3 answers neither over a working link, and `l2ping` exits 0 at 100% loss |

---

## The double-page-advance bug

Symptom: one button press advanced two pages.

Red herring: it looked like a timing problem, since the Kobo Remote sends a
second code 135–200 ms after the first (its release, as it turned out), so
widening a debounce window seemed right. It never fully worked.

The tell: `logger.info` output showed pairs of lines with **byte-identical
timestamps and deltas**. That's not two events — it's one event handled twice.

Cause: KOReader instantiates a plugin once per UI context (FileManager and
ReaderUI), so `Bluetooth:init()` runs twice in the same process, and
`registerEventAdjustHook` **chains** hooks rather than replacing them. Two live
hooks, each closing over a different `self` with its own debounce table, both
fired.

Fix: module-level state (shared, because `require` caches the module) and a
module-level flag so the hook is only ever added once.

---

## From debounce to press pairing (#31)

For a long time the Kobo Remote was believed to auto-repeat every 135–200 ms
while held, and a 0.5 s per-code debounce window absorbed the repeats. `evtest`
captures (2026-09-24) showed what was really happening: every press sends its
code exactly twice. The Kobo Remote sends one at press and one at release —
the "repeats" were the release codes of short taps — and the Free3 sends both
at press, 18–40 ms apart.

Replaying the captures, the 0.5 s window turned two pages for each Kobo Remote
press held longer than half a second, and dropped the second page of a Free3
double-tap (~140 ms apart). No window size fixes both. Pairing each press's two
codes, with no time limit short of a 30 s backstop, got every press right.

A first version kept the pair open while the Kobo Remote's empty hold reports
kept coming, with a 0.5 s gap. On the device, a 2–3 s hold turned a page at
press and again at release: those reports never reach the hook.

---

## `on.sh`: from a script to a bring-up (#49)

The first `on.sh` that worked on the Sage:

```sh
#!/bin/sh
cd /

killall rtk_hciattach 2>/dev/null
killall bluetoothd 2>/dev/null
hciconfig hci0 down 2>/dev/null

echo 0 > /sys/devices/platform/bt/rfkill/rfkill0/state
sleep 1
echo 1 > /sys/devices/platform/bt/rfkill/rfkill0/state

/sbin/rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5 > /var/log/rtk_hciattach.log 2>&1 &
sleep 2
hciconfig hci0 up

setsid /libexec/bluetooth/bluetoothd -n > /var/log/bluetoothd.log 2>&1 &
sleep 2

echo "complete"
```

It failed now and then with `hci0` down. Fixing that took four rounds, each
found from the attach log in `crash.log`:

1. **A retry**, once, of the whole sequence. The first version checked `hci0`
   before starting `bluetoothd` — but `bluetoothd` is what powers the
   controller, so every start retried.
2. **Polling instead of fixed sleeps.** The attach sometimes outlasted
   `sleep 2`; the check found no `hci0`, and the retry killed an attach that
   was about to succeed.
3. **Waiting for the old processes to exit.** With Bluetooth already on, the
   first attempt always failed with `Device setup complete` in the log and no
   `hci0`: `killall` only signals, and the old `rtk_hciattach` restored the
   serial line's discipline as it exited, detaching the new one.
4. **Holding the radio off 4 s when it was on.** Restarting a running stack
   then failed at the H5 sync instead (`h5 hdr checksum error`, SYNC timeouts,
   `Retransmission exhausts`). Held off 4–6 s first, it synced at once.

The old HANDOFF's claim that the attach log is empty was wrong in a useful
way: `rtk_hciattach` buffers its output until it exits, so the log is empty
only *while it runs*. `on.sh` stops it before reading the log.

---

## Suspend (#29)

The watcher and the unattended reconnect were built and tested with forced
disconnects over SSH. Across a real suspend, the first sleep showed the gap:
the serial link to the chip died while the Kobo slept — `hci0` DOWN,
`retransmitting` in `dmesg`, every `bluetoothctl` call failing with
`org.bluez.Error.Busy` — and nothing short of a manual toggle recovered it.
KOReader powers Wi-Fi down for suspend for a similar reason, and knows nothing
about Bluetooth on the same chip. The plugin now does the same for Bluetooth,
and treats `controller is not responding` as a cue to restart the stack.

After a night's sleep the Free3 reconnected, but was switched on just after
the attempt made on waking and waited a further minute. Hence the two-minute
window of 10 s attempts after Bluetooth comes up.

---

## RePair and the Free3 (v1.5.0)

RePair was written for the Kobo Remote, and the Free3 broke it in four
separate ways, found one after another on the device:

1. **The pair was cut off.** Every `bluetoothctl` call was capped at 5 s, and
   the Free3 takes longer to pair. `Attempting to pair` was followed by
   neither success nor failure; RePair reported failure and BlueZ finished the
   bond on its own shortly after. The pair now gets 20 s.
2. **The scan ended too soon.** A connected Free3, dropped by RePair's power
   cycle, starts advertising about 14 s later. One 5 s scan missed it. The
   scan now runs in rounds until the remote is found.
3. **The watcher joined in.** With 10 s reconnect attempts after Bluetooth
   came up, an unattended `connect.sh` dialled the Free3 in the middle of
   RePair's scan, and the pair that followed left no bond. The watcher now
   stands aside during a menu Reconnect or RePair.
4. **The Free3 ignores pages for ~45 s after being dropped.** Found in the
   scan, it still failed every pair with `ConnectionAttemptFailed`.
   `hcitool con` showed the Kobo's link stuck connecting for 5 s per attempt,
   then the Free3 paging the Kobo itself (`>` in `hcitool con`) about 45 s in,
   after which a plain connect bonded it. Every second RePair had worked only
   because it started late enough. Retries 2 s apart, and power cycles between
   them, both failed; retrying for 90 s works.

And since a working Free3 never needs a re-pair, RePair now leaves a remote
that is connected, bonded and delivering input alone. Its one gap: a remote
switched off stays "connected" for BlueZ's 20 s link timeout, and neither
`l2ping` nor `hcitool name` gets an answer out of the Free3 to tell sooner.

---

## Smaller fixes worth knowing about

- **Colon call.** `refreshPairing()` had `Device.input.open(path)`. `Input:open`
  is defined with a colon, so the path string became `self` and
  `self.input.is_ffi` threw. Every *Refresh Device Input* crashed.
- **Connect, not re-pair, on Bluetooth On.** `onBluetoothOn()` used to call
  `onDeviceRepair()`, throwing away bonds that were usually fine.
- **The two Kobo Remote input devices (#46).** Taking the first match opened
  the dead one: connected, `Connection successful!`, no page turns. Found with
  `evtest` on each node.
- **`device.conf` comments.** `main.lua` used to take the first
  `BT_DEVICE_NAME="…"` anywhere, comments included. With an old name kept as a
  comment, the scripts paired the Free3 while `main.lua` opened the Kobo Remote.
- **Output timing (#47).** `off.sh` printed nothing and its popup never went
  away; `repair.sh` printed as it went and froze the reader until it finished.
- **Missing `device.conf`.** `. device.conf || true` still exits in busybox
  ash when the file is missing, so the "both remotes" fallback was never
  reached. `lib.sh` checks for the file first.
