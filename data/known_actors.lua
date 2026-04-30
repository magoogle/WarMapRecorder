-- ---------------------------------------------------------------------------
-- Known actor skin names organized by activity. Used for typed events --
-- when interact_object() or a sibling plugin reports an interaction with
-- one of these, the recorder tags the event with a richer kind.
--
-- This table is purely informational right now -- the event-tagging hooks
-- aren't wired up yet (TODO). When they are, the recorder will emit
-- e.g. {kind='chest_opened', actor='Helltide_RewardChest_Random'} instead
-- of bare 'interact'.
-- ---------------------------------------------------------------------------

return {
    helltide = {
        chests = {
            'Helltide_RewardChest_Random',
            'Helltide_SilentChest',
            'usz_rewardGizmo_1H', 'usz_rewardGizmo_2H',
            'usz_rewardGizmo_ChestArmor', 'usz_rewardGizmo_Rings',
            'usz_rewardGizmo_Amulet', 'usz_rewardGizmo_Gloves',
            'usz_rewardGizmo_Legs', 'usz_rewardGizmo_Boots',
            'usz_rewardGizmo_Helm', 'usz_rewardGizmo_Uber',
        },
        events = {
            'Cultist_SacrificePillar_02',
            'DRLG_Structure_Spider_Cocoon',
        },
        ores = { 'OreNode_Helltide' },
        herbs = { 'HerbNode_Helltide' },
    },

    pit = {
        portal_descend = 'Prefab_Portal_Dungeon_Generic',
        traversal      = 'Traversal_Gizmo',
        glyph_gizmo    = 'EGD_MSWK_GlyphUpgrade',  -- placeholder name
    },

    nmd = {
        objectives = {
            'Cultist_SacrificePillar_02',
            'DRLG_Structure_Spider_Cocoon',
        },
        boss_actors = {},  -- per-dungeon, fill in as we map them
    },

    undercity = {
        obelisk         = 'Aubrie_Test_Undercity_Crafter',
        portal          = 'Portal_Dungeon_Undercity',
        enticements = {
            'X1_Undercity_Enticements_SpiritBeaconSwitch',
            'SpiritHearth_Switch',
        },
        warp_pad        = nil,  -- TODO: capture skin name on first run
    },

    hordes = {
        gate     = 'QST_Caldeum_GatesToHell_Seal',
        portal   = 'Portal_Dungeon_Generic',
        pylons   = {},  -- TODO
        chests   = {},  -- TODO
    },
}
