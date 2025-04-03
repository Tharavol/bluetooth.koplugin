# Bluetooth Page Turner Support for Kobo

This plugin allows the user to turn Bluetooth on/off and connect my bluetooth controller (a cheap 'q36' controller from aliexpress) to be connected to my Kobo Sage.

This repo contains a modified version of the plugin and scripts from [onatbas](https://github.com/onatbas/bluetooth.koplugin). You should check the original repo out and carefully read the readme to understand how all of this works.

I highly doubt the code in this fork, as it is, could work out of the box for someone else, but it could offer a starting point to tinker with.

I'm listing here the main differences from the original repo:

- bluetooth on & off script have been modified to work with my Sage model
- since my controller rotates mac address (and I use more than one anyway) I needed the address to not be hardcoded, and the ability to reconnect to a different one at will: the `repair.sh` and `connect.sh` scripts take care of that
- the interface has been reworked to support the new scripts and to improve the user experience
