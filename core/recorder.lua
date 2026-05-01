-- ---------------------------------------------------------------------------
-- Core recording loop. The active record's metadata lives in a module-level
-- `record` table; samples/events/cells/actors stream straight to disk via
-- core.stream_writer (which auto-flushes every 1s / 64 lines on its own).
-- A new record starts on activity_kind / zone / session transitions.
-- ---------------------------------------------------------------------------

local settings          = require 'core.settings'
local classifier        = require 'core.activity_classifier'
local flush             = require 'core.flush'
local grid_probe        = require 'core.grid_probe'
local actor_capture     = require 'core.actor_capture'
local quest_capture     = require 'core.quest_capture'
local stream_writer     = require 'core.stream_writer'
local uploader_launcher = require 'core.uploader_launcher'

-- Activity kinds that should record quest state.  Quest data is most
-- valuable in NMDs (variable objectives per sigil) but the same shape
-- ("active quest text describes the current goal") applies to seasonal
-- bounty / event-driven content too -- expand here when those need it.
-- Keeping this as a set rather than a single string so adding more
-- activity kinds is a one-line change.
local QUEST_CAPTURE_KINDS = {
    nmd = true,    -- nightmare dungeon (DGN_*) -- the headline use case
}

-- Cell resolution used by the merger when deriving walkable cells from
-- player position samples.  Recorded into each session header so the
-- merger always knows the grid the samples were taken on, even if we
-- later change the default.
local CELL_RESOLUTION_M = 0.5

local M = {}

-- Schema version we emit. Bump in sync with schema/record-v1.schema.json.
local SCHEMA_VERSION = 1

-- Loading-screen / nil-activity grace period (seconds).  Pit floor changes
-- briefly drop the player into '[sno none]' which the activity classifier
-- can't classify.  Without this, every floor becomes a separate record and
-- the floor counter resets to 1.  Keep the active record alive for this
-- long after activity goes nil; if it returns to the same kind we resume
-- the record seamlessly.
local LIMBO_GRACE_S = 30.0

-- Idle-skip heuristic.  Standing still produces no new information: cells
-- around the player are already in the probe cache, nearby actors haven't
-- moved, and additional samples just say "still at X".  When we detect the
-- player hasn't moved more than IDLE_THRESHOLD_M for IDLE_GRACE_S seconds we
-- short-circuit the heavy per-pulse work (grid probe + actor scan) and emit
-- a low-rate heartbeat sample so the trace still shows the dwell.
--   THRESHOLD_M  : footstep-wobble tolerance.  0.5m is one navmesh cell.
--   GRACE_S      : how long the player must be still before we kick in --
--                  short enough that brief stops (channeling, looting) don't
--                  pile up wasted work.
--   HEARTBEAT_S  : while idle, this is the gap between samples.
local IDLE_THRESHOLD_M = 0.5
local IDLE_GRACE_S     = 1.5
local IDLE_HEARTBEAT_S = 5.0

-- ---------------------------------------------------------------------------
-- State -- the active record's METADATA (header info), plus timing
-- bookkeeping. Samples/events/cells/actors stream to disk via stream_writer
-- on the fly; we keep only counts in memory for stats display.
-- ---------------------------------------------------------------------------
local record           = nil      -- header-only metadata (no sample/event arrays)
local sample_count     = 0
local event_count      = 0
local cell_count       = 0
local actor_count      = 0
-- Most recent sample's rounded x/y/z. Used as event-position fallback when
-- pp_valid isn't available (e.g., during a transient invalid-position frame).
local last_sample_x    = nil
local last_sample_y    = nil
local last_sample_z    = nil
local record_start_t   = -1       -- get_time_since_inject() when record started
local last_sample_t    = -1
local last_zone        = nil
local last_world       = nil
local last_world_id    = nil      -- world hash from get_world_id()
local last_activity    = nil
local last_floor_world = nil      -- for pit floor detection (keyed by world_id now)
local last_floor_idx   = 1
local last_buff_check_t = -1
local limbo_started_t  = nil

