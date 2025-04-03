#!/bin/bash
cd "$(dirname "$0")"

hciconfig hci0 down
pkill hciattach
pkill bluetoothd
echo "0" >"/sys/devices/platform/bt/rfkill/rfkill0/state"
