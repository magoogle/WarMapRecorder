-- ---------------------------------------------------------------------------
-- Walkable-grid probe.
--
-- Calls utility.is_point_walkeable() against a regular grid of points around
-- the player every pulse, building up a sparse map of which cells are
-- walkable.  The host now has its own runtime pathfinder (used by
-- StaticPather), so this probe is no longer load-bearing for navigation --
-- but the live viewer still uses it to fill in the visual map as you walk.
--
-- Per-pulse cost: scans cells outward in Chebyshev rings from the player,
-- stops after probing N unprobed cells.  Idle short-circuit (handled in
-- recorder.lua) skips this entirely when the player isn't moving.
-- ---------------------------------------------------------------------------

local M = {}

-- Module state
local enabled          = false
local resolution       = 0.5      -- world units per cell
local probe_radius     = 25       -- world units; cap probing at this distance
local probes_per_pulse = 15       -- O(1) budget guard
local snap_height      = true

-- grids[floor] = { ["cx,cy"] = bool }    true = walkable, false = blocked
local grids = {}

-- Streaming callback.  recorder.lua wires this to write each newly-probed
-- cell straight to the NDJSON file.
local on_cell_cb = nil

-- Public setters / getters
M.set_enabled          = function (v) enabled = v and true or false end
M.set_resolution       = function (r) if type(r) == 'number' and r > 0 then resolution = r end end
M.set_radius           = function (r) if type(r) == 'number' and r > 0 then probe_radius = r end end
M.set_probes_per_pulse = function (n) if type(n) == 'number' and n > 0 then probes_per_pulse = math.floor(n) end end
M.set_snap_height      = function (v) snap_height = v and true or false end
M.set_on_cell          = function (fn) on_cell_cb = (type(fn) == 'function') and fn or nil end
M.get_resolution       = function () return resolution end
M.is_enabled           = function () return enabled end

-- Walk cells outward from (pcx, pcy) in increasing Chebyshev rings.
-- callback returns true to stop early.
local function for_each_cell_outward(pcx, pcy, max_ring, callback)
    if callback(pcx, pcy) then return end
    for r = 1, max_ring do
        for dx = -r, r do
            if callback(pcx + dx, pcy + r) then return end
            if callback(pcx + dx, pcy - r) then return end
        end
        for dy = -(r - 1), (r - 1) do
            if callback(pcx - r, pcy + dy) then return end
            if callback(pcx + r, pcy + dy) then return end
        end
    end
end

-- Probe up to probes_per_pulse unprobed cells around `pos`.  Cheap when
-- everything in radius is already cached.
M.probe_pulse = function (pos, floor)
    if not enabled then return end
    if not pos or not floor then return end
    if not utility or not utility.is_point_walkeable then return end

    grids[floor] = grids[floor] or {}
    local grid = grids[floor]

    local px, py, pz = pos:x(), pos:y(), pos:z()
    if snap_height and utility.set_height_of_valid_position then
        local ok, snapped = pcall(utility.set_height_of_valid_position,
            vec3:new(px, py, pz))
        if ok and snapped and snapped.z then
            pz = snapped:z()
        end
    end

    local pcx = math.floor(px / resolution + 0.5)
    local pcy = math.floor(py / resolution + 0.5)
    local max_ring = math.floor(probe_radius / resolution)

    -- Pulse budget split:
    --   probes_per_pulse        -- cells we've never seen before
    --   reprobes_per_pulse      -- cells previously observed as BLOCKED
    --                              that we re-check in case a transient
    --                              wall opened up (boss-room doors,
    --                              Hordes wave-end gates, etc.)
    -- Walkable cells are NEVER re-probed -- walls don't re-form into
    -- walkable space mid-session, so locking that observation in is fine.
    local reprobes_per_pulse = math.max(1, math.floor(probes_per_pulse / 2))
    local probed = 0
    local reprobed = 0
    for_each_cell_outward(pcx, pcy, max_ring, function (cx, cy)
        local k = cx .. ',' .. cy
        local prev = grid[k]
        if prev == true then return false end   -- cached walkable; never re-probe

        -- Budget exhausted on the appropriate channel?
        if prev == nil and probed >= probes_per_pulse then
            return reprobed >= reprobes_per_pulse   -- stop only if both budgets are spent
        end
        if prev == false and reprobed >= reprobes_per_pulse then
            return probed >= probes_per_pulse
        end

        local wx = cx * resolution
        local wy = cy * resolution
        local wpos = vec3:new(wx, wy, pz)
        local ok, walkable = pcall(utility.is_point_walkeable, wpos)
        local w_bool = (ok and walkable) and true or false

        if prev == nil then
            -- First sighting -- emit + count.
            grid[k] = w_bool
            if on_cell_cb then on_cell_cb(cx, cy, w_bool, floor) end
            probed = probed + 1
        else  -- prev == false
            reprobed = reprobed + 1
            if w_bool == true then
                -- BLOCKED -> WALKABLE upgrade.  This is the boss-door-
                -- opening case.  Emit so the merger receives the new vote;
                -- update local cache so we don't re-probe again.
                grid[k] = true
                if on_cell_cb then on_cell_cb(cx, cy, true, floor) end
            end
            -- Still blocked: leave cache as-is, no emit (free).
        end
        return probed >= probes_per_pulse and reprobed >= reprobes_per_pulse
    end)
end

M.reset = function () grids = {} end

return M