-- Teleport-based floor-change detection.  Some sub-areas (notably undercity
-- boss rooms) share the parent floor's world_id, so the world_id-change
-- branch alone misses them.  We compare the player's pulse-to-pulse
-- position; jumps larger than TELEPORT_THRESHOLD_M can only be teleports
-- (normal D4 movement caps at ~10m/s, sample interval is fractions of a
-- second, so consecutive samples are always <2m apart unless the world
-- snapped the player elsewhere).  Reset to nil at session start so the
-- first pulse never trips it.
--
-- Why 20m and not the original 50m: short-distance teleports (UC boss-
-- room entries via portal-switch click, pit floor portals between
-- close-spawned rooms) are typically 15-30m.  20m catches them while
-- still being well above the ~2m max for natural movement between
-- consecutive sample pulses.  False positives are still effectively
-- impossible -- no D4 movement primitive crosses 20m in <500ms.
local last_pulse_x      = nil
local last_pulse_y      = nil
local TELEPORT_THRESHOLD_M  = 20
local TELEPORT_THRESHOLD_M2 = TELEPORT_THRESHOLD_M * TELEPORT_THRESHOLD_M

-- Motion tracker for the idle-skip heuristic.  last_motion_x/y is the
-- position at the most recent "moved" pulse; last_motion_t is when that
-- happened.  We only update these when displacement exceeds IDLE_THRESHOLD_M
-- so the values define the stable "still" anchor we're idling against.
local last_motion_x    = nil
local last_motion_y    = nil
local last_motion_t    = -math.huge
-- Diagnostic: only print "entering idle" / "leaving idle" once per transition
-- (otherwise every pulse during a long AFK would spam the console).
local idle_logged      = false

-- ---------------------------------------------------------------------------
-- Pseudo-UUID. Don't pull in a uuid lib; we just need uniqueness within a
-- folder. time + random suffix works.
-- ---------------------------------------------------------------------------
local function gen_session_id()
    math.randomseed(os.time() + math.floor((get_time_since_inject() or 0) * 1000))
    local hex = '0123456789abcdef'
    local id = {}
    for i = 1, 24 do
        id[i] = hex:sub(math.random(1, 16), math.random(1, 16))
    end
    return tostring(os.time()) .. '-' .. table.concat(id)
end

-- ---------------------------------------------------------------------------
-- Player position helper.  Returns vec or nil.  Treats (0,0,0) as "loading
-- screen / dead state" -- those samples corrupt the path.
-- ---------------------------------------------------------------------------
-- Reject "near origin" too -- the host sometimes returns positions a
-- fraction off (0, 0, 0) during teleports / loading transitions, and
-- we never legitimately stand at world origin in D4.  Without this
-- filter, the grid probe writes hundreds of garbage cells around (0,0)
-- which then skew the per-zone bbox.
local function valid_position(lp)
    if not lp or not lp.get_position then return nil end
    local pp = lp:get_position()
    if not pp then return nil end
    local x = pp:x() or 0
    local y = pp:y() or 0
    local z = pp:z() or 0
    -- Within 5m of world (0, 0): treat as bogus placeholder.  Real D4
    -- maps are far from origin (Cerrigar ~ -1670, -610 etc).
    if (x*x + y*y) < 25 then return nil end
    if x == 0 and y == 0 and z == 0 then return nil end
    return pp
end

