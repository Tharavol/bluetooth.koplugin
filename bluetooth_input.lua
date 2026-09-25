--[[--
The remotes' input devices: finding them, and opening and closing them in
KOReader's input backend.

@module koplugin.Bluetooth.input
--]]--

local Device = require("device")
local logger = require("logger")
local ffi = require("ffi")
local Buttons = require("bluetooth_buttons")
local Config = require("bluetooth_config")
local Stack = require("bluetooth_stack")

-- Not declared by KOReader's own ffi headers. pcall both steps: a conflicting
-- redeclaration is an error, and so is a libc without the symbol. Without it,
-- closePath falls back to closing unconditionally.
pcall(ffi.cdef, "ssize_t readlink(const char *path, char *buf, size_t bufsiz);")
local have_readlink = pcall(function() return ffi.C.readlink end)

local Input = {}

-- Seconds to wait for the uhid node after the link comes up.
local INPUT_WAIT = 5

-- The paths we actually have open. Event numbers move across reconnects, so
-- closing whatever /proc lists now could close something we never opened.
-- Per process, like everything in a require()d module.
local open_paths = {}

function Input.openPaths()
    return open_paths
end

-- Locate every /dev/input/eventN carrying a listed remote's name. The numbers
-- are not stable across reconnects, so they have to be resolved every time
-- rather than assumed. Blocks look like:
--   N: Name="Kobo Remote"
--   H: Handlers=sysrq leds event3
--
-- Every match, not the first. BlueZ can leave more than one uhid device for the
-- same remote: the Kobo Remote has shown up on the Sage as two identically
-- named devices, only one of which delivered any events -- and the first match
-- was the dead one, so the remote was connected but turned no pages. A device
-- that never sends anything costs nothing to hold open, so holding them all is
-- the one choice that can't pick wrong.
--
-- Also returns the set of remote names present, for the watcher's preference
-- check.
function Input.find()
    local paths, present = {}, {}
    local f = io.open("/proc/bus/input/devices", "r")
    if not f then
        return paths, present
    end
    local current = nil
    for line in f:lines() do
        local name = line:match('^N: Name="(.*)"%s*$')
        if name then
            -- Exact, like the scripts: a substring match would also take any
            -- other device whose name merely contains the remote's.
            current = Config.DEVICE_NAME_SET[name] and name or nil
        elseif current then
            local ev = line:match("^H: Handlers=.*(event%d+)")
            if ev then
                table.insert(paths, "/dev/input/" .. ev)
                present[current] = true
                current = nil
            end
        end
    end
    f:close()
    return paths, present
end

-- The remotes listed ahead of the best one present, in order. Empty when the
-- first choice is connected. With nothing present, that is every remote.
function Input.preferredMissing(present)
    local missing = {}
    for _i, name in ipairs(Config.DEVICE_NAMES) do
        if present[name] then
            break
        end
        table.insert(missing, name)
    end
    return missing
end

