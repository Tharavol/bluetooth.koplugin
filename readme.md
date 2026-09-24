# Bluetooth Page Turner Support for the Kobo Sage

A KOReader plugin that brings up Bluetooth on a **Kobo Sage** and connects a
page-turner remote: the **official Kobo Remote** or a **Hanlinyue Free3**.

This is working on my own Sage. Bluetooth comes up by itself when KOReader
starts, the preferred remote is connected in the background, and it turns pages
from there. Both remotes can be paired, and either one works.

## Lineage

This repo is a fork of [CarloDePieri/bluetooth.koplugin](https://github.com/CarloDePieri/bluetooth.koplugin),
itself a fork of [onatbas/bluetooth.koplugin](https://github.com/onatbas/bluetooth.koplugin).
Read the original readme to understand the overall design — this fork only
changes what the Sage needed.

Both parent repos target Kobos with a **Broadcom** Bluetooth chip and a
**classic Bluetooth HID** controller. The Sage has neither, which is what this
fork is about.

Full credits, prior art consulted, and who did what are in
[`CREDITS.md`](CREDITS.md).

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

3. **Remotes by name.** `device.conf` lists the remotes in order of preference
   (`Free3-P` and `Kobo Remote`) rather than CarloDePieri's `Q36`, and
   everything matches those names exactly.

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
| Remote | Hanlinyue Free3 in P mode — classic Bluetooth HID (UUID `00001124-…`) |
| KOReader | v2026.03 |
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

When upgrading, copy the whole folder rather than individual files: the
scripts share `lib.sh`, and `connect.sh` and `repair.sh` fail without it.

Make sure the `.sh` files have LF line endings and are executable.
`.gitattributes` forces LF on checkout so a clone made on Windows stays usable.

Root is required; the scripts write to `/sys` and start daemons.

## Using it

By default there is nothing to do. **Bluetooth turns on by itself** a few
seconds after KOReader starts, and the plugin connects whichever paired remote
answers, trying them in `device.conf` order. It then watches for a remote
dropping out and dials it again in the background, about once a minute. It
never re-pairs on its own.

The first time, pair each remote once with **RePair** (below).

Everything else lives under **Bluetooth** on the settings tab, directly below
**Network**:

- **Toggle Bluetooth** — runs `on.sh`, then connects to the first paired remote
  that answers. It takes several seconds and always tears the stack down first,
  so it drops any existing connection. Wi-Fi has to be on for this entry (#42).
- **Reconnect to Device** — `connect.sh`. Tries each paired remote in order and
  verifies the bond. A remote whose link came up without a bond is handed over
  to a re-pair automatically.
- **RePair & Reconnect to Device (long!)** — a submenu with one entry per
  remote. `repair.sh` removes that remote's bond, rescans, pairs, trusts and
  connects. The remote has to be advertising while it scans: see
  [Remotes](#remotes).
- **Refresh Device Input** — closes and reopens the remotes' input devices. The
  watcher does this by itself; this is the manual override.
- **Invert page-turn buttons** — swaps forward and back, for any remote.
- **Turn on Bluetooth at startup** — on by default. Untick it to bring Bluetooth
  up only from the menu.
- **Third button (Free3): …** — KOReader's own action picker, the one gestures
  use. Whatever is chosen runs when the Free3's third button is pressed.

Messages are kept short. The full `bluetoothctl` output goes to `crash.log`,
with each line tagged `[bluetooth]`.

## Remotes

`device.conf` lists the remotes the plugin reads, in order of preference:

```sh
BT_DEVICE_NAMES="Free3-P|Kobo Remote"
```

Every listed remote that is connected turns pages. While a remote earlier in
the list is missing, the plugin keeps dialling it about once a minute, even if
a later one is connected. Edit the list and restart KOReader to change it.

**Official Kobo Remote.** To pair it, run **RePair → Kobo Remote** and press
one of its buttons while it scans, so it advertises. It forgets its bond
whenever it loses power (see [Known issues](#known-issues)), so it needs
re-pairing after a battery change.

**Hanlinyue Free3.** Set the switch on the side to **P**. Press the side On key
until the light over the **↑↓** icon is lit: *Up and Down Mode*. In that mode
the top key turns back and the middle key turns forward, sending exactly the
codes the Kobo Remote sends. The bottom key runs whatever **Third button** is
set to. Pair it once with **RePair → Free3-P** while its blue light is flashing.
It keeps its bond through power-offs, so after that it only needs switching on.
The plugin picks it up within about a minute. Volume mode, the other one likely
to be selected by accident, sends volume keys, which turn no pages.

**Another remote** may work if it sends the same keyboard Up/Down Arrow codes:
add its exact Bluetooth name to the list. `evtest` on its input device shows
what it sends. The Kobo Remote and the Free3 send `MSC_SCAN` values `70051`
(forward) and `70052` (back).

## Known issues

- **The remote forgets its bond when it loses power.** This is the cause of the
  `Connected: yes` / `Paired: no` state, and it isn't BlueZ's fault. Pull the
  battery and the remote discards its bond; it then re-advertises as unbonded,
  BlueZ connects and offers the stored LTK, the remote rejects a key it no
  longer has, and the bonding attempt fails with HCI status `0x05`
  (authentication failure). BlueZ clears `Paired` but the LE link stays up — so
  the remote looks connected while the HID characteristics, which need
  encryption, stay unreachable and no input device is ever created. Only a
  fresh bond recovers it, which is what *Reconnect to Device* now does on its
  own. Confirmed on the Sage from `bluetoothd` debug logs.
- **The link doesn't come back by itself**, for either remote. When the Kobo
  Remote drops, BlueZ will not re-dial it, so it stays gone until something
  asks for a connection. The Free3 doesn't reconnect by itself either: every
  return seen on the Sage was the plugin dialling it.
  `[Policy] ReconnectUUIDs` is **not** the answer and adding HOGP (`1812`) to
  it does nothing: the policy plugin reconnects by calling a profile's
  `connect` method, LE profiles like HoG don't have one, and the attempt fails
  with `Operation not supported`. That's why the stock list holds only BR/EDR
  profiles. The plugin therefore dials the remotes itself, in the background,
  about once a minute. It deliberately won't re-pair unattended, so a bond the
  remote has *forgotten* still needs a menu tap.
- **Bluetooth occasionally fails to come up.** `hci0` sometimes stays down after
  `on.sh`. With the startup option, that shows only as
  `could not turn on at startup: Error: hci0 did not come up` in `crash.log`,
  and no remote. *Toggle Bluetooth* off and on again recovers it.
- **Bluetooth needs somewhere to write.** The rootfs is ~282 MB and ships
  nearly full; BlueZ stores bonds under `/var/db/bluetooth`, and when the disk
  is full it fails to persist them with no symptom other than pairings that
  never quite stick. Worth a `df -h /` before blaming anything else. Note that
  attaching VS Code's Remote-SSH to a Kobo installs ~30 MB into `/` and will
  fill it. Beware editing config files on a full rootfs: `sed -i` writes a
  temp file and renames it over the original, so it will happily replace
  `/etc/bluetooth/main.conf` with an empty one and report nothing.
- **An open SSH session blocks USB share.** KOReader's SSH server
  (`dropbear`) runs from `/mnt/onboard`, so USB mass storage reports the
  filesystem busy while it is up. Turn SSH off first. Bluetooth itself no longer
  gets in the way.
- **The debounce gap (0.5 s) is a guess.** It works; it isn't tuned. The Kobo
  Remote auto-repeats while a button is held. The Free3 sends one code on press
  and one on release, 30 ms apart, and doesn't repeat while held, so either way
  a press turns one page.
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

## License

MIT — see [`LICENSE`](LICENSE), inherited unchanged from
[onatbas/bluetooth.koplugin](https://github.com/onatbas/bluetooth.koplugin).
Changes in this fork are offered under the same terms; see
[`CREDITS.md`](CREDITS.md). [`DISCLAIMER`](DISCLAIMER) is worth reading before
you point this at a device you care about.

## Community

I found nothing documenting a Realtek-chip Sage driving the official BLE remote
through any of these plugins. If you get there too, the
[MobileRead thread](https://www.mobileread.com/forums/showthread.php?t=362986)
and [CarloDePieri's issues](https://github.com/CarloDePieri/bluetooth.koplugin/issues)
are the places to say so.
