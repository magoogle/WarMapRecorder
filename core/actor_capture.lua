-- ---------------------------------------------------------------------------
-- Actor capture.
--
-- Periodically iterates actors_manager:get_all_actors(), filters to
-- interactable + categorised actors (chests, doors, portals, traversals,
-- shrines, NPCs, quest objectives), dedups by skin+rounded-position, and
-- accumulates a sparse map of "where is everything" per zone.
--
-- Walls and decorative props don't show up here -- those come from the
-- walkable-grid probe in core.grid_probe.lua.
--
-- Per-floor (pit floors get separate entries even if positions overlap).
-- ---------------------------------------------------------------------------

local M = {}

-- Settings (set by recorder from settings.update_settings each pulse).
local enabled         = false
local scan_interval_s = 2.0
local pos_grid        = 1.0      -- dedup positions to nearest 1m

-- Output: array of entries
--   { skin, kind, x, y, z, floor, first_t, last_t, samples, last_interactable }
-- We store entries indexed by dedup key too, so updating an existing entry
-- on re-scan is O(1).
local entries = {}        -- array
local index   = {}        -- key -> entries[i]
local last_scan_t = -math.huge

-- Per-skin caches for the two hot-path classifiers.  Without these,
-- `ignored(skin)` was a linear scan over ~35 substring patterns and
-- `classify(skin, world_name)` was a linear scan over ~25 categories
-- with multiple patterns each -- run for every actor every scan, in
-- a 200-actor zone that's 5k-7k string.find calls every 2s.  With
-- caches these become O(1) lookups; first-sighting still pays the
-- real cost but subsequent encounters of the same skin are free.
--
-- Cache keys are bare skin strings.  classify() additionally depends
-- on world_name (Portal_Dungeon_* means different things in PIT vs
-- non-PIT worlds), so the classify cache gets dropped when the world
-- changes -- in practice once per session.
local _ignored_cache  = {}      -- skin -> bool (true = ignored)
local _classify_cache = {}      -- skin -> kind string OR false (no match)
local _classify_world = nil

-- Eviction state.  Long sessions (hour-plus helltide grinds, multi-pit
-- runs) can accumulate thousands of distinct actor entries; the index
-- table itself stays O(1) for lookups but the GC has to walk every
-- live entry on each cycle, which lengthens GC pause times the longer
-- a session runs.  The fix: periodically drop entries we haven't seen
-- in N minutes.  When a previously-evicted actor reappears we just
-- re-emit it; the server-side merger dedups across sessions anyway.
local last_evict_t       = -math.huge
local EVICT_MIN_INTERVAL = 60       -- seconds wall-clock between sweeps
local EVICT_MIN_ENTRIES  = 2000     -- only sweep if catalog exceeds this
local EVICT_STALE_AGE    = 300      -- seconds since last_t before drop

-- Callback invoked when a NEW actor (skin+pos+floor) is discovered. Used by
-- the recorder to stream actor entries to disk on first sighting instead of
-- buffering the whole map until flush.
local on_new_actor_cb = nil

