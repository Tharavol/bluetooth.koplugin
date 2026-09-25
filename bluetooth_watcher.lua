--[[--
Keeping a remote connected without anyone touching the menu: the watcher that
follows the remotes' input devices, the unattended reconnect, and bringing
Bluetooth up in the background.

Everything here is per process, not per plugin instance: KOReader tears the
plugin down and rebuilds it when moving between FileManager and ReaderUI, so
the timer outlives any single instance, and two would race each other onto the
same device.

@module koplugin.Bluetooth.watcher
--]]--

local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local logger = require("logger")
local Input = require("bluetooth_input")
local Stack = require("bluetooth_stack")

local Watcher = {}

-- Seconds between watcher ticks. The remote can come back without anyone
-- touching the menu: a keypress makes it re-advertise and BlueZ reconnects it
-- unprompted, because repair.sh trusted it.
local WATCH_INTERVAL = 5
local watch_scheduled = false

-- Seconds between unattended reconnect attempts. Far slower than the watch
-- tick, because each attempt spawns bluetoothctl and waits on 5 s timeouts,
-- and can only succeed if the remote happens to be advertising right then.
local RECONNECT_INTERVAL = 60

-- For this long after Bluetooth comes up -- at startup, on waking, after a
-- restart or a manual toggle -- attempts come every RECONNECT_FAST seconds
-- instead. That is when a remote is most likely to be switched on at any
-- moment: on the Sage the Free3 was off after a night's sleep, missed the
-- attempt made right after waking, and waited another minute.
local RECONNECT_FAST_FOR = 120
local RECONNECT_FAST = 10
local fast_until = 0

-- When the last unattended attempt started, for the rate limit.
local last_reconnect = 0

-- An attempt against remotes that don't answer can take longer than
-- RECONNECT_FAST, so attempts must not overlap. A start time rather than a
-- flag, so a run that never reports back (an error, a hung script) holds the
-- next one off for RECONNECT_INTERVAL at most, not for the whole session.
local reconnect_running_since = nil

-- Seconds between background restarts of the whole stack when the controller
-- is found dead. A restart takes the radio down for several seconds, so this
-- is deliberately slow: it is a recovery, not a retry loop.
local RESTART_INTERVAL = 300
local last_restart = 0

