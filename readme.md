# Bluetooth Page Turner Support for the Kobo Sage

A KOReader plugin that brings up Bluetooth on a **Kobo Sage** and pairs the
**official Kobo Remote** so its two buttons turn pages.

This is working on my own Sage: one tap of *Toggle Bluetooth* powers the radio,
pairs, connects, and opens the input device, and the remote turns pages from
there.

## Lineage

This repo is a fork of [CarloDePieri/bluetooth.koplugin](https://github.com/CarloDePieri/bluetooth.koplugin),
itself a fork of [onatbas/bluetooth.koplugin](https://github.com/onatbas/bluetooth.koplugin).
Read the original readme to understand the overall design — this fork only
changes what the Sage needed.

Both parent repos target Kobos with a **Broadcom** Bluetooth chip and a
**classic Bluetooth HID** controller. The Sage has neither, which is what this
fork is about.

## What's different here

Three things, each of which is on its own load-bearing:

1. **Realtek RTL8821CS bring-up.** The Sage's radio is a Realtek part attached
   over UART on `/dev/ttyS1` speaking H5, not a Broadcom one. The upstream
   `hciattach ... bcm43xx` always ends in `Initialization timed out` and `hci0`
   is never created, so every step after it fails. `on.sh` now uses
   `rtk_hciattach`, power-cycles the chip through rfkill first, and starts
   `bluetoothd` under `setsid`.

   `rtk_hciattach` output **must** be redirected to a file. It is a resident
   process, so if it inherits the script's stdout the `io.popen` pipe never
   reaches EOF and KOReader's UI thread hangs forever — which looks exactly like
   a crash.

2. **BLE input translation.** The Kobo Remote is HID-over-GATT (BLE), not
   classic HID, and it emits **only** `EV_MSC`/`MSC_SCAN`. The kernel never
   synthesises a matching `EV_KEY`, so KOReader's normal keymap sees nothing at
   all. The usual fix — a udev hwdb rule — isn't available on this firmware.
   Instead `main.lua` registers an event-adjust hook, recognises the remote's
   scancodes, and dispatches `GotoViewRel` directly.

3. **Device name.** `connect.sh` and `repair.sh` match `Kobo Remote` rather than
   CarloDePieri's `Q36`.

Plus two fixes: `Device.input:open(...)` was being called with a dot, which
crashed on every *Refresh Device Input*; and the event-adjust hook is now
registered once from module scope, because KOReader instantiates the plugin once
per UI context and the hook chains rather than replaces — two live hooks meant
every button press turned two pages.

## Tested on

| | |
|---|---|
| Device | Kobo Sage |
| Bluetooth/WiFi chip | Realtek RTL8821CS, UART on `/dev/ttyS1`, H5 |
| BlueZ | 5.63, `bluetoothd` at `/libexec/bluetooth/bluetoothd` |
| Remote | Official Kobo Remote — BLE HID-over-GATT (UUID `00001812-…`) |
| `uhid` | Built into the kernel (`CONFIG_UHID=y`), no module needed |

Nothing here is likely to work unmodified on another model. Other Realtek Kobos
are a plausible starting point; Broadcom and MTK devices should use one of the
parent repos instead.

## Install

Copy this folder to:

```
/mnt/onboard/.adds/koreader/plugins/bluetooth.koplugin/
```

The folder name must be **exactly** `bluetooth.koplugin`. KOReader only scans
for `*.koplugin`, and a mis-named directory (GitHub's "Download ZIP" gives you
`bluetooth.koplugin-main`) means the plugin silently never loads — no error, and
nothing in `crash.log`.

Make sure the `.sh` files have LF line endings and are executable.
`.gitattributes` forces LF on checkout so a clone made on Windows stays usable.

Root is required; the scripts write to `/sys` and start daemons.

## Using it

Everything lives under **Bluetooth** in the network menu:

- **Toggle Bluetooth** — runs `on.sh`, then automatically runs the full
  re-pair/connect and opens the input device. This is the one you want. It takes
  several seconds and always tears the stack down first, so it drops any
  existing connection.
- **RePair & Reconnect to Device (long!)** — `repair.sh`. Full recovery: remove
  the bond, rescan, pair, trust, connect. Press a button on the remote while
  it's scanning so it advertises.
- **Reconnect to Device** — `connect.sh`. The quick path: reconnect to an
  already-bonded remote without re-pairing. Only works while the bond survives.
- **Refresh Device Input** — reopens `/dev/input/eventN` after the remote
  reconnects on its own.

Wi-Fi has to be on; the plugin refuses to start otherwise.

## Known issues

- **The connection doesn't survive idle.** The remote drops its BLE link and the
  `uhid` device goes with it. BlueZ's `[Policy] ReconnectUUIDs` lists classic
  HID (`1124`) but not HOGP (`1812`); adding it might help, untested.
- **Bond state is fragile.** `Connected: yes` with `Paired: no` happens — the
  remote reconnects without re-bonding, the HID characteristics stay
  inaccessible, and no input device appears. Only a full re-pair recovers it.
- **Nothing recovers automatically.** Every reconnect needs a menu tap. When the
  remote comes back on its own, KOReader is still holding a dead fd and has no
  way to notice.
- **`onBluetoothOff()` doesn't close the input device**, so the handle stays
  open against a destroyed device until the next connect.
- **The debounce gap (0.5 s) is a guess.** It works; it isn't tuned.
- **The scripts run on the UI thread.** A toggle blocks the reader for 15-20 s.
  There's a progress message so it no longer looks frozen, but the work is still
  synchronous — it should move to a subprocess.
- `device.lua.patch` and `uhid/` are inherited from upstream and are **not** part
  of the Sage setup described here. `uhid` is compiled into this kernel, and the
  page-turn path bypasses KOReader's keymap entirely, so the `BT*` key events in
  `main.lua` are unused on the Sage.

## Digging deeper

[`docs/HANDOFF.md`](docs/HANDOFF.md) is the full technical record: how each
hardware fact was established, the exact scripts and why every line is there, a
table of dead ends not worth retrying, the diagnosis of the double-page-advance
bug, and a list of useful debugging commands.

One gotcha worth repeating here: KOReader's SSH server is itself a plugin, so
quitting KOReader kills your own shell session.

## Community

I found nothing documenting a Realtek-chip Sage driving the official BLE remote
through any of these plugins. If you get there too, the
[MobileRead thread](https://www.mobileread.com/forums/showthread.php?t=362986)
and [CarloDePieri's issues](https://github.com/CarloDePieri/bluetooth.koplugin/issues)
are the places to say so.
