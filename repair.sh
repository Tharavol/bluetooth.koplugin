#!/bin/sh

BT_DIR=$(dirname "$0")
# shellcheck source=lib.sh
. "$BT_DIR/lib.sh"

# shut off the power, make sure its turned off
bltctl power off
sleep 2
# turn back the power, make sure it's come back online
bltctl power on
sleep 2

# Delete every old entry for the remote. A for loop rather than `| while read`,
# which would run the body in a subshell and lose anything it set.
for bluetooth_address in $(device_macs); do
  echo "Removing $bluetooth_address"
  bltctl remove "$bluetooth_address"
done

# scan for new device
bltctl scan on
sleep 2

bluetooth_address=$(device_macs | head -n 1)
if [ -z "$bluetooth_address" ]; then
    echo "Device not found."
    exit 1
fi
bltctl pair "$bluetooth_address"
bltctl trust "$bluetooth_address"
bltctl connect "$bluetooth_address"
