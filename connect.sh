#!/bin/bash

set -e

BT_DEVICE_NAME="Kobo Remote"  # fallback if device.conf is missing
# shellcheck source=device.conf
. "$(dirname "$0")/device.conf" 2>/dev/null || true

timeout 5s bluetoothctl power on

# Quote the pattern: unquoted, grep reads "Remote" as a filename and dies.
device=$(timeout 5s bluetoothctl devices | grep "$BT_DEVICE_NAME") || true
if [ -z "$device" ]; then
    echo "Device not found."
    exit 1
fi

bluetooth_address=$(echo "$device" | grep -oE '[0-9A-Fa-f]{2}([-:][0-9A-Fa-f]{2}){5}')
timeout 5s bluetoothctl connect "$bluetooth_address"