-- ---------------------------------------------------------------------------
-- Skin -> kind classification.
--
-- Order matters: more specific patterns must come first. An actor's skin
-- is matched against pattern_list[i] in order; first match wins.
-- ---------------------------------------------------------------------------
local CATEGORIES = {
    -- Multi-floor traversal points (cliffs, ropes, jumps)
    { kind = 'traversal',   patterns = { 'Traversal_' } },

    -- Event-doors / firewalls / boss-fight barriers.  These are the
    -- transient gates that close off an arena while a boss fight is
    -- active and re-open afterward.  Without their own kind they used
    -- to land in the catch-all 'interactable' bucket which made boss
    -- arenas look like big black boxes in the viewer (the recorder
    -- can't sample walkable cells through a closed firewall, so the
    -- arena interior has no data; the surrounding actors were just
    -- generic grey diamonds with no clue why).  Tagging them as
    -- event_door lets the viewer style them distinctly + lets sister
    -- plugins know "this is a transient barrier, not a real wall."
    --
    -- Skin patterns observed across boss encounters:
    --   * Helltide world bosses:   "FX_BossRoom_*", "Boss_Door_*",
    --                              "*_FireWall*", "Helltide_Maiden_Door"
    --   * Hordes wave gates:       "DGN_Standard_Door_Lock_Sigil_Ancients_*"
    --   * Vampire / Duriel arenas: "*_BossArena_*", "Boss_Arena_Wall*",
    --                              "*_BossEncounter*Door*"
    --   * Generic boss event:      "_Event_Door", "_Encounter_Door"
    -- Order: BEFORE dungeon_entrance and other door buckets so the
    -- more specific event-door label wins.
    { kind = 'event_door', patterns = {
        'BossRoom_Door',         'BossArena_Door',     'BossArena_Wall',
        'Boss_Arena_',           'BossEncounter_',     'Boss_Door_',
        'BossRoom_FireWall',     '_FireWall_Door',     '_Encounter_Door',
        '_Event_Door',           'Helltide_Maiden_Door',
        'DGN_Standard_Door_Lock_Sigil',     -- Hordes wave gates
        'FX_BossRoom_',
    }},

    -- Dungeon entrances / nightmare-dungeon doors / boss-room portals.
    -- The player typically stands on / walks into these to enter content.
    -- Order matters -- this must be checked BEFORE the generic portal
    -- bucket so we keep the more specific label.
    { kind = 'dungeon_entrance', patterns = {
        'Portal_Dungeon',                  -- Portal_Dungeon_Generic_*_Door
        'Dungeon_Location',                -- Dungeon_Location_0, _1, ...
        'Dungeon_Entrance',
        'EGD_DungeonEntry',
        '_DungeonEntrance',
    }},

    -- Pit-specific exits: the clickable switch in each pit boss room
    -- that opens the portal to the next floor / pit completion.
    -- D4's pit is internally "Tower" so the prefix is TWR_.
    { kind = 'pit_exit', patterns = {
        'TWR_ExitPortalSwitch',
        'TWR_ExitPortal',
        'TWR_BossRoomExit',
    }},

    -- Undercity floor-progression switches: the clickable platform that
    -- transitions the player to the next level of an Undercity run.
    -- Without this, Undercity zones merge with no inter-level traversal
    -- info -- the beacons (enticement) get captured but the level-change
    -- mechanism doesn't, so StaticPather has no way to plan multi-level
    -- routes.
    { kind = 'undercity_exit', patterns = {
        'X1_Undercity_PortalSwitch',
    }},

    -- Town portals (placed by player or persistent town links). Catching
    -- these lets the static-pather plant "exit to town" pins automatically.
    { kind = 'portal_town', patterns = {
        'TownPortal',                      -- TownPortal, townPortal_*
        'Town_Portal',                     -- Town_Portal_Destination_*
        'Portal_Town_',
    }},

    -- Helltide-specific portals (Maiden chambers, sub-area gates).
    { kind = 'portal_helltide', patterns = { 'Portal_Helltide' } },

    -- Generic / unclassified portals (zone-to-zone scene transitions).
    { kind = 'portal', patterns = {
        'Prefab_Portal_', 'EGD_MSWK_World_Portal', 'ZoneTransition_',
    }},

    -- Waypoints + town infrastructure
    { kind = 'waypoint',    patterns = { 'Waypoint_', '^Waypoint$' } },
    { kind = 'stash',       patterns = { '^Stash$' } },

    -- Chests
    { kind = 'chest_helltide_random',   patterns = { 'Helltide_RewardChest_Random' } },
    { kind = 'chest_helltide_silent',   patterns = { 'Helltide_SilentChest' } },
    { kind = 'chest_helltide_targeted', patterns = { 'usz_rewardGizmo_' } },
    { kind = 'chest',                   patterns = { 'GizmoLootChest', '_LootChest', '_RewardChest', 'Chest_Generic' } },

    -- Shrines / pyres
    { kind = 'pyre',     patterns = { 'Pyre_Helltide', 'Helltide_Pyre' } },
    { kind = 'shrine',   patterns = { '^Shrine_', '_Shrine$' } },

    -- Quest objectives
    { kind = 'objective',         patterns = {
        'Symbol_Quest_Proxy', 'Cultist_SacrificePillar',
        'DRLG_Structure_Spider_Cocoon',
    }},
    { kind = 'enticement',        patterns = {
        'X1_Undercity_Enticements_SpiritBeaconSwitch',
        'SpiritHearth_Switch',
    }},
    { kind = 'glyph_gizmo',       patterns = { 'EGD_MSWK_GlyphUpgrade', 'Pit_Glyph' } },

    -- Infernal Hordes pylons (a.k.a. "boons" in the UI).  Each wave the
    -- player walks to one of these and clicks it to apply its modifier
    -- to the rest of the run.  Skin names match HordeDev/data/pylons.lua
    -- (substring match against the skin -- the live actor skin is
    -- typically `BSK_Pylon_<name>` and HordeDev's existing matcher uses
    -- the bare name as a substring pattern, so we do the same).
    { kind = 'pylon', patterns = {
        'ChaoticOffering',     'AetherGoblins',     'InfernalStalker',
        'MassingMasses',       'PuffingMasses',     'GorgingMasses',
        'HellishMasses',       'FiendishLegions',   'CorruptingSpires',
        'FiendishMasses',      'SurgingElites',     'GestatingMasses',
        'InfernalLords',       'EnduringLords',     'BlightedVerge',
        'FiendishSpires',      'ColossalFiends',    'RuthlessLords',
        'SummonedHellborne',   'UnstoppableElites', 'EmpoweredElites',
        'AmbushingHellborne',  'TransitiveSpires',  'CovetedSpires',
        'TreasuredSpires',     'PreciousSpires',    'ForceChaosWaves',
        'ForceNextChaosWave',  'ForceNoChaosWaves', 'BlightedSpires',
        'HellsWrath',          'AnchoredMasses',    'SkulkingHellborne',
        'SurgingHellborne',    'BlisteringHordes',  'EmpoweredHellborne',
        'RagingHellfire',      'InvigoratingHellborne',
        'EmpoweredMasses',     'ThrivingMasses',    'EmpoweredCouncil',
        'IncreasedEvadeCooldown',  'IncreasedPotionCooldown',
        'ReduceAllResistance', 'MeteoricHellborne', 'DeadlySpires',
        'AetherRush',          'EnergizingMasses',  'GreedySpires',
        'UnstableFiends',      'DesolateVerge',
    }},
    -- Bonus-aether structures (separate from pylons -- spawn during Aether
    -- Goblins / Aether Mass events as alt-loot containers).
    { kind = 'aether_structure', patterns = { 'BSK_Structure_BonusAether' } },

    -- Activity-specific NPCs we care about (vendors, obelisks, gate keepers)
    { kind = 'pit_obelisk',       patterns = { 'TWN_Kehj_IronWolves_PitKey_Crafter' } },
    { kind = 'undercity_obelisk', patterns = { 'Aubrie_Test_Undercity_Crafter' } },
    { kind = 'warplans_vendor',   patterns = { 'Warplans_Vendor' } },
    { kind = 'tyrael',            patterns = { 'NPC_QST_X2_Tyrael' } },
    { kind = 'horde_gate',        patterns = { 'QST_Caldeum_GatesToHell_Seal' } },

    -- Mercenaries (Skov_Temis hideout NPCs)
    { kind = 'mercenary',  patterns = { 'Merc_Hideout_NPC' } },

    -- S07 bounty meta system (Ravens, etc -- weekly bounty NPCs).
    { kind = 'bounty_npc', patterns = { 'S07_Bounty_Meta_', 'Bounty_Meta_' } },

    -- Town gizmos: armory, jeweler chest, etc.
    { kind = 'gizmo',  patterns = { '^Gizmo_' } },

    -- Resources
    { kind = 'ore',  patterns = { 'OreNode_', '_OreNode' } },
    { kind = 'herb', patterns = { 'HerbNode_', '_HerbNode' } },

    -- Wells: XP wells, season pact wells, healing wells, etc.  Stationary
    -- interactables that grant a buff or resource.  Substring matches
    -- cover the common D4 naming variants.
    { kind = 'well', patterns = {
        'Well_XP', 'XPWell', 'XP_Well', 'PactWell', 'Pact_Well',
        'Well_Health', 'HealthWell', 'Healing_Well',
        'Realmwalker_Well', 'Tribute_Well',
        'EGD_.*Well', 'S0%d_.*Well', 'BSK_.*Well',
        '_Well_',
    }},

    -- Generic NPC / town vendor (broad fallback for interactables)
    { kind = 'npc_vendor', patterns = {
        '_Crafter', '_Vendor', '_Healer', '_Service_', '_DustyTomes',
        '_Gambler', '_Jeweler', '_Occultist', '_Stable',
        'TWN_.*Crafter',
    }},
    { kind = 'npc',        patterns = { '^TWN_', '^NPC_' } },
}

