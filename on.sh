#!/bin/bash
cd "$(dirname "$0")"

# Turn the bluetooth on (on Kobo Sage)
echo "1" >"/sys/devices/platform/bt/rfkill/rfkill0/state"
/sbin/hciattach /dev/ttyS1 bcm43xx 1500000 flow -t 20 -b bcm43xx_init
dbus-send --system --dest=org.bluez --print-reply  /  org.freedesktop.DBus.ObjectManager.GetManagedObjects
hciconfig hci0 up
