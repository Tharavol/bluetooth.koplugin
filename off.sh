#!/bin/sh
cd "$(dirname "$0")"

hciconfig hci0 down
killall rtk_hciattach
killall bluetoothd
echo 0 > /sys/devices/platform/bt/rfkill/rfkill0/state
