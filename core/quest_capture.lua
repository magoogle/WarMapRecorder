-- ---------------------------------------------------------------------------
-- Quest capture.
--
-- For nightmare-dungeon (DGN_*) zones, snapshot the host's active-quest list
-- and emit changes into the recording.  Other plugins (a future nightmare
-- runner, or a generic objective HUD) read this either:
--   * live  : via WarMapRecorderPlugin.current_quests()
--   * post  : by walking the dump's quest_change events / header.initial_quests
--
-- Why bother?  In NMDs the quest text describes the current objective
-- ("Slay the Sigil Bearer", "Defeat all monsters", "Activate the Beacon").
-- Pairing the active quest name with the actors visible at that moment
-- tells us which actor SNOs are objectives for which quest -- data we
-- can use to auto-route to the right interactable without hardcoding
-- per-dungeon tables.
--
-- Cost: get_quests() is host-cached, each pulse is O(N quests) which is
-- typically <10.  Throttled internally to POLL_INTERVAL_S so it isn't
-- per-frame work.
-- ---------------------------------------------------------------------------

local M = {}

-- Throttle the host poll.  NMD quests change at session boundaries and
-- on big progression beats (boss spawn, door unlock) -- 0.5s is plenty
-- of resolution and keeps the snapshot work off the framerate hot path.
local POLL_INTERVAL_S = 0.5

local enabled       = false
local last_poll_t   = -math.huge
local last_snapshot = nil    -- sorted array of { id, name }
local last_change_t = -math.huge

-- Read one host quest into a plain Lua table.  Tolerates missing methods
-- (some hosts ship a stub that lacks get_id / get_name) -- we just skip
-- the entry rather than letting an exception kill the pulse.
local function read_quest(q)
    if not q then return nil end
    local id   = q.get_id   and q:get_id()   or nil
    local name = q.get_name and q:get_name() or nil
    if not id then return nil end
    return { id = id, name = name and tostring(name) or '?' }
end

-- Pull the host's current quest list as a sorted-by-id array of
-- { id, name } tables.  Returns nil iff the host doesn't expose
-- get_quests() at all (e.g. during loading screens, or on hosts that
-- never implemented the call).  Returns {} for "no quests active".
local function snapshot()
    if not get_quests then return nil end
    local ok, raw = pcall(get_quests)
    if not ok or type(raw) ~= 'table' then return nil end
    local out = {}
    for _, q in pairs(raw) do
        local entry = read_quest(q)
        if entry then out[#out + 1] = entry end
    end
    -- Stable order so diffs against later snapshots are reproducible.
    table.sort(out, function (a, b) return a.id < b.id end)
    return out
end

-- True iff a and b describe different quest lists.  Both nil => false
-- (no change).  One nil + one non-nil => true (transitioned in/out
-- of "host knows quests").
local function differs(a, b)
    if a == nil and b == nil then return false end
    if a == nil or  b == nil then return true  end
    if #a ~= #b then return true end
    for i = 1, #a do
        if a[i].id ~= b[i].id or a[i].name ~= b[i].name then
            return true
        end
    end
    return false
end

-- Build a diagnostic delta { added=[...], removed=[...] } between two
-- snapshots.  Useful as event payload so a downstream consumer can see
-- what specifically changed without having to diff arrays themselves.
local function delta_of(prev, cur)
    local d = { added = {}, removed = {} }
    local prev_ids, cur_ids = {}, {}
    if prev then for _, q in ipairs(prev) do prev_ids[q.id] = q end end
    if cur  then for _, q in ipairs(cur)  do cur_ids[q.id]  = q end end
    for id, q in pairs(cur_ids) do
        if not prev_ids[id] then d.added[#d.added + 1] = q end
    end
    for id, q in pairs(prev_ids) do
        if not cur_ids[id] then d.removed[#d.removed + 1] = q end
    end
    return d
end

-- ---------------------------------------------------------------------------
-- Public API.
-- ---------------------------------------------------------------------------
M.set_enabled = function (v) enabled = v and true or false end
M.is_enabled  = function () return enabled end

-- Force-snapshot at session start; bypasses throttling and resets
-- diff state.  Returns the captured array (or nil if API unavailable).
M.initial_snapshot = function ()
    last_snapshot = snapshot()
    last_change_t = -math.huge
    last_poll_t   = -math.huge
    return last_snapshot
end

-- Pulse-driven check.  When the quest list has changed since the last
-- successful poll, returns
--    { quests = <new full snapshot>, delta = { added, removed } }
-- so the caller can emit a single quest_change event with both the
-- full state (for late readers) and the diff (for change-driven
-- consumers).  Otherwise returns nil.  Throttled internally to
-- POLL_INTERVAL_S; cheap to call every pulse.
M.poll_pulse = function (now)
    if not enabled then return nil end
    if (now - last_poll_t) < POLL_INTERVAL_S then return nil end
    last_poll_t = now
    local cur = snapshot()
    if not differs(cur, last_snapshot) then return nil end
    local d = delta_of(last_snapshot, cur)
    last_snapshot = cur
    last_change_t = now
    return { quests = cur, delta = d }
end

-- Latest cached snapshot.  Live consumers (WarMapRecorderPlugin.current_quests)
-- read this without forcing a fresh poll.
M.current = function () return last_snapshot end

-- Reset between records so a fresh session starts with no carried-over
-- diff state.  Called by recorder.lua's finalize/start_record path.
M.reset = function ()
    last_snapshot = nil
    last_change_t = -math.huge
    last_poll_t   = -math.huge
end

return M
