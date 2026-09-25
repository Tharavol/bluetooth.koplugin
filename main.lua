--[[--
This is a plugin to manage Bluetooth.

The plugin class, its menu and its handlers. The rest lives in sibling
modules, which KOReader's plugin loader lets main.lua require():

  bluetooth_config   where the plugin lives, the remotes' names, setting keys
  bluetooth_buttons  button codes to page turns and actions
  bluetooth_stack    running the scripts; whether Bluetooth and Wi-Fi are up
  bluetooth_input    finding, opening and closing the remotes' input devices
  bluetooth_watcher  the watcher, the unattended reconnect, background start

The prefix matters: require() caches modules by name across every plugin.

@module koplugin.Bluetooth
--]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local InputContainer = require("ui/widget/container/inputcontainer")
local Device = require("device")
local Trapper = require("ui/trapper")
local logger = require("logger")
local _ = require("gettext")
-- Messages take their variable parts through T() placeholders (%1, %2), so
-- translators get whole sentences they can reorder.
local T = require("ffi/util").template

local Buttons = require("bluetooth_buttons")
local Config = require("bluetooth_config")
local Input = require("bluetooth_input")
local Stack = require("bluetooth_stack")
local Watcher = require("bluetooth_watcher")

-- Seconds after startup before bringing Bluetooth up, so on.sh's rfkill cycle
-- and daemon restarts don't compete with KOReader opening the last book.
local AUTOSTART_DELAY = 3

-- Once per process: init() runs once for FileManager and again for ReaderUI.
local autostart_done = false

-- Set when onSuspend switched Bluetooth off, so onResume knows to bring it
-- back -- and only then.
local off_for_suspend = false

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

-- `name` matches the folder name and _meta.lua; see there (#41).
local Bluetooth = InputContainer:extend{
    name = "bluetooth",
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

    -- Both once per process, however many instances there are.
    Buttons.register()
    -- Started here rather than from onBluetoothOn so it survives a KOReader
    -- restart with Bluetooth already on, instead of waiting for a toggle.
    Watcher.schedule()

    if not autostart_done then
        autostart_done = true
        -- Skipped when Bluetooth is already up, e.g. after a KOReader restart:
        -- on.sh always tears the stack down first, which would drop a remote
        -- that is working.
        if G_reader_settings:nilOrTrue(Config.AUTOSTART_SETTING) and not Stack.isBluetoothOn() then
            UIManager:scheduleIn(AUTOSTART_DELAY, function() Bluetooth:autoStart() end)
        end
    end
end

-- Bring Bluetooth up at startup without putting anything on screen.
--
-- Runs on.sh only, in the background like the unattended reconnect, and logs
-- rather than pops up: a startup popup every time the remotes happen to be off
-- would be worse than none. Connecting is left to the watcher, which stands
-- aside until on.sh is done and then runs connect.sh --no-repair straight
-- away, trying the remotes in order. A remote whose bond is gone still needs
-- RePair from the menu, as with any unattended attempt.
--
-- Not gated on Wi-Fi like the Toggle menu entry: whether Bluetooth really
-- needs it is unresolved (#42). If on.sh fails, the log says so.
function Bluetooth:autoStart()
    Watcher.startInBackground("at startup")
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
                    return Stack.isBluetoothOn()
                end,
                callback = function()
                    if not Stack.isWifiOn() then
                        self:popup(_("Please turn on Wi-Fi first. Bluetooth shares its chip with Wi-Fi, " ..
                                     "which powers it."))
                    elseif Stack.isBluetoothOn() then
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
                    return Stack.isBluetoothOn()
                end,
                callback = function()
                    self:onConnectToDevice()
                end,
            },
            {
                text = _("RePair & Reconnect to Device (long!)"),
                enabled_func = function()
                    return Stack.isBluetoothOn()
                end,
                -- One entry per remote: a re-pair removes that remote's bond
                -- before rebuilding it, so it has to be aimed at one.
                sub_item_table_func = function()
                    local items = {}
                    for _i, name in ipairs(Config.DEVICE_NAMES) do
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
                    return Stack.isBluetoothOn()
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
                    return G_reader_settings:isTrue(Config.INVERT_SETTING)
                end,
                callback = function()
                    G_reader_settings:flipNilOrFalse(Config.INVERT_SETTING)
                end,
            },
            {
                text = _("Turn on Bluetooth at startup"),
                keep_menu_open = true,
                checked_func = function()
                    return G_reader_settings:nilOrTrue(Config.AUTOSTART_SETTING)
                end,
                callback = function()
                    G_reader_settings:flipNilOrTrue(Config.AUTOSTART_SETTING)
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
                    local actions = G_reader_settings:readSetting(Config.BUTTONS_SETTING, {})[Config.THIRD_KEY]
                    return T(_("Third button (Free3): %1"),
                             actions and Dispatcher:menuTextFunc(actions) or _("Nothing"))
                end,
                sub_item_table_func = function()
                    -- KOReader's own action picker, as used for gestures and
                    -- hotkeys. It edits the table in place and sets
                    -- self.updated, which onFlushSettings picks up.
                    local sub_items = {}
                    Dispatcher:addSubMenu(self, sub_items,
                        G_reader_settings:readSetting(Config.BUTTONS_SETTING, {}), Config.THIRD_KEY)
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
local function stateSummary()
    local present = select(2, Input.find())
    local names = {}
    for _i, name in ipairs(Config.DEVICE_NAMES) do
        if present[name] then
            table.insert(names, name)
        end
    end
    local open_paths = Input.openPaths()
    return "bluetooth " .. (Stack.isBluetoothOn() and "on" or "off") ..
           ", remotes present: " .. (#names > 0 and table.concat(names, ", ") or "none") ..
           ", open: " .. (#open_paths > 0 and table.concat(open_paths, ", ") or "none")
end

function Bluetooth:onSuspend()
    logger.info("Bluetooth: suspending; " .. stateSummary())
    if not Stack.isBluetoothOn() then
        return
    end
    off_for_suspend = true
    Input.closeAll()
    -- Blocking: the Kobo suspends as soon as the Suspend handlers return, so
    -- a background run would still be going when it does. off.sh only kills
    -- two daemons and blocks the radio; it takes about a second.
    Stack.runBlocking("off.sh")
    logger.info("Bluetooth: turned off for suspend")
end

function Bluetooth:onResume()
    logger.info("Bluetooth: resumed; " .. stateSummary())
    Watcher.resetClock()
    if off_for_suspend then
        off_for_suspend = false
        -- A moment's grace for the rest of the resume to settle first.
        UIManager:scheduleIn(1, function() Watcher.startInBackground("on resume") end)
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

function Bluetooth:onBluetoothOn()
    if not Trapper:isWrapped() then
        return Trapper:wrap(function() self:onBluetoothOn() end)
    end

    local script = "on.sh"
    Watcher.starting()
    local completed, result = Stack.run(script, _("Starting Bluetooth…"))
    if completed then
        Watcher.started()
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

    -- The uhid device goes away with the stack, so drop our handle first
    -- rather than leaving it open against a device that no longer exists.
    Input.closeAll()

    -- Both return values are ignored on purpose: off.sh prints nothing on
    -- success, and dismissing the message doesn't call the teardown back, so
    -- the stack goes down either way and the popup below stays true.
    Stack.run("off.sh", _("Turning Bluetooth off…"))

    self:popup(_("Bluetooth turned off."))
end

function Bluetooth:onRefreshPairing()
    -- Wrapped so refreshPairing's wait can yield instead of blocking (#33).
    if not Trapper:isWrapped() then
        return Trapper:wrap(function() self:onRefreshPairing() end)
    end
    if not Stack.isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before refreshing pairing."))
        return
    end
    if self:refreshPairing() then
        self:popup(T(_("Bluetooth device at %1 is now open."), table.concat(Input.openPaths(), ", ")))
    end
end

-- Returns true if the input device was opened. Callers must check it before
-- reporting success: this pops up its own error, and claiming the device is
-- open right after that is the common case when the event number has moved.
function Bluetooth:refreshPairing()
    local ready, listed = Input.waitFor()
    if #ready == 0 then
        if #listed > 0 then
            self:popup(T(_("The remote is connected and listed as %1, but no device node for it exists."),
                         table.concat(listed, ", ")))
        else
            self:popup(T(_("Could not find %1 in /proc/bus/input/devices. Is it connected?"),
                         table.concat(Config.DEVICE_NAMES, _(" or "))))
        end
        return false
    end

    local ok, err = Input.reopen(ready)
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

    if not Stack.isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before connecting to a device."))
        return
    end
    local script = "repair.sh"
    if name then
        script = script .. " " .. Stack.shellQuote(name)
    end
    Watcher.beginManual()
    local completed, result = Stack.run(script,
        T(_("Pairing with %1… Put it in pairing mode."), name or Config.DEVICE_NAMES[1]))
    if completed then
        Watcher.endManual()
    end

    if not completed then
        logger.dbg("Bluetooth: " .. script .. " dismissed or could not be run")
        return
    end

    if not result then
        self:popup(T(_("Error: could not run %1"), script))
        return
    end

    if result:match("Connection successful") then
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

    if not Stack.isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before connecting to a device."))
        return
    end

    local script = "connect.sh"
    Watcher.beginManual()
    local completed, result = Stack.run(script, _("Connecting to the remote…"))
    if completed then
        Watcher.endManual()
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

    if result:match("Connection successful") then
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
        T(_("Bluetooth: %1"), Stack.isBluetoothOn() and _("on") or _("off")),
    }
    local completed, result = Stack.run("info.sh", _("Reading Bluetooth info…"))
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
    if name and result:match("Already connected") then
        -- repair.sh found nothing to repair and left the bond alone. The wait
        -- is BlueZ's: a remote switched off without disconnecting is still
        -- listed as connected until its link times out, 20 s on the Sage.
        -- Nothing tells the two apart sooner -- the Free3 answers neither
        -- l2ping nor hcitool name.
        return T(_("%1 is already connected and paired, so it was left as it is. " ..
                   "To pair it again anyway, turn it off, wait 20 seconds, choose RePair, then turn it on."),
                 name)
    end
    if name then
        return T(_("Connected to %1."), name)
    end
    return _("Connection successful!")
end

function Bluetooth:popup(text)
    local popup = InfoMessage:new{
        text = text,
    }
    UIManager:show(popup)
end

return Bluetooth
