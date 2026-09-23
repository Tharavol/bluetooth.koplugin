#!/bin/sh
cd "$(dirname "$0")" || exit 1

killall rtk_hciattach 2>/dev/null
killall bluetoothd 2>/dev/null
hciconfig hci0 down 2>/dev/null

echo 0 > /sys/devices/platform/bt/rfkill/rfkill0/state
sleep 1
echo 1 > /sys/devices/platform/bt/rfkill/rfkill0/state

/sbin/rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5 > /var/log/rtk_hciattach.log 2>&1 &
sleep 2
hciconfig hci0 up

# No -d: /var/log is a 16 KB tmpfs, debug output wraps it within seconds, and
# the logging costs wakeups on a battery device for a log nobody can read.
# HANDOFF section 8 has the command for a debug daemon logging somewhere with room.
setsid /libexec/bluetooth/bluetoothd -n > /var/log/bluetoothd.log 2>&1 &
sleep 2

# Only report success if the controller actually came up. hci0 regularly ends
# up attached-but-DOWN, and echoing "complete" regardless sends the plugin
# straight into pairing against a controller that isn't there.
if ! hciconfig hci0 2>/dev/null | grep -q "UP RUNNING"; then
    echo "Error: hci0 did not come up - see /var/log/rtk_hciattach.log"
    exit 1
fi

echo "complete"