-- ---------------------------------------------------------------------------
-- Start a new record. Opens the stream file, writes the header line, and
-- wires grid/actor callbacks so newly-discovered cells/actors stream
-- straight to disk (no in-memory buffer beyond the dedup index).
-- ---------------------------------------------------------------------------
local function start_record(activity_kind, zone, world, world_id)
    local now = os.time()
    record = {
        schema_version = SCHEMA_VERSION,
        activity_kind  = activity_kind,
        zone           = zone or '',
        world          = world or '',
        world_id       = world_id or 0,
        game_patch     = '',
        session_id     = gen_session_id(),
        started_at     = now,
        ended_at       = now,
    }
    record_start_t   = get_time_since_inject() or 0
    last_sample_t    = -1
    last_floor_world = world_id    -- floor detection keys off world_id
    last_floor_idx   = 1
    limbo_started_t  = nil
    last_motion_x    = nil
    last_motion_y    = nil
    last_motion_t    = -math.huge
    last_pulse_x     = nil
    last_pulse_y     = nil
    idle_logged      = false
    sample_count     = 0
    event_count      = 0
    cell_count       = 0
    actor_count      = 0
    grid_probe.reset()
    actor_capture.reset()
    quest_capture.reset()

    -- Quest capture: enable for activity kinds that benefit (NMDs at the
    -- moment).  Take an initial snapshot here so the dump's header
    -- carries the quest list active at session start -- a sibling plugin
    -- reading the dump can correlate "at t=0 quest X was active" with
    -- the actor entries observed during the run.
    local capture_quests = QUEST_CAPTURE_KINDS[activity_kind] == true
    quest_capture.set_enabled(capture_quests)
    local initial_quests = capture_quests and quest_capture.initial_snapshot() or nil

    -- Note: we always capture, regardless of how much the server thinks
    -- it knows about this zone.  The server-side merger decides coverage;
    -- the recorder just streams whatever it sees, so missing pieces can
    -- still be filled in by anyone's session.

    -- Open stream + write header line.  initial_quests is omitted for
    -- non-NMD records so unrelated dump types don't grow a perpetually-
    -- empty field.
    local path = (flush.dump_dir or '.') .. '\\' .. record.session_id .. '.ndjson'
    local header = {
        type              = 'header',
        schema_version    = record.schema_version,
        session_id        = record.session_id,
        activity_kind     = record.activity_kind,
        zone              = record.zone,
        world             = record.world,
        world_id          = record.world_id,
        game_patch        = record.game_patch,
        started_at        = record.started_at,
        cell_resolution_m = CELL_RESOLUTION_M,
    }
    if initial_quests then header.initial_quests = initial_quests end
    local ok = stream_writer.start_session(path, header)
    if not ok then
        console.print('[WarMapRecorder] FAILED to open stream for ' .. tostring(path))
    end

    -- Wire grid_probe to stream cells as they're discovered.  Keeps the
    -- live viewer's "fill in around me" behavior; sample-only mode only
    -- gives a thin trail of actually-walked cells.
    grid_probe.set_on_cell(function (cx, cy, w_bool, floor)
        cell_count = cell_count + 1
        stream_writer.append({
            type  = 'grid_cell',
            floor = floor,
            cx    = cx, cy = cy,
            w     = w_bool and 1 or 0,
            res   = grid_probe.get_resolution(),
        })
    end)

    -- Wire actor_capture to stream new actors on first sighting.
    actor_capture.set_on_new_actor(function (entry)
        actor_count = actor_count + 1
        -- Shallow copy with type tag so consumer knows how to interpret the line
        local out = { type = 'actor' }
        for k, v in pairs(entry) do out[k] = v end
        stream_writer.append(out)
    end)

    console.print(string.format(
        '[WarMapRecorder] NEW RECORD activity=%s zone=%s world=%s world_id=%s session=%s',
        tostring(activity_kind), tostring(zone), tostring(world),
        tostring(world_id), record.session_id))
end

-- ---------------------------------------------------------------------------
-- Finalize the active record and flush to disk.
-- ---------------------------------------------------------------------------
-- Finalize: write footer + close stream. Counts come from the in-memory
-- counters bumped by append_sample/append_event/etc.
local function finalize_record(reason)
    if not record then return end
    record.ended_at = os.time()
    stream_writer.end_session({
        type     = 'footer',
        ended_at = record.ended_at,
        reason   = reason,
        samples  = sample_count,
        events   = event_count,
        cells    = cell_count,
        actors   = actor_count,
    })
    console.print(string.format(
        '[WarMapRecorder] FINALIZED %s samples=%d events=%d cells=%d actors=%d reason=%s',
        record.session_id, sample_count, event_count, cell_count, actor_count,
        tostring(reason)))
    record          = nil
    record_start_t  = -1
    limbo_started_t = nil
    sample_count    = 0
    event_count     = 0
    cell_count      = 0
    actor_count     = 0
    grid_probe.reset()
    actor_capture.reset()
    quest_capture.reset()
end

-- ---------------------------------------------------------------------------
-- Time-since-record-start, with 0.01s precision.  Used for sample/event `t`.
-- ---------------------------------------------------------------------------
local function rel_t(now)
    local dt = now - (record_start_t < 0 and now or record_start_t)
    if dt < 0 then dt = 0 end
    return math.floor(dt * 100 + 0.5) / 100
