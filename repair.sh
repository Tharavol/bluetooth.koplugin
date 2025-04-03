#!/bin/bash

bltctl="timeout 5s bluetoothctl"

# shut off the power, make sure its turned off
$bltctl power off
sleep 2
# turn back the power, make sure it's come back online
$bltctl power on
sleep 2

# delete all old devices
$bltctl devices | grep "Q36 for Android" | while read device; do
  bluetooth_address=$(echo "$device" | grep -oE '[0-9A-Fa-f]{2}([-:][0-9A-Fa-f]{2}){5}')
  echo "Removing $bluetooth_address"
  $bltctl remove $bluetooth_address
done

# scan for new device
$bltctl scan on
sleep 2

device=$($bltctl devices | grep "Q36 for Android")
if [ -z "$device" ]; then
    echo "Device not found."
    exit 1
else
  bluetooth_address=$(echo "$device" | grep -oE '[0-9A-Fa-f]{2}([-:][0-9A-Fa-f]{2}){5}')
  $bltctl pair $bluetooth_address
  $bltctl trust $bluetooth_address
  $bltctl connect $bluetooth_address
fi