-- Skins we never capture even if interactable=true. Player class actors,
-- combat-effect transients, world-building noise.
local SKIN_IGNORE_SUBSTR = {
    'Hardpoint', 'SceneTrigger', 'environmentFX', 'Light_',
    '_cone', 'twoHandSorc', 'sorcererF', 'rogueF', 'barbarianF',
    'druidF', 'necromancerF', 'spiritbornF',
    'sorcererM', 'rogueM', 'barbarianM', 'druidM', 'necromancerM', 'spiritbornM',
    'Start_Location', 'sorc_', 'rogue_', 'X1_Gidbinn',
    -- Decorative props that look like interactables but aren't useful
    -- catalog entries: building doors (the actual building prop, not
    -- dungeon entrances -- those start with Portal_Dungeon/Dungeon_*),
    -- vendor display props, light sources, signs, etc.
    '_Building_Wood_Door', '_Building_Stone_Door',
    '_Wood_Door_', '_Stone_Door_', '_Metal_Door_',
    'Askari_Prop_', '_Prop_Lantern', '_Prop_Sign',
    -- Pit-boss paragon-glyph upgrade gizmo: spawns wherever the boss died,
    -- so its position is meaningless for pathing.  All three known skin
    -- variants are filtered:
    --   Gizmo_Paragon_Glyph_Upgrade  -- post-boss interactable (pit floor 5)
    --   EGD_MSWK_GlyphUpgrade        -- early-game equivalent
    --   Pit_Glyph                    -- internal pit naming
    'Gizmo_Paragon_Glyph_Upgrade', 'EGD_MSWK_GlyphUpgrade', 'Pit_Glyph',
    -- Transient floor pickups that drop from kills/chests.  These spawn at
    -- random positions wherever a mob died, so a static actor catalog
    -- entry is meaningless -- they're consumed-on-pickup, not waypoints.
    --   HealthPot_Dose_Pickup            (type_id 30631106,   sno_id 47186448)
    --   Sorcerer_CracklingEnergy_Pickup  (type_id 1385506706, sno_id 72352155)
    --   BurningAether                    (type_id 3189278226, sno_id 1234174277)
    'HealthPot_Dose_Pickup', 'Sorcerer_CracklingEnergy_Pickup',
    'BurningAether',
}

