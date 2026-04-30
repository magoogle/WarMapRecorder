-- ---------------------------------------------------------------------------
-- Auto-launch the WarMap uploader watcher.
--
-- The Python uploader is a separate process that ships completed dump files
-- to the central server and pulls back merged data.  When the user enables
-- the recorder, we want a watcher running -- otherwise their sessions just
-- pile up locally.  This module fires `start /MIN cmd /c python upload.py
-- --watch` once on the rising edge of `settings.enabled`.
--
-- Duplicate spawns are safe: the Python side acquires a lockfile on
-- startup; a second instance sees the lock, prints "another uploader
-- already running", and exits.  We additionally check the lockfile from
-- this side as a fast path so we don't spawn a process just to have it
-- exit immediately.
--
-- The launch is a one-shot `os.execute` per rising edge -- not a per-frame
-- cost.  `os.execute` is technically a blocking call but `start` returns
-- immediately, so the game thread sees roughly a single CreateProcess()
-- worth of work.  Throttled further by LAUNCH_COOLDOWN_S so a bouncy
-- enable/disable doesn't spam launches.
-- ---------------------------------------------------------------------------

local M = {}

-- Read once at module load.  If the installer hasn't written
-- uploader_config.lua, auto-launch is silently disabled.
local cfg = nil

-- ---------------------------------------------------------------------------
-- Find <scripts>/WarMapData/uploader_config.lua relative to package.path,
-- which QQT sets to "<scripts>/<plugin>/?.lua;..." while loading us.
-- ---------------------------------------------------------------------------
local function find_config_path()
    local first = (package.path or ''):match('([^;]+)')
    if not first then return nil end
    -- Strip "?.lua" suffix to get the plugin dir, then strip the plugin dir
    -- name to get scripts/.
    local plugin_dir = first:match('(.-)%?')
    if not plugin_dir or plugin_dir == '' then return nil end
    -- plugin_dir ends in "...\WarMapRecorder\".  Walk up one level.
    local scripts_dir = plugin_dir:match('^(.*[\\/])[^\\/]+[\\/]$')
    if not scripts_dir then return nil end
    return scripts_dir .. 'WarMapData' .. '\\' .. 'uploader_config.lua'
end

local function load_config()
    local path = find_config_path()
    if not path then return nil, 'no_config_path' end
    local f = io.open(path, 'r')
    if not f then return nil, 'no_config_file:' .. path end
    f:close()
    local chunk, err = loadfile(path)
    if not chunk then return nil, 'load_error:' .. tostring(err) end
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= 'table' then
        return nil, 'eval_error:' .. tostring(result)
    end
    return result
end

cfg = (function ()
    local c, err = load_config()
    if not c then
        console.print('[uploader_launcher] config not loaded (' .. tostring(err) .. ')')
    end
    return c
end)()

-- ---------------------------------------------------------------------------
-- Throttling.  After a spawn, refuse to spawn again for COOLDOWN seconds
-- regardless of what the lockfile looks like.  Why so long?
--
-- Python startup (cmd.exe -> python.exe -> import requests -> acquire lock)
-- can take 5-10 seconds on a cold cache.  The previous 5s cooldown meant
-- the recorder's 15s poll loop could see a "no fresh lockfile yet" state
-- after a fresh spawn, decide the watcher is dead, and spawn another.
-- The Python side's atomic O_EXCL would catch the duplicate at lock-claim
-- time and the second python would exit, but the user still saw the
-- python.exe flicker into existence every poll cycle.
--
-- 30s is generous enough that any real watcher startup completes in time.
-- If a watcher genuinely crashes mid-startup (rare), we wait one extra
-- 15s poll cycle before relaunching -- acceptable cost for not spamming
-- spawns.
-- ---------------------------------------------------------------------------
local LAUNCH_COOLDOWN_S = 30
local last_launch_t     = -math.huge