-- Poll until every listed device has a node we can actually open.
--
-- /proc/bus/input/devices lists the kernel's input device, but the /dev node
-- is created separately and not at the same instant -- and the entry can be
-- listed while the node is absent entirely. Checking only /proc is what
-- produced "Error opening input device </dev/input/event3>: No such file or
-- directory" on a reconnect.
--
-- Returns the openable paths and the listed ones, so the caller can tell
-- "remote isn't there" (nothing listed) from "node never appeared" (listed,
-- none openable).
--
-- Waits without blocking the reader: between polls it yields to UIManager, the
-- way Trapper:dismissablePopen does, so pages still turn and taps still land.
-- os.execute("sleep 1") used to stall the whole process for up to five seconds
-- right after a successful connect (#33).
function Input.waitFor()
    local ready, listed = {}, {}
    for i = 0, INPUT_WAIT do
        if i > 0 then
            Stack.pause(1)
        end
        listed, ready = Input.find(), {}
        for _i, path in ipairs(listed) do
            local f = io.open(path, "r")
            if f then
                f:close()
                table.insert(ready, path)
            end
        end
        if #listed > 0 and #ready == #listed then
            break
        end
    end
    return ready, listed
end

-- What an fd of this process currently refers to, or nil if it is not open.
local function fdTarget(fd)
    local buf = ffi.new("char[256]")
    local ok, n = pcall(function()
        return tonumber(ffi.C.readlink("/proc/self/fd/" .. tostring(fd), buf, 255))
    end)
    if not ok or not n or n < 0 then
        return nil
    end
    return ffi.string(buf, n)
end

-- Drop one handle we hold.
--
-- Only close it if KOReader's fd for this path still refers to this path.
-- When a device goes away, KOReader's input backend closes its fd by itself
-- ("[ko-input] Closed input device ... (matched by idx)") but leaves the
-- path -> fd entry in Input.opened_devices. The fd number is then free for
-- reuse, and Input:close(path) closes whatever holds that number now -- seen
-- on the Sage closing the live remote's fd while tidying up after the other
-- one, which left the reader connected and turning no pages until "Refresh
-- Device Input" (#48). In that case just forget the entry: the fd is already
-- closed, and clearing it lets the next Input:open of this path through
-- instead of being skipped as a duplicate.
--
-- Not fatal if the close fails, but it means the handle leaked, so log it
-- rather than swallowing it -- it shows up in crash.log if the call is wrong.
local function closePath(path)
    Buttons.reset()
    local opened = Device.input.opened_devices
    local fd = opened and opened[path]
    if fd and have_readlink and fdTarget(fd) ~= path then
        logger.info("Bluetooth: " .. path .. " was already closed by KOReader; forgetting it")
        opened[path] = nil
        return
    end
    local closed, close_err = pcall(function() Device.input:close(path) end)
    if not closed then
        logger.warn("Bluetooth: could not close " .. path .. ": " .. tostring(close_err))
    end
end

-- Drop every handle we hold. Safe to call when nothing is open.
function Input.closeAll()
    for _i, path in ipairs(open_paths) do
        closePath(path)
    end
    open_paths = {}
end

-- Open one more path alongside whatever we already hold. Returns false plus
-- the error rather than reporting it, so the caller decides whether it deserves
-- a popup: the menu paths want one, the watcher has to stay silent.
function Input.open(path)
    Buttons.reset()
    local ok, err = pcall(function()
        Device.input:open(path)
    end)
    if not ok then
        return false, err
    end
    table.insert(open_paths, path)
    return true
end

-- Open exactly these paths, dropping whatever we currently hold first. True
-- if at least one opened; otherwise false plus the last error.
--
-- The close has to happen even when the paths are unchanged: a disconnect
-- destroys the uhid device and the reconnect can recreate it on the same event
-- number, so the fd we hold refers to a device that no longer exists. Same
-- path, different device, no events.
function Input.reopen(paths)
    Input.closeAll()
    local last_err
    for _i, path in ipairs(paths) do
        local ok, err = Input.open(path)
        if not ok then
            last_err = err
        end
    end
    if #open_paths == 0 then
        return false, last_err
    end
    return true
end

-- Bring what we hold in line with what is listed: close what has gone, open
-- what is new, and leave the rest alone, so a live remote isn't dropped for a
-- moment whenever one of its siblings changes. For the watcher, so it logs
-- rather than reports.
function Input.reconcile(paths)
    local listed = {}
    for _i, path in ipairs(paths) do
        listed[path] = true
    end
    local kept, held = {}, {}
    for _i, path in ipairs(open_paths) do
        if listed[path] then
            table.insert(kept, path)
            held[path] = true
        else
            logger.info("Bluetooth: watcher closing " .. path .. "; it is no longer listed")
            closePath(path)
        end
    end
    open_paths = kept
    for _i, path in ipairs(paths) do
        if not held[path] then
            local ok, err = Input.open(path)
            if ok then
                logger.info("Bluetooth: watcher opened the remote at " .. path)
            else
                -- Typically the udev lag -- /proc lists the device before the
                -- node exists. The next tick picks it up, so stay quiet.
                logger.dbg("Bluetooth: watcher could not open " .. path .. ": " .. tostring(err))
            end
        end
    end
end

return Input
