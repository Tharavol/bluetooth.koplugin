#!/bin/sh
# Bluetooth hardware and stack details for the "Bluetooth info" menu entry,
# one "Label: value" line each. Read-only: queries, never changes anything.

cd / || exit 1

# The controller answers only while Bluetooth is on. Its manufacturer is the
# authoritative word on the Bluetooth side; "HCI Version" is the Bluetooth core
# version it implements.
version=$(hciconfig hci0 version 2>/dev/null)
if [ -n "$version" ]; then
    echo "$version" | awk '
        /Manufacturer:/ { m = $0; sub(/.*Manufacturer: */, "", m) }
        /HCI Version:/  { h = $0; sub(/.*HCI Version: */, "", h); sub(/ .*/, "", h) }
        /Bus:/          { b = $0; sub(/.*Bus: */, "", b); sub(/ .*/, "", b) }
        /BD Address:/   { a = $0; sub(/.*BD Address: */, "", a); sub(/ .*/, "", a) }
        END {
            print "Controller: " m
            print "Bluetooth version: " h
            print "Bus: " b
            print "Address: " a
        }'
else
    echo "Controller: unavailable while Bluetooth is off"
fi

# The chip model. The Sage's RTL8821CS is a Wi-Fi/Bluetooth combo, and its
# Wi-Fi driver module is named after it (8821cs). rtk_hciattach does log
# "IC: RTL8821CS", but buffers its output until it exits, so the log is empty
# while Bluetooth is on. The driver name is available then -- but only while
# Wi-Fi is on, since KOReader unloads the module with it.
driver=$(awk '$1 ~ /^(8[0-9][0-9][0-9][a-z]*|rtl[0-9a-z]*)$/ { print $1; exit }' /proc/modules 2>/dev/null)
if [ -n "$driver" ]; then
    chip=$(echo "${driver#rtl}" | tr '[:lower:]' '[:upper:]')
    echo "Chip: RTL$chip (from the $driver Wi-Fi driver)"
else
    echo "Chip: unknown (named by the Wi-Fi driver, which loads with Wi-Fi)"
fi

bluez=$(bluetoothctl --version 2>/dev/null | awk '{ print $2 }')
echo "BlueZ: ${bluez:-unknown}"