-- ---------------------------------------------------------------------------
-- Lockfile freshness check.  The Python side writes 'pid\nts' and
-- refreshes the timestamp every 30s.  If the embedded ts is recent we
-- assume a watcher is alive; otherwise it's an orphan from a previous
-- run and we should spawn a fresh one.  This is what makes "boot into a
-- new game with the recorder already enabled" work: the watcher process
-- from the previous game is dead, its lockfile is stale, the recorder
-- detects that and re-launches.
-- ---------------------------------------------------------------------------
local LOCK_FRESH_WINDOW_S = 90   -- match the Python side's LOCK_STALE_S

local function watcher_seems_alive()
    if not cfg or not cfg.sidecar_dir then return false end
    local lock_path = cfg.sidecar_dir .. '\\uploader.lock'
    local f = io.open(lock_path, 'r')
    if not f then return false end          -- no lockfile -> no watcher
    local content = f:read('*a') or ''
    f:close()
    -- Lockfile format (post-upgrade): 'pid\nts'.  Older format was just
    -- 'pid' with no timestamp.  If we can't extract a timestamp, treat
    -- the lock as STALE (not "be conservative, assume alive") -- being
    -- conservative was a footgun: a dead old-format lock would block
    -- new-format watchers from ever launching.
    local ts = tonumber(content:match('\n(%d+)')) or 0
    if ts == 0 then return false end        -- pre-upgrade lock = stale
    local age = os.time() - ts
    return age < LOCK_FRESH_WINDOW_S
end

-- ---------------------------------------------------------------------------
-- Map a python interpreter path to its pythonw sibling.  pythonw.exe is
-- the GUI-subsystem launcher that ships alongside python.exe in every
-- modern CPython install -- runs the same code but with no allocated
-- console.  When the user has Python on PATH as a bare 'python', the
-- bare 'pythonw' is also on PATH.  When uploader_config.lua specifies
-- a full path like 'C:\Python\python.exe', we swap the basename.
-- ---------------------------------------------------------------------------
local function to_pythonw(p)
    if not p or p == '' then return 'pythonw' end
    if p == 'python'     then return 'pythonw' end
    if p == 'python.exe' then return 'pythonw.exe' end
    local pw = p:gsub('python%.exe$', 'pythonw.exe'):gsub('python$', 'pythonw')
    return pw
end

-- ---------------------------------------------------------------------------
-- Public: try to launch the uploader watcher.  Returns (true, reason) if a
-- launch was attempted, (false, reason) otherwise.  Cheap to call
-- repeatedly thanks to the cooldown gate -- O(1) when nothing happens.
-- ---------------------------------------------------------------------------
M.try_launch = function ()
    -- INTENTIONAL NO-SPAWN.  The uploader watcher is now started by a
    -- Windows scheduled task at user logon (registered by install.ps1)
    -- and runs as a long-lived hidden pythonw process.  Lua never
    -- spawns a watcher anymore -- doing so would force os.execute to
    -- allocate a cmd.exe child, which flashes a console window briefly
    -- regardless of the /B + pythonw flags we pass it.
    --
    -- This function stays as a status probe: callers can use
    -- watcher_seems_alive() via M.is_alive() to decide whether to
    -- show a "watcher offline" warning.  No relaunch from here.
    if not cfg then return false, 'no_config' end
    if watcher_seems_alive() then
        return false, 'already_running'
    end
    -- Watcher isn't responding -- log it once per cooldown window so
    -- we don't spam the console, but don't try to restart.  The user
    -- can manually start it (Task Scheduler -> WarMap Uploader -> Run)
    -- or fix whatever broke it.
    local now = (get_time_since_inject and get_time_since_inject()) or os.time()
    if (now - last_launch_t) >= LAUNCH_COOLDOWN_S then
        last_launch_t = now
        if console and console.print then
            console.print(
                '[uploader_launcher] WATCHER OFFLINE: no fresh lockfile ' ..
                '(checked ' .. (cfg.sidecar_dir or '?') .. '\\uploader.lock).  ' ..
                'Sessions are queuing locally; start the WarMap Uploader ' ..
                'task in Task Scheduler to flush them.')
        end
    end
    return false, 'no_spawn_from_lua'
end


-- ---------------------------------------------------------------------------
-- Public: is auto-launch usable on this install?
-- ---------------------------------------------------------------------------
M.has_config = function () return cfg ~= nil end
M.config     = function () return cfg end

return M
