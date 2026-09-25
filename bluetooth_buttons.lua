--[[--
Turning the remotes' button codes into page turns and actions.

@module koplugin.Bluetooth.buttons
--]]--

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Event = require("ui/event")
local logger = require("logger")
local Config = require("bluetooth_config")

local Buttons = {}

-- MSC_SCAN values: HID usages, page in the high 16 bits. evtest prints them in
-- hex. Keyboard Down/Up Arrow are what the official Kobo Remote sends, and what
-- the Hanlinyue Free3 sends in P mode set to Up and Down Mode.
local SCAN_FORWARD = 0x70051  -- Keyboard Down Arrow
local SCAN_BACK = 0x70052     -- Keyboard Up Arrow
-- The Free3's third (bottom) button, in every mode tested. The Kobo Remote has
-- no equivalent. It runs whatever Dispatcher actions the menu assigns to it.
local SCAN_THIRD = 0x7002c    -- Keyboard Spacebar

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
local PAIR_GAP = 30

-- Press tracking; see PAIR_GAP. Keyed by MSC_SCAN value. Module-level, so
-- there is one for the whole process: see Buttons.register.
local pending = {}    -- true while a press's second code is due
local last_code = {}  -- when that value's last code arrived

-- Forget any half-seen press. Called whenever a remote's input device opens
-- or closes: a dropped link is exactly when a second code can go missing, and
-- a stale half-pair would otherwise make the next press act on release.
function Buttons.reset()
    pending = {}
end

local function onEvent(_, ev)
    if ev.type ~= 4 or ev.code ~= 4 then  -- EV_MSC, MSC_SCAN
        return
    end
    local now = ev.time.sec + ev.time.usec / 1000000
    local value = ev.value
    if value ~= SCAN_FORWARD and value ~= SCAN_BACK and value ~= SCAN_THIRD then
        return
    end
    if pending[value] then
        if now - (last_code[value] or 0) < PAIR_GAP then
            pending[value] = false
            last_code[value] = now
            return  -- the press's second code
        end
        -- A second code this late means one went missing. Log it, so a wrong
        -- page turn can be traced from crash.log.
        logger.info(string.format("Bluetooth: press of 0x%x abandoned its pair after %.1f s",
            value, now - (last_code[value] or 0)))
    end
    last_code[value] = now
    pending[value] = true
    local step
    if value == SCAN_FORWARD then
        step = 1
    elseif value == SCAN_BACK then
        step = -1
    end
    if step then
        if G_reader_settings:isTrue(Config.INVERT_SETTING) then
            step = -step
        end
        UIManager:sendEvent(Event:new("GotoViewRel", step))
    elseif value == SCAN_THIRD then
        local actions = G_reader_settings:readSetting(Config.BUTTONS_SETTING, {})[Config.THIRD_KEY]
        if actions and next(actions) then
            -- Off the input path: an action may open a menu or reflow the
            -- book, which has no business running inside an event-adjust hook.
            UIManager:nextTick(function() Dispatcher:execute(actions) end)
        end
    end
end

-- The remotes report button presses as EV_MSC/MSC_SCAN only; the kernel never
-- synthesises an EV_KEY for these usages, so translate them in an event-adjust
-- hook.
--
-- Once per process. KOReader init()s plugins once per UI context (FileManager
-- and ReaderUI), and registerEventAdjustHook CHAINS hooks rather than
-- replacing them: two registrations meant two page turns per press.
local registered = false
function Buttons.register()
    if registered then
        return
    end
    registered = true
    Device.input:registerEventAdjustHook(onEvent)
end

return Buttons
