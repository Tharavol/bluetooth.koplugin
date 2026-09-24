#!/bin/sh
# Run from /, not from the plugin directory. rtk_hciattach and bluetoothd are
# resident and inherit this directory as their cwd; left on /mnt/onboard, they
# hold that filesystem busy and USB mass storage refuses to start. Nothing below
# uses a relative path.
cd / || exit 1

# Power-cycle the chip and attach it. hci0 regularly ends up attached-but-DOWN,
# at which point "hciconfig hci0 up" fails; only a full rfkill 0->1 cycle and
# a fresh rtk_hciattach recover it, so this does both every time.
bring_up() {
    killall rtk_hciattach 2>/dev/null
    killall bluetoothd 2>/dev/null
    hciconfig hci0 down 2>/dev/null

    echo 0 > /sys/devices/platform/bt/rfkill/rfkill0/state
    sleep 1
    echo 1 > /sys/devices/platform/bt/rfkill/rfkill0/state

    /sbin/rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5 > /var/log/rtk_hciattach.log 2>&1 &
    sleep 2
    hciconfig hci0 up 2>/dev/null
}

hci0_up() {
    hciconfig hci0 2>/dev/null | grep -q "UP RUNNING"
}

# The attach log goes to stderr, which KOReader leaves pointing at crash.log:
# /var/log is a small tmpfs, and by the time anyone reads it the next attempt
# has overwritten it.
log_attach() {
    echo "[bluetooth] $1; rtk_hciattach.log follows" >&2
    sed 's/^/[bluetooth]   /' /var/log/rtk_hciattach.log >&2 2>/dev/null
}

bring_up
# Once is usually enough. When it isn't, try one more full cycle (#49): seen
# failing at startup, where that otherwise means no remote until a manual
# toggle. Whether a second cycle recovers it is not yet observed; the attach
# log in crash.log will say.
if ! hci0_up; then
    log_attach "hci0 did not come up; retrying once"
    bring_up
fi

# No -d: /var/log is a 16 KB tmpfs, debug output wraps it within seconds, and
# the logging costs wakeups on a battery device for a log nobody can read.
# HANDOFF section 8 has the command for a debug daemon logging somewhere with room.
setsid /libexec/bluetooth/bluetoothd -n > /var/log/bluetoothd.log 2>&1 &
sleep 2

# Only report success if the controller actually came up. hci0 regularly ends
# up attached-but-DOWN, and echoing "complete" regardless sends the plugin
# straight into pairing against a controller that isn't there.
if ! hci0_up; then
    log_attach "hci0 did not come up after a retry"
    echo "Error: hci0 did not come up - see crash.log"
    exit 1
fi

echo "complete"