-- While on.sh is running, the watcher stands aside. hci0 appears partway
-- through it, so isBluetoothOn() turns true while bluetoothd is still being
-- restarted, and a reconnect started then races the teardown -- seen on the
-- Sage as a connect.sh running alongside on.sh at startup. A deadline rather
-- than a flag, so a start that never reports back (a dismissed "Starting
-- Bluetooth" message) can't hold the watcher off for good. 40 s covers on.sh's
-- worst case: two full attempts, each waiting up to 15 s for hci0.
local START_GRACE = 40
local starting_until = 0

-- While a remote is being connected or re-paired from the menu, the watcher
-- makes no reconnect attempts of its own. On the Sage an unattended connect.sh
-- dialled the Free3 in the middle of a RePair's scan, and the pair that
-- followed ran against an already connected device and left no bond
-- ("Paired: no"). A deadline rather than a flag, for the same reason as
-- starting_until; 180 s covers repair.sh's worst case, about 145 s.
local MANUAL_GRACE = 180
local manual_until = 0

-- Call just before on.sh starts.
function Watcher.starting()
    starting_until = os.time() + START_GRACE
end

-- Call when on.sh reports back.
function Watcher.started()
    starting_until = 0
    -- Let the watcher's next tick try the remotes straight away, and keep
    -- trying often for a while: see RECONNECT_FAST_FOR.
    last_reconnect = 0
    fast_until = os.time() + RECONNECT_FAST_FOR
end

-- Timers don't run while asleep, so after waking the reconnect clock may say
-- an attempt is recent when it is hours old. Let the next tick dial straight
-- away.
function Watcher.resetClock()
    last_reconnect = 0
end

-- Call inside Trapper:wrap(), before a menu connect or re-pair. An unattended
-- attempt already under way is left to finish first; connect.sh --no-repair
-- gives up within about 15 s.
function Watcher.beginManual()
    manual_until = os.time() + MANUAL_GRACE
    while reconnect_running_since and os.time() - reconnect_running_since < RECONNECT_INTERVAL do
        Stack.pause(1)
    end
end

-- Only once the script has finished: a dismissed message leaves it running,
-- and the deadline then keeps the watcher out until it is done.
function Watcher.endManual()
    manual_until = 0
end

-- Run on.sh in the background and log the outcome; the watcher connects
-- afterwards. Shared by startup, resume and the dead-controller recovery.
-- `why` finishes the log lines: "turned on at startup", "... on resume".
function Watcher.startInBackground(why)
    Trapper:wrap(function()
        Watcher.starting()
        local completed, result = Stack.run("on.sh", Stack.BACKGROUND())
        Watcher.started()
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
local function tryReconnect(names, quiet)
    local now = os.time()
    if now < manual_until then
        return  -- a connect or re-pair from the menu is running
    end
    if reconnect_running_since and now - reconnect_running_since < RECONNECT_INTERVAL then
        return  -- the previous attempt is still going
    end
    local interval = now < fast_until and RECONNECT_FAST or RECONNECT_INTERVAL
    if now - last_reconnect < interval then
        return
    end
    last_reconnect = now
    reconnect_running_since = now

    -- The tick is a plain timer callback rather than a coroutine, so this needs
    -- its own wrap. It runs in the BACKGROUND: nothing on screen, and nothing a
    -- tap on the reader can cancel.
    Trapper:wrap(function()
        local script = "connect.sh --no-repair"
        if names then
            script = script .. " " .. Stack.shellQuote(table.concat(names, "|"))
        end
        local completed, result = Stack.run(script, Stack.BACKGROUND())
        reconnect_running_since = nil

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
            if now_restart - last_restart >= RESTART_INTERVAL then
                last_restart = now_restart
                logger.info("Bluetooth: the controller is not responding; restarting Bluetooth")
                Watcher.startInBackground("after the controller stopped responding")
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

-- Notice the remote coming and going without a menu tap.
--
-- Pressing a button makes the remote re-advertise, and BlueZ reconnects it on
-- its own because repair.sh trusted it. The uhid device is recreated with
-- whatever event number happens to be free, so KOReader is left holding an fd
-- to a device that no longer exists -- connected, but dead, until "Refresh
-- Device Input" is tapped. Watching /proc closes that gap.
local function tick()
    watch_scheduled = false

    if os.time() < starting_until then
        -- on.sh is still bringing the stack up; see starting_until.
        Watcher.schedule()
        return
    end

    if Stack.isBluetoothOn() then
        local paths, present = Input.find()
        if #paths > 0 then
            Input.reconcile(paths)
            -- A remote is in use, but maybe not the first choice.
            local missing = Input.preferredMissing(present)
            if #missing > 0 then
                tryReconnect(missing, true)
            end
        else
            local open_paths = Input.openPaths()
            if #open_paths > 0 then
                -- The remote went away. Drop the handles instead of leaving
                -- them pointing at destroyed uhid devices until the next connect.
                logger.info("Bluetooth: watcher closing " .. table.concat(open_paths, ", ") ..
                            "; the remote is gone")
                Input.closeAll()
            end
            tryReconnect()
        end
    end

    Watcher.schedule()
end

-- Ticks even while Bluetooth is off, where the check costs two small sysfs
-- reads: a watcher that stops has to be started again from somewhere, and
-- that's one more thing to get wrong across the two plugin instances.
function Watcher.schedule()
    if watch_scheduled then
        return
    end
    watch_scheduled = true
    UIManager:scheduleIn(WATCH_INTERVAL, tick)
end

return Watcher
