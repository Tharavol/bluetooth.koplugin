#!/bin/sh
# Take Bluetooth down: the controller, both daemons, then the radio.
cd / || exit 1

hciconfig hci0 down 2>/dev/null
killall rtk_hciattach 2>/dev/null
killall bluetoothd 2>/dev/null

# killall only signals. Give both a moment to exit before blocking the radio,
# so rtk_hciattach isn't still restoring the serial line when the next on.sh
# attaches (#49). Capped at 3 s: this runs synchronously when the Kobo
# suspends.
n=0
while pidof rtk_hciattach >/dev/null 2>&1 || pidof bluetoothd >/dev/null 2>&1; do
    n=$((n + 1))
    if [ "$n" -gt 3 ]; then
        break
    fi
    sleep 1
done

echo 0 > /sys/devices/platform/bt/rfkill/rfkill0/state
echo "off"
