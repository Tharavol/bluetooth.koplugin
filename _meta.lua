-- What KOReader's plugin manager shows, and what it loads in place of main.lua
-- while the plugin is disabled. Without this file a disabled plugin fails to
-- load and drops out of the list, so it can't be enabled again from the menu
-- (#41). `name` must match the folder name without ".koplugin": the manager
-- records a disabled plugin under `name`, and the loader looks it up under the
-- folder name.
local _ = require("gettext")
return {
    name = "bluetooth",
    fullname = _("Bluetooth"),
    description = _("Brings up Bluetooth on a Kobo Sage and turns pages from a Bluetooth page turner: " ..
                    "the official Kobo Remote or a Hanlinyue Free3."),
}