-- Memoized: first time we see a skin we run the linear scan over the
-- ignore-list, then stash the answer.  Subsequent encounters of the
-- same skin are a single hash lookup.  This is the dominant per-pulse
-- saving in dense zones with many actors of repeating skins.
-- Dynamic ignore list, loaded from a sibling file the uploader writes
-- on each cycle.  Empty if the file is missing.  Loaded ONCE at module
-- load time -- the user reloads Lua to pick up new patterns, matching
-- the rest of the recorder's load model.  Wrapped in pcall so a syntax
-- error in the generated file doesn't take the recorder down.
local _DYNAMIC_IGNORE = {}
do
    local ok, mod = pcall(require, 'core.ignore_dynamic')
    if ok and type(mod) == 'table' then
        _DYNAMIC_IGNORE = mod
        if console and console.print then
            console.print(string.format(
                '[actor_capture] loaded %d dynamic ignore pattern(s)', #mod))
        end
    end
end

local function ignored(skin)
    local v = _ignored_cache[skin]
    if v ~= nil then return v end
    for _, s in ipairs(SKIN_IGNORE_SUBSTR) do
        if skin:find(s, 1, true) then
            _ignored_cache[skin] = true
            return true
        end
    end
    -- Then check the dynamic list (admin-added patterns from the server).
    -- Lookup is the same plain-substring shape as the static list, so
    -- adding 'BurningAether' here matches every skin containing that
    -- substring without the admin needing to know about Lua patterns.
    for _, s in ipairs(_DYNAMIC_IGNORE) do
        if skin:find(s, 1, true) then
            _ignored_cache[skin] = true
            return true
        end
    end
    _ignored_cache[skin] = false
    return false
end

-- Context-aware override.  Some skins mean different things depending on
-- whether the player is inside a pit vs. an open dungeon (e.g. the same
-- 'Portal_Dungeon_Generic' is a between-floor transition in pits but a
-- dungeon entrance out in the world).  `world_name` comes from the
-- recorder's current record (e.g. 'PIT_ProtoDun_South' or 'Sanctuary_*').
local function context_kind(skin, world_name)
    local in_pit = world_name and world_name:sub(1, 4) == 'PIT_'
    if in_pit and skin:find('Portal_Dungeon', 1, true) then
        return 'pit_floor_portal'
    end
    return nil
end

-- Memoized classify: result depends on (skin, world_name) but world is
-- effectively constant within a session, so we keep one cache per world
-- and dump it when the world changes.  Per-pulse this turns N pattern
-- scans into a single hash lookup once a skin has been classified once.
local function classify(skin, world_name)
    -- World swap -> drop the cache.  Skin classification is context-
    -- aware (Portal_Dungeon_* maps to pit_floor_portal in pit worlds,
    -- dungeon_entrance elsewhere), so a stale cache from the previous
    -- world would mis-label new sightings.
    if world_name ~= _classify_world then
        _classify_cache = {}
        _classify_world = world_name
    end
    local cached = _classify_cache[skin]
    if cached ~= nil then
        return cached or nil       -- false (no match) -> nil
    end
    local ctx = context_kind(skin, world_name)
    if ctx then
        _classify_cache[skin] = ctx
        return ctx
    end
    for _, cat in ipairs(CATEGORIES) do
        for _, p in ipairs(cat.patterns) do
            -- Use Lua pattern match if pattern starts with '^' or has special
            -- chars; otherwise plain substring. Most patterns are plain.
            if p:sub(1,1) == '^' or p:find('[%%%[%]%*%+%?]') then
                if skin:match(p) then
                    _classify_cache[skin] = cat.kind
                    return cat.kind
                end
            else
                if skin:find(p, 1, true) then
                    _classify_cache[skin] = cat.kind
                    return cat.kind
                end
            end
        end
    end
    -- Catch-all: any interactable that survived SKIN_IGNORE_SUBSTR but
    -- didn't match a specific category becomes a generic 'interactable'.
    -- This makes the recorder log everything clickable in the world (XP
    -- wells, lever switches, season-event pillars, vendor stalls we
    -- haven't named yet, etc.) rather than silently dropping them.  Adds
    -- some noise but the merger's saturation logic dedups static spawns
    -- and the viewer can hide low-confidence entries.
    _classify_cache[skin] = 'interactable'
    return 'interactable'
end

-- ---------------------------------------------------------------------------
-- Public API.
-- ---------------------------------------------------------------------------
M.set_enabled       = function (v) enabled = v and true or false end
M.set_scan_interval = function (s) if type(s) == 'number' and s > 0 then scan_interval_s = s end end
M.set_on_new_actor  = function (fn) on_new_actor_cb = (type(fn) == 'function') and fn or nil end
M.is_enabled        = function () return enabled end
M.entry_count       = function () return #entries end

M.reset = function ()
    entries = {}
    index   = {}
    last_scan_t  = -math.huge
    last_evict_t = -math.huge
    -- Skin caches survive M.reset() on purpose: the ignore-list is
    -- session-invariant, and the classify cache is invalidated lazily
    -- on world change inside classify() itself.  Keeping them across
    -- resets means the next session starts pre-warmed for any skin
    -- the previous session already saw.
end

local function dedup_key(skin, x, y, floor)
    local cx = math.floor(x / pos_grid + 0.5)
    local cy = math.floor(y / pos_grid + 0.5)
    return string.format('%s|%d|%d|%d', skin, cx, cy, floor or 1)
end

-- Pulse: caller passes a function record_t(now) returning seconds-since-record-start.
-- world_name is optional; when provided lets context_kind() override the
-- generic classification (e.g. Portal_Dungeon_Generic in PIT_* worlds
-- becomes 'pit_floor_portal' instead of 'dungeon_entrance').
-- Returns true if a scan happened this pulse, false otherwise.
M.scan_pulse = function (now, floor_idx, record_t, world_name)
    if not enabled then return false end
    if (now - last_scan_t) < scan_interval_s then return false end
    last_scan_t = now
    if not actors_manager or not actors_manager.get_all_actors then return false end

    local floor = floor_idx or 1
    local rt = record_t and record_t(now) or now

    local seen_this_scan = 0
    for _, a in pairs(actors_manager:get_all_actors()) do
        local interactable = false
        local ok, ret = pcall(a.is_interactable, a)
        if ok then interactable = ret and true or false end

        -- ------------------------------------------------------------------
        -- Hostile-mob capture path (separate from the interactable path).
        --
        -- Bosses + elites + champions have stable spawn points within their
        -- procedural layouts (pit boss rooms, helltide world bosses, NMD
        -- end-of-dungeon bosses, hordes wave-final elites).  Crowdsourced
        -- across many runs the merger clusters them by skin+rounded-pos
        -- and identifies "boss rooms" + roaming-elite paths.  Trash mobs
        -- that randomly spawn at varying coords get filtered by the merger's
        -- saturation logic (one observation = noise; many observations at
        -- the same location = real fixed spawn).
        -- ------------------------------------------------------------------
        if not interactable then
            local skin = a.get_skin_name and a:get_skin_name() or nil
            if skin and skin ~= '' and not ignored(skin) then
                local is_boss, is_elite, is_champ
                pcall(function () is_boss  = a:is_boss()      and true or false end)
                pcall(function () is_elite = a:is_elite()     and true or false end)
                pcall(function () is_champ = a:is_champion()  and true or false end)
                if is_boss or is_elite or is_champ then
                    local kind = 'boss'
                    if not is_boss then kind = is_champ and 'champion' or 'elite' end
                    local pp = a:get_position()
                    if pp then
                        local x, y, z = pp:x() or 0, pp:y() or 0, pp:z() or 0
                        if not (x == 0 and y == 0 and z == 0) and (x*x + y*y) >= 25 then
                            local key = dedup_key(skin, x, y, floor)
                            local existing = index[key]
                            if existing then
                                existing.last_t = rt
                                existing.samples = existing.samples + 1
                            else
                                local rid, tid, sec, rad
                                pcall(function () rid = a:get_id() end)
                                pcall(function () tid = a:get_type_id() end)
                                pcall(function () sec = a:get_secondary_data_id() end)
                                pcall(function () rad = a:get_radius() end)
                                local entry = {
                                    skin    = skin,
                                    kind    = kind,
                                    x       = math.floor(x * 10 + 0.5) / 10,
                                    y       = math.floor(y * 10 + 0.5) / 10,
                                    z       = math.floor(z * 10 + 0.5) / 10,
                                    floor   = floor,
                                    first_t = rt,
                                    last_t  = rt,
                                    samples = 1,
                                    interactable = false,
                                    id      = rid,
                                    type_id = tid,
                                    sno_id  = sec,
                                    radius  = rad and (math.floor(rad * 10 + 0.5) / 10) or nil,
                                    is_boss  = is_boss  or nil,
                                    is_elite = is_elite or nil,
                                    is_champ = is_champ or nil,
                                }
                                entries[#entries + 1] = entry
                                index[key] = entry
                                if on_new_actor_cb then on_new_actor_cb(entry) end
                            end
                            seen_this_scan = seen_this_scan + 1
                        end
                    end
                end
            end
        end

        if interactable then
            local skin = a.get_skin_name and a:get_skin_name() or nil
            if skin and skin ~= '' and not ignored(skin) then
                local kind = classify(skin, world_name)
                if kind then
                    local pp = a:get_position()
                    if pp then
                        local x, y, z = pp:x() or 0, pp:y() or 0, pp:z() or 0
                        if not (x == 0 and y == 0 and z == 0) then
                            local key = dedup_key(skin, x, y, floor)
                            local existing = index[key]
                            if existing then
                                existing.last_t = rt
                                existing.samples = existing.samples + 1
                                existing.interactable = true
                            else
                                -- Capture richer metadata once on first sighting.
                                local rid, tid, sec, rad, is_boss, is_elite
                                pcall(function () rid     = a:get_id() end)
                                pcall(function () tid     = a:get_type_id() end)
                                pcall(function () sec     = a:get_secondary_data_id() end)
                                pcall(function () rad     = a:get_radius() end)
                                pcall(function () is_boss = a:is_boss() and true or false end)
                                pcall(function () is_elite= a:is_elite() and true or false end)
                                local entry = {
                                    skin    = skin,
                                    kind    = kind,
                                    x       = math.floor(x * 10 + 0.5) / 10,
                                    y       = math.floor(y * 10 + 0.5) / 10,
                                    z       = math.floor(z * 10 + 0.5) / 10,
                                    floor   = floor,
                                    first_t = rt,
                                    last_t  = rt,
                                    samples = 1,
                                    interactable = true,
                                    -- Richer identifiers (nil-safe in JSON encoder)
                                    id      = rid,
                                    type_id = tid,
                                    sno_id  = sec,    -- often the SNO hash for the actor's def
                                    radius  = rad and (math.floor(rad * 10 + 0.5) / 10) or nil,
                                    is_boss  = is_boss or nil,
                                    is_elite = is_elite or nil,
                                }
                                entries[#entries + 1] = entry
                                index[key] = entry
                                if on_new_actor_cb then on_new_actor_cb(entry) end
                            end
                            seen_this_scan = seen_this_scan + 1
                        end
                    end
                end
            end
        end
    end

    -- Periodic stale-entry eviction.  Long sessions accumulate hundreds
    -- of distinct catalog entries; the index lookup itself stays O(1)
    -- but Lua's GC has to walk every live object on each cycle, so
    -- catalog size feeds back into per-pulse pause times.  Drop entries
    -- we haven't seen in EVICT_STALE_AGE seconds to keep total live
    -- objects bounded.  The merger dedups across sessions server-side,
    -- so re-emitting an evicted actor when it reappears is harmless.
    if #entries > EVICT_MIN_ENTRIES and (now - last_evict_t) > EVICT_MIN_INTERVAL then
        last_evict_t = now
        local stale_threshold = rt - EVICT_STALE_AGE
        local kept = {}
        local kept_index = {}
        for i = 1, #entries do
            local e = entries[i]
            if e.last_t >= stale_threshold then
                kept[#kept + 1] = e
                kept_index[dedup_key(e.skin, e.x, e.y, e.floor)] = e
            end
        end
        local dropped = #entries - #kept
        if dropped > 0 then
            entries = kept
            index   = kept_index
            if console and console.print then
                console.print(string.format(
                    '[actor_capture] evicted %d stale entries; %d remain',
                    dropped, #kept))
            end
        end
    end

    return true, seen_this_scan
end

-- Snapshot for inclusion in record JSON. Marks the array so flush.lua
-- emits it as a JSON array, not an object.
M.snapshot = function ()
    local out = { __array = true }
    for _, e in ipairs(entries) do
        out[#out + 1] = e
    end
    return out
end

return M
