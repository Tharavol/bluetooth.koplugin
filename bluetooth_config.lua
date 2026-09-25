--[[--
Where the plugin lives, which remotes it looks for, and the names of its
settings. Shared by every other module; loaded once per process, since
require() caches it.

@module koplugin.Bluetooth.config
--]]--

local Config = {}

-- The plugin's own directory, with a trailing slash, for device.conf and the
-- scripts. Taken from where this file was loaded, so an install anywhere
-- works: under KOReader's own plugins/ or the data directory's, on an SD card,
-- or with KOReader itself somewhere other than /mnt/onboard/.adds (#36). It
-- used to be hardcoded, and anywhere else every script failed with "could not
-- run" and device.conf went unread, with nothing saying why.
--
-- KOReader's plugin loader dofile()s main.lua by a path relative to its own
-- directory ("plugins/bluetooth.koplugin/main.lua"), or an absolute one for an
-- extra plugin path, and require()s this file from the same directory. A
-- relative path is made absolute here, so the scripts don't depend on the
-- current directory. The loader's own `path` field would do too, but it is set
-- only after main.lua has run, and device.conf is read while it runs.
local function pluginDir()
    local source = debug.getinfo(1, "S").source
    local dir = source:match("^@(.*/)[^/]*$") or "./"
    if dir:sub(1, 1) ~= "/" then
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        local cwd = ok and lfs.currentdir()
        if cwd then
            dir = cwd .. "/" .. dir:gsub("^%./", "")
        end
    end
    return dir
end
Config.PLUGIN_DIR = pluginDir()

-- Read from device.conf so the names live in one place; the shell scripts
-- source the same file. Falls back to both known remotes if it's missing.
--
-- Parsed the way sh reads it, so the two can't disagree: commented-out lines
-- are skipped and the last assignment wins. Matching the first
-- BT_DEVICE_NAME="..." anywhere in the file picked up a commented-out old
-- name, so main.lua watched for one remote while the scripts paired another.
--
-- BT_DEVICE_NAMES is the list, in order of preference, separated by "|". An
-- older device.conf with a single BT_DEVICE_NAME still works, as in lib.sh.
local function readDeviceNames()
    local list, single
    local f = io.open(Config.PLUGIN_DIR .. "device.conf", "r")
    if f then
        for line in f:lines() do
            local key, value = line:match('^%s*(BT_DEVICE_NAMES?)="([^"]+)"')
            if not key then
                key, value = line:match("^%s*(BT_DEVICE_NAMES?)='([^']+)'")
            end
            if key == "BT_DEVICE_NAMES" then
                list = value
            elseif key == "BT_DEVICE_NAME" then
                single = value
            end
        end
        f:close()
    end
    local names = {}
    for name in (list or single or "Free3-P|Kobo Remote"):gmatch("[^|]+") do
        table.insert(names, name)
    end
    return names
end

-- In order of preference, and as a set for matching input devices.
Config.DEVICE_NAMES = readDeviceNames()
Config.DEVICE_NAME_SET = {}
for _i, name in ipairs(Config.DEVICE_NAMES) do
    Config.DEVICE_NAME_SET[name] = true
end

-- Global KOReader setting behind "Invert page-turn buttons". Read on every
-- press rather than cached, so the menu toggle takes effect immediately.
Config.INVERT_SETTING = "bluetooth_invert_page_turn"

-- Global KOReader setting holding the third button's Dispatcher actions, in
-- the shape Dispatcher:addSubMenu edits: a table of action lists keyed by
-- button. It lives inside G_reader_settings, so edits persist with it.
Config.BUTTONS_SETTING = "bluetooth_button_actions"
Config.THIRD_KEY = "third"

-- Global KOReader setting behind "Turn on Bluetooth at startup". Unset means
-- on, so a fresh install brings Bluetooth up without a menu tap.
Config.AUTOSTART_SETTING = "bluetooth_autostart"

return Config
