--[[--
This is a plugin to manage Bluetooth.

@module koplugin.Bluetooth
--]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local InputContainer = require("ui/widget/container/inputcontainer")
local Device = require("device")
local Event = require("ui/event")
local Trapper = require("ui/trapper")
local logger = require("logger")
local ffi = require("ffi")

-- Not declared by KOReader's own ffi headers. pcall both steps: a conflicting
-- redeclaration is an error, and so is a libc without the symbol. Without it,
-- closeInputPath falls back to closing unconditionally, as it always did.
pcall(ffi.cdef, "ssize_t readlink(const char *path, char *buf, size_t bufsiz);")
local have_readlink = pcall(function() return ffi.C.readlink end)

local _ = require("gettext")
-- Messages take their variable parts through T() placeholders (%1, %2), so
-- translators get whole sentences they can reorder.
local T = require("ffi/util").template

-- Module-level state, shared by every instance of this plugin in the process.
-- KOReader init()s plugins once per UI context (FileManager and ReaderUI), and
-- registerEventAdjustHook CHAINS hooks rather than replacing them. Keeping the
-- flag and the press-tracking state here means only one hook is ever
-- registered, and it tracks presses in a single shared place.
local bt_hook_registered = false

-- Press tracking; see BT_PAIR_GAP. Keyed by MSC_SCAN value.
local bt_pending = {}        -- true while a press's second code is due
local bt_last_code = {}      -- when that value's last code arrived

-- Forget any half-seen press. Called whenever a remote's input device opens
-- or closes: a dropped link is exactly when a second code can go missing, and
-- a stale half-pair would otherwise make the next press act on release.
local function resetPresses()
    bt_pending = {}
end

-- MSC_SCAN values: HID usages, page in the high 16 bits. evtest prints them in
-- hex. Keyboard Down/Up Arrow are what the official Kobo Remote sends, and what
-- the Hanlinyue Free3 sends in P mode set to Up and Down Mode.
local BT_SCAN_FORWARD = 0x70051  -- Keyboard Down Arrow
local BT_SCAN_BACK = 0x70052     -- Keyboard Up Arrow
-- The Free3's third (bottom) button, in every mode tested. The Kobo Remote has
-- no equivalent. It runs whatever Dispatcher actions the menu assigns to it.
local BT_SCAN_THIRD = 0x7002c    -- Keyboard Spacebar

-- Every press sends its code exactly twice, on both remotes, measured with
-- evtest on the Sage (#31):
--   Free3        both at press, 18-40 ms apart; nothing at release, nothing
--                while held. A fast double-tap puts presses ~140 ms apart.
--   Kobo Remote  one at press, one at release, 4-200 ms later for a tap. While
--                held it sends empty reports (a bare SYN) every ~37 ms, and
--                the second code only on release, however long that takes.
-- So a press acts on its first code and swallows its second -- however long
-- the second takes, since a held Kobo Remote button sends it only on release.
-- No time window can do this: the Kobo Remote's release can come seconds
-- after its press, a Free3 re-tap 140 ms after the last. The old 0.5 s window
-- lost the second page of a Free3 double-tap, and turned two pages for a Kobo
-- Remote press held longer than half a second.
--
-- The held button's empty reports are no help: evtest shows them, but they
-- never reach KOReader's event hook ("last empty report never" in the log).
--
-- Getting out of step would make every later press act on release, so the
-- pairing resets whenever a remote's input device opens or closes (a dropped
-- link), and a pair left open this long is abandoned as a backstop. Nobody
-- holds a page-turn button for half a minute.
local BT_PAIR_GAP = 30

-- Global KOReader setting behind "Invert page-turn buttons". Read on every
-- press rather than cached, so the menu toggle takes effect immediately.
local BT_INVERT_SETTING = "bluetooth_invert_page_turn"

-- Global KOReader setting holding the third button's Dispatcher actions, in
-- the shape Dispatcher:addSubMenu edits: a table of action lists keyed by
-- button. It lives inside G_reader_settings, so edits persist with it.
local BT_BUTTONS_SETTING = "bluetooth_button_actions"
local BT_THIRD_KEY = "third"

local PLUGIN_DIR = "/mnt/onboard/.adds/koreader/plugins/bluetooth.koplugin/"

-- Seconds to wait for the uhid node after the link comes up.
local BT_INPUT_WAIT = 5

-- Seconds between watcher ticks. The remote can come back without anyone
-- touching the menu: a keypress makes it re-advertise and BlueZ reconnects it
-- unprompted, because repair.sh trusted it.
local BT_WATCH_INTERVAL = 5

-- Only one watcher for the whole process, for the same reason as
-- bt_hook_registered above: init() runs once for FileManager and again for
-- ReaderUI, and two timers would race each other onto the same device.
local bt_watch_scheduled = false

-- Seconds between unattended reconnect attempts. Far slower than the watch
-- tick, because each attempt spawns bluetoothctl and waits on 5 s timeouts,
-- and can only succeed if the remote happens to be advertising right then.
local BT_RECONNECT_INTERVAL = 60

-- For this long after Bluetooth comes up -- at startup, on waking, after a
-- restart or a manual toggle -- attempts come every BT_RECONNECT_FAST seconds
-- instead. That is when a remote is most likely to be switched on at any
-- moment: on the Sage the Free3 was off after a night's sleep, missed the
-- attempt made right after waking, and waited another minute.
local BT_RECONNECT_FAST_FOR = 120
local BT_RECONNECT_FAST = 10
local bt_fast_until = 0

-- An attempt against remotes that don't answer can take longer than
-- BT_RECONNECT_FAST, so attempts must not overlap. A start time rather than a
-- flag, so a run that never reports back (an error, a hung script) holds the
-- next one off for BT_RECONNECT_INTERVAL at most, not for the whole session.
local bt_reconnect_running_since = nil

-- Seconds between background restarts of the whole stack when the controller
-- is found dead. A restart takes the radio down for several seconds, so this
-- is deliberately slow: it is a recovery, not a retry loop.
local BT_RESTART_INTERVAL = 300
local bt_last_restart = 0

-- Set when onSuspend switched Bluetooth off, so onResume knows to bring it
-- back -- and only then.
local bt_off_for_suspend = false

-- When the last unattended attempt started, for the rate limit. Overlap is
-- prevented separately, by bt_reconnect_running_since.
local bt_last_reconnect = 0

-- Global KOReader setting behind "Turn on Bluetooth at startup". Unset means
-- on, so a fresh install brings Bluetooth up without a menu tap.
local BT_AUTOSTART_SETTING = "bluetooth_autostart"

-- Seconds after startup before bringing Bluetooth up, so on.sh's rfkill cycle
-- and daemon restarts don't compete with KOReader opening the last book.
local BT_AUTOSTART_DELAY = 3

-- Once per process, for the same reason as bt_watch_scheduled: init() runs for
-- FileManager and again for ReaderUI.
local bt_autostart_done = false

-- While on.sh is running, the watcher stands aside. hci0 appears partway
-- through it, so isBluetoothOn() turns true while bluetoothd is still being
-- restarted, and a reconnect started then races the teardown -- seen on the
-- Sage as a connect.sh running alongside on.sh at startup. A deadline rather
-- than a flag, so a start that never reports back (a dismissed "Starting
-- Bluetooth" message) can't hold the watcher off for good. 40 s covers on.sh's
-- worst case: two full attempts, each waiting up to 15 s for hci0.
local BT_START_GRACE = 40
local bt_starting_until = 0

local function startingBluetooth()
    bt_starting_until = os.time() + BT_START_GRACE
end

local function startedBluetooth()
    bt_starting_until = 0
    -- Let the watcher's next tick try the remotes straight away, and keep
    -- trying often for a while: see BT_RECONNECT_FAST_FOR.
    bt_last_reconnect = 0
    bt_fast_until = os.time() + BT_RECONNECT_FAST_FOR
end

-- The "widget" for a run nobody should see or be able to cancel. Trapper
-- takes a table as an already-shown widget: it attaches its dismiss_callback
-- and, since it didn't create it, never shows or closes it. This one is never
-- shown, so nothing can dismiss it and every tap goes to the reader as normal.
--
-- Trapper's own invisible widget (passing `true`) is dismissed by any tap, and
-- on the Sage it was: "unattended reconnect was interrupted" and "startup was
-- interrupted" logged together at startup, with both scripts left running
-- unsupervised (#30). A fresh table per run, since Trapper writes into it.
local function BACKGROUND()
    return {}
end

-- Wait `seconds` without stalling the UI. Inside a coroutine (Trapper:wrap),
-- yield and have UIManager resume us; outside one, all that's left is a
-- blocking sleep. Every caller today runs wrapped.
local function pause(seconds)
    local co = coroutine.running()
    if not co then
        os.execute("sleep " .. tonumber(seconds))
        return
    end
    UIManager:scheduleIn(seconds, function() coroutine.resume(co) end)
    coroutine.yield()
end

-- While a remote is being connected or re-paired from the menu, the watcher
-- makes no reconnect attempts of its own. On the Sage an unattended connect.sh
-- dialled the Free3 in the middle of a RePair's scan, and the pair that
-- followed ran against an already connected device and left no bond
-- ("Paired: no"). A deadline rather than a flag, for the same reason as
-- bt_starting_until; 90 s covers repair.sh's worst case, about 65 s.
local BT_MANUAL_GRACE = 90
local bt_manual_until = 0

-- Call inside Trapper:wrap(). An unattended attempt already under way is left
-- to finish first; connect.sh --no-repair gives up within about 15 s.
local function beginManual()
    bt_manual_until = os.time() + BT_MANUAL_GRACE
    while bt_reconnect_running_since and os.time() - bt_reconnect_running_since < BT_RECONNECT_INTERVAL do
        pause(1)
    end
end

-- Only once the script has finished: a dismissed message leaves it running,
-- and the deadline then keeps the watcher out until it is done.
local function endManual()
    bt_manual_until = 0
end

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
    local f = io.open(PLUGIN_DIR .. "device.conf", "r")
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
local BT_DEVICE_NAMES = readDeviceNames()
local BT_DEVICE_NAME_SET = {}
for _i, name in ipairs(BT_DEVICE_NAMES) do
    BT_DEVICE_NAME_SET[name] = true
end

-- Quote a string for sh, for passing a remote's name to a script.
local function shellQuote(str)
    return "'" .. str:gsub("'", "'\\''") .. "'"
end

-- The paths we actually have open. Event numbers move across reconnects, so
-- closing whatever /proc lists now could close something we never opened.
local bt_open_paths = {}

-- Put "Bluetooth" on the settings tab directly below "Network", rather than
-- inside it. Plugins normally place themselves with sorting_hint, which can
-- only append to the end of a menu. KOReader's menu order is a plain table
-- that require() caches, so naming the item in it, right after "network",
-- gives it that exact spot. Both the reader's and the file manager's order
-- need it. If the table isn't there or has no "network", the "setting"
-- sorting_hint still lands it on the same tab.
local function placeBesideNetwork(order_module)
    local ok, order = pcall(require, order_module)
    if not ok or type(order) ~= "table" or type(order.setting) ~= "table" then
        return
    end
    for _i, id in ipairs(order.setting) do
        if id == "bluetooth" then
            return  -- already placed
        end
    end
    for i, id in ipairs(order.setting) do
        if id == "network" then
            table.insert(order.setting, i + 1, "bluetooth")
            return
        end
    end
end
placeBesideNetwork("ui/elements/reader_menu_order")
placeBesideNetwork("ui/elements/filemanager_menu_order")

local Bluetooth = InputContainer:extend{
    name = "Bluetooth",
}

function Bluetooth:onDispatcherRegisterActions()
    Dispatcher:registerAction("bluetooth_on_action",
        {category="none", event="BluetoothOn", title=_("Bluetooth On"), general=true})
    Dispatcher:registerAction("bluetooth_off_action",
        {category="none", event="BluetoothOff", title=_("Bluetooth Off"), general=true})
    Dispatcher:registerAction("refresh_pairing_action",
        {category="none", event="RefreshPairing", title=_("Refresh Device Input"), general=true})
    Dispatcher:registerAction("connect_to_device_action",
        {category="none", event="ConnectToDevice", title=_("Connect to Device"), general=true})
end

function Bluetooth:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)


    -- The remote reports button presses as EV_MSC/MSC_SCAN only; the kernel
    -- never synthesises an EV_KEY for these usages, so translate them here.
    if not bt_hook_registered then
        bt_hook_registered = true
        Device.input:registerEventAdjustHook(function(_, ev)
            if ev.type == 4 and ev.code == 4 then  -- EV_MSC, MSC_SCAN
                local now = ev.time.sec + ev.time.usec / 1000000
                local value = ev.value
                if value ~= BT_SCAN_FORWARD and value ~= BT_SCAN_BACK and value ~= BT_SCAN_THIRD then
                    return
                end
                if bt_pending[value] then
                    if now - (bt_last_code[value] or 0) < BT_PAIR_GAP then
                        bt_pending[value] = false
                        bt_last_code[value] = now
                        return  -- the press's second code
                    end
                    -- A second code this late means one went missing. Log it,
                    -- so a wrong page turn can be traced from crash.log.
                    logger.info(string.format("Bluetooth: press of 0x%x abandoned its pair after %.1f s",
                        value, now - (bt_last_code[value] or 0)))
                end
                bt_last_code[value] = now
                bt_pending[value] = true
                local step
                if ev.value == BT_SCAN_FORWARD then
                    step = 1
                elseif ev.value == BT_SCAN_BACK then
                    step = -1
                end
                if step then
                    if G_reader_settings:isTrue(BT_INVERT_SETTING) then
                        step = -step
                    end
                    UIManager:sendEvent(Event:new("GotoViewRel", step))
                elseif ev.value == BT_SCAN_THIRD then
                    local actions = G_reader_settings:readSetting(BT_BUTTONS_SETTING, {})[BT_THIRD_KEY]
                    if actions and next(actions) then
                        -- Off the input path: an action may open a menu or
                        -- reflow the book, which has no business running
                        -- inside an event-adjust hook.
                        UIManager:nextTick(function() Dispatcher:execute(actions) end)
                    end
                end
            end
        end)
    end

    -- Started here rather than from onBluetoothOn so it survives a KOReader
    -- restart with Bluetooth already on, instead of waiting for a toggle.
    -- Guarded, so the second instance doesn't add a second timer.
    self:scheduleWatch()

    if not bt_autostart_done then
        bt_autostart_done = true
        -- Skipped when Bluetooth is already up, e.g. after a KOReader restart:
        -- on.sh always tears the stack down first, which would drop a remote
        -- that is working.
        if G_reader_settings:nilOrTrue(BT_AUTOSTART_SETTING) and not self:isBluetoothOn() then
            UIManager:scheduleIn(BT_AUTOSTART_DELAY, function() Bluetooth:autoStart() end)
        end
    end
end

-- Bring Bluetooth up at startup without putting anything on screen.
--
-- Runs on.sh only, in the background like the unattended reconnect, and logs
-- rather than pops up: a startup popup every time the remotes happen to be off
-- would be worse than none. Connecting is left to the watcher, which stands
-- aside until on.sh is done and then runs connect.sh --no-repair straight
-- away, trying the remotes in order. A remote
-- whose bond is gone still needs RePair from the menu, as with any unattended
-- attempt.
--
-- Not gated on Wi-Fi like the Toggle menu entry: whether Bluetooth really
-- needs it is unresolved (#42). If on.sh fails, the log says so.
function Bluetooth:autoStart()
    self:startInBackground("at startup")
end

-- Run on.sh in the background and log the outcome; the watcher connects
-- afterwards. Shared by startup, resume and the dead-controller recovery.
-- `why` finishes the log lines: "turned on at startup", "... on resume".
function Bluetooth:startInBackground(why)
    Trapper:wrap(function()
        startingBluetooth()
        local completed, result = self:executeScript("on.sh", BACKGROUND())
        startedBluetooth()
        if not completed then
            logger.info("Bluetooth: start " .. why .. " was interrupted; on.sh may still finish")
        elseif result and result:match("complete") then
            logger.info("Bluetooth: turned on " .. why)
        else
            logger.info("Bluetooth: could not turn on " .. why .. ": " ..
                        tostring(result):gsub("%s+", " "):sub(1, 120))
        end
    end)
end

function Bluetooth:addToMainMenu(menu_items)
    menu_items.bluetooth = {
        text = _("Bluetooth"),
        -- Fallback only: placeBesideNetwork() normally puts it in the menu
        -- order explicitly, and an item the order names ignores its hint.
        sorting_hint = "setting",
        sub_item_table = {
            {
                text = _("Toggle Bluetooth"),
                keep_menu_open = true,
                checked_func = function()
                    return self:isBluetoothOn()
                end,
                callback = function()
                    if not self:isWifiEnabled() then
                        self:popup(_("Please turn on Wi-Fi to continue."))
                    elseif self:isBluetoothOn() then
                        self:onBluetoothOff()
                    else
                        self:onBluetoothOn()
                    end
                end,
                separator = true,
            },
            {
                text = _("Reconnect to Device"),
                enabled_func = function()
                    return self:isBluetoothOn()
                end,
                callback = function()
                    self:onConnectToDevice()
                end,
            },
            {
                text = _("RePair & Reconnect to Device (long!)"),
                enabled_func = function()
                    return self:isBluetoothOn()
                end,
                -- One entry per remote: a re-pair removes that remote's bond
                -- before rebuilding it, so it has to be aimed at one.
                sub_item_table_func = function()
                    local items = {}
                    for _i, name in ipairs(BT_DEVICE_NAMES) do
                        table.insert(items, {
                            text = name,
                            callback = function()
                                self:onDeviceRepair(name)
                            end,
                        })
                    end
                    return items
                end,
            },
            {
                text = _("Refresh Device Input"),
                enabled_func = function()
                    return self:isBluetoothOn()
                end,
                callback = function()
                    self:onRefreshPairing()
                end,
                separator = true,
            },
            {
                text = _("Invert page-turn buttons"),
                keep_menu_open = true,
                checked_func = function()
                    return G_reader_settings:isTrue(BT_INVERT_SETTING)
                end,
                callback = function()
                    G_reader_settings:flipNilOrFalse(BT_INVERT_SETTING)
                end,
            },
            {
                text = _("Turn on Bluetooth at startup"),
                keep_menu_open = true,
                checked_func = function()
                    return G_reader_settings:nilOrTrue(BT_AUTOSTART_SETTING)
                end,
                callback = function()
                    G_reader_settings:flipNilOrTrue(BT_AUTOSTART_SETTING)
                end,
            },
            {
                text = _("Bluetooth info"),
                keep_menu_open = true,
                callback = function()
                    self:onShowBluetoothInfo()
                end,
            },
            {
                text_func = function()
                    local actions = G_reader_settings:readSetting(BT_BUTTONS_SETTING, {})[BT_THIRD_KEY]
                    return T(_("Third button (Free3): %1"),
                             actions and Dispatcher:menuTextFunc(actions) or _("Nothing"))
                end,
                sub_item_table_func = function()
                    -- KOReader's own action picker, as used for gestures and
                    -- hotkeys. It edits the table in place and sets
                    -- self.updated, which onFlushSettings picks up.
                    local sub_items = {}
                    Dispatcher:addSubMenu(self, sub_items,
                        G_reader_settings:readSetting(BT_BUTTONS_SETTING, {}), BT_THIRD_KEY)
                    return sub_items
                end,
            },
        },
    }
end

-- Suspend and resume (#29). KOReader broadcasts both to plugins, and kills
-- Wi-Fi before suspending, because power-managing with the Wi-Fi module
-- loaded can crash the kernel on Kobos. On the Sage, Bluetooth lives on the
-- same RTL8821CS chip, which KOReader knows nothing about -- and left running
-- across a suspend, the serial link to it died: hci0 DOWN, "retransmitting"
-- in dmesg, every bluetoothctl call failing with org.bluez.Error.Busy, and no
-- remote until a manual toggle. So Bluetooth goes off with the Kobo and comes
-- back in the background when it wakes, the way KOReader treats Wi-Fi.
local function btStateSummary()
    local present = select(2, Bluetooth:findInputDevices())
    local names = {}
    for _i, name in ipairs(BT_DEVICE_NAMES) do
        if present[name] then
            table.insert(names, name)
        end
    end
    return "bluetooth " .. (Bluetooth:isBluetoothOn() and "on" or "off") ..
           ", remotes present: " .. (#names > 0 and table.concat(names, ", ") or "none") ..
           ", open: " .. (#bt_open_paths > 0 and table.concat(bt_open_paths, ", ") or "none")
end

function Bluetooth:onSuspend()
    logger.info("Bluetooth: suspending; " .. btStateSummary())
    if not self:isBluetoothOn() then
        return
    end
    bt_off_for_suspend = true
    self:closeInputDevices()
    -- Synchronously: the Kobo suspends as soon as the Suspend handlers
    -- return, so a background run would still be going when it does. off.sh
    -- only kills two daemons and blocks the radio; it takes about a second.
    os.execute("/bin/sh " .. PLUGIN_DIR .. "off.sh >/dev/null 2>&1")
    logger.info("Bluetooth: turned off for suspend")
end

function Bluetooth:onResume()
    logger.info("Bluetooth: resumed; " .. btStateSummary())
    -- Timers don't run while asleep, so the reconnect clock may say an attempt
    -- is recent when it is hours old. Let the watcher's next tick dial the
    -- remotes straight away if one is missing.
    bt_last_reconnect = 0
    if bt_off_for_suspend then
        bt_off_for_suspend = false
        -- A moment's grace for the rest of the resume to settle first.
        UIManager:scheduleIn(1, function() Bluetooth:startInBackground("on resume") end)
    end
end

-- Dispatcher edits the button actions in place inside G_reader_settings and
-- only marks us updated, so write them out when KOReader flushes settings.
function Bluetooth:onFlushSettings()
    if self.updated then
        G_reader_settings:flush()
        self.updated = nil
    end
end

function Bluetooth:getScriptPath(script)
    return script
end

-- Run a script off the UI thread, showing a dismissable message while it works.
--
-- Returns Trapper's own pair: completed, output. `completed` is false when the
-- message was dismissed, and the script keeps running regardless -- there's no
-- way to call it back, so the output of a dismissed run can't be trusted.
--
-- Callers must take BOTH values: assigning this to a single variable binds
-- the boolean instead of the output, which then blows up on the first
-- result:match(). Trapper:wrap swallows that error into a pcall, so the
-- symptom is nothing happening rather than a traceback.
--
-- `script` may carry arguments; it is appended to the interpreter and plugin
-- directory as-is. `message` is what Trapper shows while it works -- a string
-- gets a dismissable widget. Background runs pass BACKGROUND() instead: see
-- there.
--
-- Needs to run inside Trapper:wrap(); outside one, Trapper logs a warning and
-- falls back to a blocking io.popen, which is exactly today's behaviour.
--
-- The script's output is collected by the shell and written in one piece when
-- it exits, always with at least a newline. Trapper decides the script is done
-- by polling the pipe with FIONREAD, and then reads the rest with a blocking
-- read("*all") on the UI thread, which gives two failure modes:
--   * no output at all (off.sh on success): EOF reads as 0 bytes available,
--     so it never completes, and the message stays up until tapped away;
--   * early output (repair.sh relaying bluetoothctl as it goes): the first
--     line counts as done, and the blocking read then freezes the reader for
--     the rest of the script.
-- stderr is left alone and still goes to crash.log.
function Bluetooth:executeScript(script, message)
    local command = "out=$(/bin/sh " .. PLUGIN_DIR .. script .. "); printf '%s\\n' \"$out\""
    return Trapper:dismissablePopen(command, message)
end

function Bluetooth:onBluetoothOn()
    if not Trapper:isWrapped() then
        return Trapper:wrap(function() self:onBluetoothOn() end)
    end

    local script = self:getScriptPath("on.sh")
    startingBluetooth()
    local completed, result = self:executeScript(script, _("Starting Bluetooth…"))
    if completed then
        startedBluetooth()
    end

    if not completed then
        logger.dbg("Bluetooth: " .. script .. " dismissed or could not be run")
        return
    end

    if not result or not result:match("%S") then
        self:popup(_("Error: No result from the Bluetooth script"))
        return
    end

    if result:match("complete") then
        -- on.sh succeeded; go straight into connecting so a single menu tap
        -- brings a remote all the way up. Connect rather than re-pair: a
        -- re-pair throws away bonds that are usually fine, and connect.sh
        -- still hands over to repair.sh for a remote whose bond is gone.
        -- onConnectToDevice shows its own popup.
        self:onConnectToDevice()
    else
        self:failurePopup(result)
    end
end

function Bluetooth:onBluetoothOff()
    if not Trapper:isWrapped() then
        return Trapper:wrap(function() self:onBluetoothOff() end)
    end

    local script = self:getScriptPath("off.sh")

    -- The uhid device goes away with the stack, so drop our handle first
    -- rather than leaving it open against a device that no longer exists.
    self:closeInputDevices()

    -- Both return values are ignored on purpose: off.sh prints nothing on
    -- success, and dismissing the message doesn't call the teardown back, so
    -- the stack goes down either way and the popup below stays true.
    self:executeScript(script, _("Turning Bluetooth off…"))

    self:popup(_("Bluetooth turned off."))
end

function Bluetooth:onRefreshPairing()
    -- Wrapped so refreshPairing's wait can yield instead of blocking (#33).
    if not Trapper:isWrapped() then
        return Trapper:wrap(function() self:onRefreshPairing() end)
    end
    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before refreshing pairing."))
        return
    end
    if self:refreshPairing() then
        self:popup(T(_("Bluetooth device at %1 is now open."), table.concat(bt_open_paths, ", ")))
    end
end

-- Locate every /dev/input/eventN carrying the remote's name. The numbers are
-- not stable across reconnects, so they have to be resolved every time rather
-- than assumed. Blocks look like:
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
function Bluetooth:findInputDevices()
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
            current = BT_DEVICE_NAME_SET[name] and name or nil
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
local function preferredMissing(present)
    local missing = {}
    for _i, name in ipairs(BT_DEVICE_NAMES) do
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
function Bluetooth:waitForInputDevices()
    local ready, listed = {}, {}
    for i = 0, BT_INPUT_WAIT do
        if i > 0 then
            pause(1)
        end
        listed, ready = self:findInputDevices(), {}
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
-- Device Input". In that case just forget the entry: the fd is already
-- closed, and clearing it lets the next Input:open of this path through
-- instead of being skipped as a duplicate.
--
-- Not fatal if the close fails, but it means the handle leaked, so log it
-- rather than swallowing it -- it shows up in crash.log if the call is wrong.
local function closeInputPath(path)
    resetPresses()
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
function Bluetooth:closeInputDevices()
    for _i, path in ipairs(bt_open_paths) do
        closeInputPath(path)
    end
    bt_open_paths = {}
end

-- Open one more path alongside whatever we already hold. Returns false plus
-- the error rather than reporting it, so the caller decides whether it deserves
-- a popup: the menu paths want one, the watcher has to stay silent.
function Bluetooth:openInputDevice(path)
    resetPresses()
    local ok, err = pcall(function()
        Device.input:open(path)
    end)
    if not ok then
        return false, err
    end
    table.insert(bt_open_paths, path)
    return true
end

-- Open exactly these paths, dropping whatever we currently hold first. True
-- if at least one opened; otherwise false plus the last error.
function Bluetooth:reopenInputDevices(paths)
    self:closeInputDevices()
    local last_err
    for _i, path in ipairs(paths) do
        local ok, err = self:openInputDevice(path)
        if not ok then
            last_err = err
        end
    end
    if #bt_open_paths == 0 then
        return false, last_err
    end
    return true
end

-- Notice the remote coming and going without a menu tap.
--
-- Pressing a button makes the remote re-advertise, and BlueZ reconnects it on
-- its own because repair.sh trusted it. The uhid device is recreated with
-- whatever event number happens to be free, so KOReader is left holding an fd
-- to a device that no longer exists -- connected, but dead, until "Refresh
-- Device Input" is tapped. Watching /proc closes that gap.
--
-- Runs against the module table rather than an instance: KOReader tears the
-- plugin down and rebuilds it when moving between FileManager and ReaderUI, so
-- the timer outlives any single self.
-- Ask for the link back without anyone tapping anything.
--
-- BlueZ will not re-dial an LE peripheral: its [Policy] reconnect works by
-- calling a profile's connect method, HoG hasn't got one, and the attempt dies
-- with "Operation not supported". Doing it from here is the only route.
--
-- Always runs connect.sh with --no-repair, so an unattended attempt can never
-- take the destructive path: repair.sh removes the bond before rebuilding it,
-- and a re-pair that doesn't take would leave the remote worse off than it
-- started. Recovering a lost bond stays a deliberate menu tap.
--
-- `names` limits it to those remotes; the watcher passes the ones missing
-- ahead of whichever is connected, so a preferred remote coming back is
-- dialled even while another one is in use. The Free3 does not reconnect by
-- itself either -- every return seen on the Sage was this dialling it -- so
-- without this a connected Kobo Remote kept it out indefinitely. Failures in
-- that case are only debug-logged: with the preferred remote simply switched
-- off, they would otherwise fill crash.log at one a minute.
function Bluetooth:tryReconnect(names, quiet)
    local now = os.time()
    if now < bt_manual_until then
        return  -- a connect or re-pair from the menu is running
    end
    if bt_reconnect_running_since and now - bt_reconnect_running_since < BT_RECONNECT_INTERVAL then
        return  -- the previous attempt is still going
    end
    local interval = now < bt_fast_until and BT_RECONNECT_FAST or BT_RECONNECT_INTERVAL
    if now - bt_last_reconnect < interval then
        return
    end
    bt_last_reconnect = now
    bt_reconnect_running_since = now

    -- The tick is a plain timer callback rather than a coroutine, so this needs
    -- its own wrap. It runs in the BACKGROUND: nothing on screen, and nothing a
    -- tap on the reader can cancel.
    Trapper:wrap(function()
        local script = "connect.sh --no-repair"
        if names then
            script = script .. " " .. shellQuote(table.concat(names, "|"))
        end
        local completed, result = self:executeScript(script, BACKGROUND())
        bt_reconnect_running_since = nil

        -- Every outcome gets a line. Logging only the two recognised ones left
        -- silence meaning both "never ran" and "ran and said something else",
        -- which is not a distinction worth having to guess at from a log.
        if not completed then
            logger.info("Bluetooth: unattended reconnect was interrupted")
        elseif not result then
            logger.info("Bluetooth: unattended reconnect produced no output")
        elseif result:match("Connection successful") then
            -- Opening the input device is left to the next tick, which is what
            -- it's for; the uhid node lags the link coming up anyway.
            logger.info("Bluetooth: reconnected the remote unattended" ..
                        (result:match("Remote: ([^\n]+)") and
                         " (" .. result:match("Remote: ([^\n]+)") .. ")" or ""))
        elseif result:match("controller is not responding") then
            -- The link to the chip is dead; only a full restart recovers it.
            local now_restart = os.time()
            if now_restart - bt_last_restart >= BT_RESTART_INTERVAL then
                bt_last_restart = now_restart
                logger.info("Bluetooth: the controller is not responding; restarting Bluetooth")
                self:startInBackground("after the controller stopped responding")
            else
                logger.dbg("Bluetooth: the controller is not responding; restarted recently, waiting")
            end
        elseif result:match("without a valid bond") then
            logger.info("Bluetooth: the remote is back but its bond is gone; needs a re-pair")
        else
            local log = quiet and logger.dbg or logger.info
            log("Bluetooth: unattended reconnect did not take: " ..
                result:gsub("%s+", " "):sub(1, 120))
        end
    end)
end

local function btWatchTick()
    bt_watch_scheduled = false

    if os.time() < bt_starting_until then
        -- on.sh is still bringing the stack up; see startingBluetooth().
        Bluetooth:scheduleWatch()
        return
    end

    if Bluetooth:isBluetoothOn() then
        local paths, present = Bluetooth:findInputDevices()
        if #paths > 0 then
            -- Reconcile what we hold with what is listed: close what has gone,
            -- open what is new, and leave the rest alone so a live remote isn't
            -- dropped for a moment whenever one of its siblings changes.
            local listed = {}
            for _i, path in ipairs(paths) do
                listed[path] = true
            end
            local kept, held = {}, {}
            for _i, path in ipairs(bt_open_paths) do
                if listed[path] then
                    table.insert(kept, path)
                    held[path] = true
                else
                    logger.info("Bluetooth: watcher closing " .. path .. "; it is no longer listed")
                    closeInputPath(path)
                end
            end
            bt_open_paths = kept
            for _i, path in ipairs(paths) do
                if not held[path] then
                    local ok, err = Bluetooth:openInputDevice(path)
                    if ok then
                        logger.info("Bluetooth: watcher opened the remote at " .. path)
                    else
                        -- Typically the udev lag -- /proc lists the device
                        -- before the node exists. The next tick picks it up,
                        -- so stay quiet.
                        logger.dbg("Bluetooth: watcher could not open " .. path .. ": " .. tostring(err))
                    end
                end
            end
            -- A remote is in use, but maybe not the first choice.
            local missing = preferredMissing(present)
            if #missing > 0 then
                Bluetooth:tryReconnect(missing, true)
            end
        else
            if #bt_open_paths > 0 then
                -- The remote went away. Drop the handles instead of leaving
                -- them pointing at destroyed uhid devices until the next connect.
                logger.info("Bluetooth: watcher closing " .. table.concat(bt_open_paths, ", ") ..
                            "; the remote is gone")
                Bluetooth:closeInputDevices()
            end
            Bluetooth:tryReconnect()
        end
    end

    Bluetooth:scheduleWatch()
end

-- Ticks even while Bluetooth is off, where the check costs two small sysfs
-- reads: a watcher that stops has to be started again from somewhere, and
-- that's one more thing to get wrong across the two plugin instances.
function Bluetooth:scheduleWatch()
    if bt_watch_scheduled then
        return
    end
    bt_watch_scheduled = true
    UIManager:scheduleIn(BT_WATCH_INTERVAL, btWatchTick)
end

-- Returns true if the input device was opened. Callers must check it before
-- reporting success: this pops up its own error, and claiming the device is
-- open right after that is the common case when the event number has moved.
function Bluetooth:refreshPairing()
    local ready, listed = self:waitForInputDevices()
    if #ready == 0 then
        if #listed > 0 then
            self:popup(T(_("The remote is connected and listed as %1, but no device node for it exists."),
                         table.concat(listed, ", ")))
        else
            self:popup(T(_("Could not find %1 in /proc/bus/input/devices. Is it connected?"),
                         table.concat(BT_DEVICE_NAMES, _(" or "))))
        end
        return false
    end

    -- reopenInputDevices closes the previous fds first, which must happen even
    -- when the paths are unchanged: a disconnect destroys the uhid device and
    -- the reconnect can recreate it on the same event number, so the fd we
    -- hold refers to a device that no longer exists. Same path, different
    -- device, no events. Skipping the close here is why a reconnect onto the
    -- same eventN left the remote connected but dead.
    local ok, err = self:reopenInputDevices(ready)
    if not ok then
        self:popup(T(_("Error: %1"), tostring(err)))
        return false
    end

    return true
end

-- Re-pair one remote by name; with no name, repair.sh takes the first listed.
function Bluetooth:onDeviceRepair(name)
    if not Trapper:isWrapped() then
        return Trapper:wrap(function() self:onDeviceRepair(name) end)
    end

    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before connecting to a device."))
        return
    end
    local script = self:getScriptPath("repair.sh")
    if name then
        script = script .. " " .. shellQuote(name)
    end
    beginManual()
    local completed, result = self:executeScript(script,
        T(_("Pairing with %1… Put it in pairing mode."), name or BT_DEVICE_NAMES[1]))
    if completed then
        endManual()
    end

    if not completed then
        logger.dbg("Bluetooth: " .. script .. " dismissed or could not be run")
        return
    end

    if not result then
        self:popup(T(_("Error: could not run %1"), script))
        return
    end

    -- Simplify the message: focus on the success and device name
    local success = result:match("Connection successful")  -- Check if connection was successful
    if success then
        -- refreshPairing polls for the uhid node, so no fixed sleep needed
        if self:refreshPairing() then
            self:popup(self:connectedMessage(result))
        end
    else
        self:failurePopup(result)
    end
end

function Bluetooth:onConnectToDevice()
    -- Trapper needs a coroutine to yield into. Wrapping here rather than at the
    -- menu callback covers the Dispatcher entry point too, so a gesture bound
    -- to this action gets the same treatment as a menu tap.
    if not Trapper:isWrapped() then
        return Trapper:wrap(function() self:onConnectToDevice() end)
    end

    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before connecting to a device."))
        return
    end

    local script = self:getScriptPath("connect.sh")
    beginManual()
    local completed, result = self:executeScript(script, _("Connecting to the remote…"))
    if completed then
        endManual()
    end

    if not completed then
        -- Dismissed: connect.sh is still running and may yet succeed, so
        -- reporting a failure that hasn't happened would be worse than saying
        -- nothing. A failed popen also lands here and is indistinguishable, so
        -- log it -- silence is the right call for the common case, and the
        -- rare one shouldn't vanish entirely.
        logger.dbg("Bluetooth: " .. script .. " dismissed or could not be run")
        return
    end

    if not result then
        self:popup(T(_("Error: could not run %1"), script))
        return
    end

    -- Simplify the message: focus on the success and device name
    local success = result:match("Connection successful")  -- Check if connection was successful

    if success then

        -- refreshPairing polls for the uhid node, so no fixed sleep needed
        if self:refreshPairing() then
            self:popup(self:connectedMessage(result))
        end
    else
        self:failurePopup(result)
    end
end

-- Show a script's failure output. The scripts keep bluetoothctl's chatter out
-- of stdout, but a raw dump once filled the whole screen with scan results,
-- so strip colour codes and keep only the last few lines regardless.
function Bluetooth:failurePopup(result)
    local lines = {}
    for line in result:gsub("\27%[[%d;]*m", ""):gmatch("[^\r\n]+") do
        if line:match("%S") then
            table.insert(lines, line)
        end
    end
    local first = math.max(1, #lines - 7)
    self:popup(table.concat(lines, "\n", first))
end

-- KOReader knows devices by codename; the ones worth a readable name here.
local DEVICE_NAMES = {
    Kobo_cadmus = "Kobo Sage",
}

-- "Bluetooth info": which hardware and stack this is running on (#50). The
-- device and on/off state come from here; the rest from info.sh, which
-- queries the controller, the loaded driver and BlueZ without changing
-- anything.
function Bluetooth:onShowBluetoothInfo()
    if not Trapper:isWrapped() then
        return Trapper:wrap(function() self:onShowBluetoothInfo() end)
    end
    local model = Device.model or "unknown"
    local lines = {
        T(_("Device: %1"), DEVICE_NAMES[model] and DEVICE_NAMES[model] .. " (" .. model .. ")" or model),
        T(_("Bluetooth: %1"), self:isBluetoothOn() and _("on") or _("off")),
    }
    local completed, result = self:executeScript("info.sh", _("Reading Bluetooth info…"))
    if completed and result then
        for line in result:gmatch("[^\r\n]+") do
            table.insert(lines, line)
        end
    end
    self:popup(table.concat(lines, "\n"))
end

-- The success popup, naming the remote when the script said which one.
function Bluetooth:connectedMessage(result)
    local name = result:match("Remote: ([^\n]+)")
    if name then
        return T(_("Connected to %1."), name)
    end
    return _("Connection successful!")
end

function Bluetooth:isBluetoothOn()
    local file = io.open("/sys/devices/platform/bt/rfkill/rfkill0/state", "r")
    if not file then
        return false
    end
    local content = file:read("*line")
    file:close()
    if content ~= "1" then
        return false
    end

    -- rfkill only reports that the radio is unblocked, which it can be at boot
    -- with nothing attached to it. hci0 appears under /sys/class/bluetooth only
    -- once rtk_hciattach has registered the controller, and every sysfs device
    -- directory has a uevent file, so this is the cheap existence check.
    -- (It still reads as "on" for an attached-but-DOWN hci0.)
    local hci = io.open("/sys/class/bluetooth/hci0/uevent", "r")
    if not hci then
        return false
    end
    hci:close()
    return true
end

function Bluetooth:popup(text)
    local popup = InfoMessage:new{
        text = text,
    }
    UIManager:show(popup)
end

function Bluetooth:isWifiEnabled()
    local handle = io.popen("iwconfig")
    if not handle then
        return false
    end
    local result = handle:read("*a")
    handle:close()

    -- Check if Wi-Fi is enabled by looking for 'ESSID'
    return result:match("ESSID") ~= nil
end


return Bluetooth