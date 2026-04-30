-- ---------------------------------------------------------------------------
-- Classify the current zone/world into a WarMap activity_kind.
--
-- Returns one of: 'helltide', 'pit', 'nmd', 'undercity', 'hordes', 'town',
-- 'overworld', or nil when the player is in a true loading screen
-- ('[sno none]'). Towns are recorded just like activities so we build maps
-- of every place the player goes.
-- ---------------------------------------------------------------------------

local M = {}

local HELLTIDE_BUFF_HASH = 1066539

-- Known D4 town zone names. Anything matching is 'town'. Everything else
-- that doesn't match a prefix rule is 'overworld'.
local TOWNS = {
    ['Skov_Temis']             = true,
    ['Scos_Cerrigar']          = true,
    ['Kehj_Caldeum']           = true,
    ['Hawe_Backwater']         = true,
    ['Hawe_Tarsarak']          = true,
    ['Hawe_Zarbinzet']         = true,
    ['Naha_KurastDocks']       = true,
    ['Frac_Menestad']          = true,
    ['Step_Jirandai']          = true,
    ['Kehj_IronWolves_Kehjan'] = true,
    ['Frac_Tundra_S']          = true,    -- Menestad subzone
    ['Scos_Coast']             = true,    -- Marowen subzone
}

-- Zone-prefix -> activity. More specific prefixes first.
local PREFIX_RULES = {
    { prefix = 'X1_Undercity_',         activity = 'undercity' },
    { prefix = 'PIT_',                  activity = 'pit'       },
    { prefix = 'DGN_',                  activity = 'nmd'       },
    { prefix = 'S05_BSK_',              activity = 'hordes'    },
}

local function player_has_helltide_buff()
    local lp = get_local_player()
    if not lp then return false end
    if not lp.get_buffs then return false end
    local buffs = lp:get_buffs()
    if not buffs then return false end
    for _, b in pairs(buffs) do
        local hash = b.name_hash or (b.get_name_hash and b:get_name_hash()) or nil
        if hash == HELLTIDE_BUFF_HASH then return true end
    end
    return false
end

-- Returns activity_kind string or nil (only for loading screens).
M.classify = function ()
    local w = get_current_world()
    if not w then return nil end
    local zone = w.get_current_zone_name and w:get_current_zone_name() or nil
    if not zone or zone == '' then return nil end
    if zone == '[sno none]' then return nil end    -- true loading screen

    if TOWNS[zone] then return 'town' end

    for _, rule in ipairs(PREFIX_RULES) do
        if zone:sub(1, #rule.prefix) == rule.prefix then
            return rule.activity
        end
    end

    -- Helltide is "overworld zone with the helltide buff active".
    if player_has_helltide_buff() then
        return 'helltide'
    end

    return 'overworld'
end

M.world_name_for_floor_tracking = function ()
    local w = get_current_world()
    if not w or not w.get_name then return nil end
    return w:get_name()
end

-- Multi-floor activities: same zone name across floors, but world_id
-- changes when the player descends.  The recorder uses world_id transitions
-- to drive its floor counter -- but only for these activities.  Other
-- activities (overworld, town, helltide, nmd, hordes) treat zone as flat.
--
-- Pit:        zone='PIT_Subzone' across all floors
-- Undercity:  zone='X1_Undercity_BugCave' (etc.) across all floors
local MULTI_FLOOR = { pit = true, undercity = true }
M.is_multi_floor = function (activity_kind)
    return MULTI_FLOOR[activity_kind] == true
end

return M