end

-- ---------------------------------------------------------------------------
-- Append helpers.
-- ---------------------------------------------------------------------------
local function append_sample(now, pp)
    if not record then return end
    local x = math.floor(pp:x() * 10 + 0.5) / 10
    local y = math.floor(pp:y() * 10 + 0.5) / 10
    local z = math.floor(pp:z() * 10 + 0.5) / 10
    last_sample_x, last_sample_y, last_sample_z = x, y, z
    local sample = {
        type = 'sample',
        t    = rel_t(now),
        x    = x, y = y, z = z,
    }
    if record.activity_kind == 'helltide' then
        if get_helltide_coin_cinders then
            sample.cinders = get_helltide_coin_cinders() or 0
        end
        sample.in_helltide = true
    end
    if record.activity_kind == 'pit' then
        sample.floor = last_floor_idx
    end
    sample_count = sample_count + 1
    stream_writer.append(sample)
end

local function append_event(now, kind, payload, pp)
    if not record then return end
    local event = {
        type = 'event',
        t    = rel_t(now),
        kind = kind,
    }
    if pp then
        event.x = math.floor(pp:x() * 10 + 0.5) / 10
        event.y = math.floor(pp:y() * 10 + 0.5) / 10
        event.z = math.floor(pp:z() * 10 + 0.5) / 10
    elseif last_sample_x then
        event.x = last_sample_x
        event.y = last_sample_y
        event.z = last_sample_z
    end
    -- Stamp the floor index for pit activity so the viewer can filter
    -- events per-floor. floor_change events keep the OLD floor as their
    -- own .floor (they happened on the floor we're leaving) and the new
    -- floor lives in metadata.to_floor.
    if record.activity_kind == 'pit' then
        if kind == 'floor_change' and payload and payload.metadata
           and payload.metadata.from_floor then
            event.floor = payload.metadata.from_floor
        else
            event.floor = last_floor_idx
        end
    end
    if payload then
        for k, v in pairs(payload) do event[k] = v end
    end
    event_count = event_count + 1
    stream_writer.append(event)
end

-- ---------------------------------------------------------------------------
-- Pulse: called from main.lua's on_update at game framerate.
-- O(1) per pulse.  The streaming writer's flush is amortized -- it batches
-- in memory and writes when buffer reaches 64 lines or 1s elapses, whichever
-- comes first, so per-pulse cost stays bounded.
-- ---------------------------------------------------------------------------
-- Watcher health-check.  We don't rely on rising-edge alone -- the module
-- state survives across game-load cycles, so booting into a new game with
-- the recorder already enabled used to silently never launch the watcher.
-- Instead we periodically poll: while enabled, ask the launcher to spawn
-- if no fresh lockfile is detected.  The launcher itself is cheap (one
-- file read per call) and rate-limits via its own 5s cooldown.
local _watcher_check_t = -math.huge
local WATCHER_CHECK_INTERVAL_S = 15

M.pulse = function ()
    if not settings.enabled then
        if record then finalize_record('disabled') end
        return
    end

    -- Watcher health: try-launch when (a) lockfile is missing/stale, AND
    -- (b) we haven't checked in the last WATCHER_CHECK_INTERVAL_S.
    -- Cheap: launcher's own check returns 'already_running' on a fresh
    -- lockfile, so most calls are no-ops.
    local nowt = (get_time_since_inject and get_time_since_inject()) or 0
    if (nowt - _watcher_check_t) > WATCHER_CHECK_INTERVAL_S then
        _watcher_check_t = nowt
        if uploader_launcher.has_config() then
            uploader_launcher.try_launch()
        end
    end

    local lp = get_local_player()
    if not lp then
        -- No player handle: stay in limbo grace, don't kill the record yet.
        if record and not limbo_started_t then
            limbo_started_t = get_time_since_inject() or 0
        end
        return
    end

    local now = get_time_since_inject() or 0
    local pp_valid = valid_position(lp)   -- nil during loading screens / dead

    -- Activity classification (cheap; helltide buff check is the most expensive
    -- piece, throttled to 0.5s).
    local activity, zone, world, world_id
    if (now - last_buff_check_t) > 0.5 then
        last_buff_check_t = now
        activity = classifier.classify()
        local w = get_current_world()
        zone     = w and w.get_current_zone_name and w:get_current_zone_name() or nil
        world    = w and w.get_name and w:get_name() or nil
        world_id = w and w.get_world_id and w:get_world_id() or nil
    else
        activity, zone, world, world_id = last_activity, last_zone, last_world, last_world_id
    end

    -- Always log transitions (zone or world_id) so the user can see exactly
    -- what the API is reporting when they walk between areas.
    if zone ~= last_zone or world_id ~= last_world_id then
        console.print(string.format(
            '[WarMapRecorder] zone/world transition: zone %s -> %s, world_id %s -> %s, world=%s',
            tostring(last_zone), tostring(zone),
            tostring(last_world_id), tostring(world_id),
            tostring(world)))
    end

    -- ---------------------------------------------------------------------
    -- Zone-driven transition logic.
    --
    -- A "record" covers exactly one zone. Going PIT -> Skov_Temis splits
    -- into two records. Going pit-floor-1 -> pit-floor-2 stays in one
    -- record because zone is 'PIT_Subzone' on every floor (only world
    -- name changes -- that's our floor signal).
    --
    -- '[sno none]' is the loading-screen sentinel; we enter limbo grace
    -- and freeze sampling/probing until a real zone returns. If the new
    -- zone matches the record's zone we resume; otherwise we finalize
    -- and start fresh for the new zone.
    -- ---------------------------------------------------------------------
    local in_limbo = (zone == nil) or (zone == '[sno none]')

    if record then
        if in_limbo then
            if not limbo_started_t then
                limbo_started_t = now
                if settings.debug_mode then
                    console.print('[WarMapRecorder] entered limbo (grace ' ..
                        tostring(LIMBO_GRACE_S) .. 's)')
                end
            end
            if (now - limbo_started_t) > LIMBO_GRACE_S then
                if settings.debug_mode then
                    console.print(string.format(
                        '[WarMapRecorder] limbo expired (%.1fs > %.1fs), finalizing',
                        now - limbo_started_t, LIMBO_GRACE_S))
                end
                finalize_record('limbo_timeout')
            end
        elseif zone == record.zone then
            -- Same zone (possibly after a brief loading screen). Continue.
            -- world_id can change WITHIN a zone (pit floor transitions),
            -- so we don't gate on it here -- the floor detector below
            -- handles intra-zone world changes.
            if limbo_started_t then
                console.print('[WarMapRecorder] resumed ' .. record.activity_kind ..
                    ' (zone=' .. zone .. ', world_id=' .. tostring(world_id) ..
                    ') from limbo')
                limbo_started_t = nil
            end
            -- Floor detection for multi-floor activities (pit, undercity).
            -- Two signals, either of which advances the floor counter:
            --   1. world_id change (most pit floors, most undercity floors)
            --   2. position teleport > TELEPORT_THRESHOLD_M between pulses
            --      (undercity boss rooms share the parent floor's world_id;
            --      crossing into them is detectable only by the player
            --      snapping to a distant region of the level layout)
            -- Both signals are gated on not being mid-Limbo (loading screen)
            -- so we don't fire spurious floor changes during normal zone
            -- transitions.
            if classifier.is_multi_floor(record.activity_kind)
               and (not world or not world:find('Limbo', 1, true))
            then
                local detected_via = nil
                if world_id and world_id ~= last_floor_world then
                    detected_via = 'world_id'
                elseif world and last_world and world ~= last_world then
                    -- World _name_ changed even though world_id didn't.
                    -- Some UC dungeon variants reuse a world_id across
                    -- a hub + boss-room pair but name them differently
                    -- (e.g. X1_Undercity_BugCave vs X1_Undercity_BugCave_Boss).
                    detected_via = 'world_name'
                elseif pp_valid and last_pulse_x and last_pulse_y then
                    local dx = pp_valid:x() - last_pulse_x
                    local dy = pp_valid:y() - last_pulse_y
                    if (dx*dx + dy*dy) > TELEPORT_THRESHOLD_M2 then
                        detected_via = 'teleport'
                    end
                end
                if detected_via then
                    local prev_world = last_world
                    last_floor_idx = last_floor_idx + 1
                    last_floor_world = world_id
                    append_event(now, 'floor_change', {
                        metadata = {
                            from_floor    = last_floor_idx - 1,
                            to_floor      = last_floor_idx,
                            from_world    = prev_world,
                            to_world      = world,
                            to_world_id   = world_id,
                            detected_via  = detected_via,
                        },
                    }, pp_valid)
                    console.print(string.format(
                        '[WarMapRecorder] floor change %d -> %d via %s (world=%s, world_id=%s)',
                        last_floor_idx - 1, last_floor_idx, detected_via,
                        tostring(world), tostring(world_id)))
                end
            end
        else
            -- Different zone -> close out and start fresh.
            console.print(string.format(
                '[WarMapRecorder] SPLIT: zone %s -> %s (world_id %s -> %s)',
                tostring(record.zone), tostring(zone),
                tostring(record.world_id), tostring(world_id)))
            finalize_record('zone_change')
            if settings.auto_start and activity then
                start_record(activity, zone, world, world_id)
            end
        end
    else
        -- No record. Start one if we're in a recordable zone.
        if settings.auto_start and activity and not in_limbo then
            start_record(activity, zone, world, world_id)
        end
    end

    last_zone = zone
    -- last_world deliberately NOT updated when the host briefly reports
    -- a Limbo world (loading screen between two same-world-id rooms,
    -- common in undercity sub-area portals).  Without this guard,
    -- entering Limbo set last_world='Limbo*', and on the next pulse
    -- when the host swung back to the real world name the comparison
    -- `world ~= last_world` fired a spurious floor_change with
    -- via='world_name' -- even though world_id never changed.  Result:
    -- same-world-id rooms (BugCave_03 hub vs BugCave_03 boss room
    -- reached via portal) ended up tagged as different floor numbers,
    -- which the server-side merger then collapsed back into one
    -- bucket because the world_id was identical.  Preserving the last
    -- "real" world name through Limbo periods makes the post-Limbo
    -- comparison stable, and the teleport-distance branch still picks
    -- up legitimate same-world-id room jumps via the >20m position
    -- heuristic.
    if world and not world:find('Limbo', 1, true) then
        last_world = world
    end
    last_world_id = world_id
    last_activity = activity
    -- Track pulse-to-pulse position for the teleport-based floor detector.
    -- Only update when we have a valid position; in-limbo pulses leave the
    -- previous good position in place so the comparison after limbo
    -- correctly catches the post-load teleport (boss-room snap-in).
    if pp_valid then
        last_pulse_x = pp_valid:x()
        last_pulse_y = pp_valid:y()
    end

    if not record then return end
    -- Freeze sampling + probing while in limbo (loading screen / no player).
    if in_limbo or limbo_started_t then return end

    -- ---------------------------------------------------------------------
    -- Idle detection.  Compare current pp_valid against the last "motion
    -- anchor" (the position we last considered the player to be moving at).
    -- If displacement >= IDLE_THRESHOLD_M, refresh the anchor and we're
    -- moving.  Otherwise, if it's been longer than IDLE_GRACE_S since we
    -- last refreshed the anchor, we're idle and skip the expensive work.
    -- ---------------------------------------------------------------------
    local is_idle = false
    if pp_valid then
        local px, py = pp_valid:x(), pp_valid:y()
        if last_motion_x == nil then
            last_motion_x, last_motion_y, last_motion_t = px, py, now
        else
            local dx = px - last_motion_x
            local dy = py - last_motion_y
            -- Cheap squared-distance check; sqrt only when needed.
            if (dx * dx + dy * dy) >= (IDLE_THRESHOLD_M * IDLE_THRESHOLD_M) then
                last_motion_x, last_motion_y, last_motion_t = px, py, now
                if idle_logged then
                    if settings.debug_mode then
                        console.print('[WarMapRecorder] motion resumed')
                    end
                    idle_logged = false
                end
            elseif (now - last_motion_t) >= IDLE_GRACE_S then
                is_idle = true
                if not idle_logged then
                    if settings.debug_mode then
                        console.print(string.format(
                            '[WarMapRecorder] idle (still for %.1fs) -- skipping probe/actors',
                            now - last_motion_t))
                    end
                    idle_logged = true
                end
            end
        end
    end

    -- Sampling.
    --   Moving      : every 1/sample_hz seconds (default 5 Hz)
    --   Idle        : one heartbeat every IDLE_HEARTBEAT_S seconds
    --   No position : skip
    local sample_interval = is_idle
        and IDLE_HEARTBEAT_S
        or  (1.0 / math.max(settings.sample_hz or 5, 1))
    if pp_valid and (now - last_sample_t) >= sample_interval then
        last_sample_t = now
        append_sample(now, pp_valid)
    end

    -- Walkable-grid probe.  The host's calculate_path() handles actual
    -- in-game navigation, but the live viewer needs the explored area
    -- filled in around the player as they walk -- sample-only data only
    -- gives a thin trail.  Idle short-circuit means we don't spend cycles
    -- when the player isn't moving.
    grid_probe.set_enabled(pp_valid ~= nil and not is_idle)
    if pp_valid and grid_probe.is_enabled() then
        local floor_for_probe = classifier.is_multi_floor(record.activity_kind)
            and last_floor_idx or 1
        grid_probe.probe_pulse(pp_valid, floor_for_probe)
    end

    -- Actor capture: unconditional w.r.t. server-side saturation.
    -- Skip only while idle (nearby actors don't relocate while still).
    actor_capture.set_enabled(settings.capture_actors and not is_idle)
    actor_capture.set_scan_interval(settings.actor_scan_interval)
    if pp_valid and actor_capture.is_enabled() then
        local floor_for_actors = classifier.is_multi_floor(record.activity_kind)
            and last_floor_idx or 1
        actor_capture.scan_pulse(now, floor_for_actors, rel_t, record.world)
    end

    -- Quest capture: poll the host's active-quest list for changes and
    -- emit a quest_change event when it differs from the last
    -- snapshot.  Self-gated (does nothing unless set_enabled(true) at
    -- start_record), self-throttled (POLL_INTERVAL_S internally) so
    -- this stays effectively free on non-NMD activities and on NMD
    -- pulses where nothing changed.  We DON'T short-circuit on
    -- is_idle: a player standing in a boss room waiting for the
    -- objective to update should still have that update captured.
    if quest_capture.is_enabled() then
        local change = quest_capture.poll_pulse(now)
        if change then
            append_event(now, 'quest_change', {
                quests  = change.quests,
                added   = change.delta.added,
                removed = change.delta.removed,
            }, pp_valid)
            if settings.debug_mode then
                console.print(string.format(
                    '[WarMapRecorder] quest_change: +%d -%d (now %d active)',
                    #change.delta.added, #change.delta.removed, #change.quests))
            end
        end
    end

    -- Streaming writer auto-flushes every ~1s/64 lines on its own. We don't
    -- need a separate periodic flush here -- the previous design's "rewrite
    -- the whole record" pause is gone.
end

-- ---------------------------------------------------------------------------
-- Public API for hooking event sources from sibling plugins.
--   WarMapRecorderPlugin.note_event('chest_opened',
--       { actor='...', x=..., y=..., metadata={ cost=75 } })
-- If x/y aren't provided in the payload, we stamp the player's current
-- position (when valid).
-- ---------------------------------------------------------------------------
M.note_event = function (kind, payload)
    if not record then return false end
    local now = get_time_since_inject() or 0
    local pp = valid_position(get_local_player())
    -- If caller already provided x/y in payload, don't overwrite.
    if payload and payload.x and payload.y then
        append_event(now, kind, payload, nil)
    else
        append_event(now, kind, payload, pp)
    end
    return true
end

M.is_recording = function () return record ~= nil end
M.current = function () return record end
M.counts = function ()
    return {
        samples = sample_count,
        events  = event_count,
        cells   = cell_count,
        actors  = actor_count,
    }
end

-- Public read-only accessor for the most recent quest snapshot.  Sibling
-- plugins (the future nightmare runner / objective HUD) call this to
-- learn the active quest list without having to query the host directly
-- or parse the dump.  Returns the cached array of { id, name } or nil
-- when the recorder isn't capturing quests for the current activity.
M.current_quests = function () return quest_capture.current() end

return M
