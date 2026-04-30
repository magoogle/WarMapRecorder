-- ---------------------------------------------------------------------------
-- WarMapRecorder GUI -- enable/disable + sample rate + debug logging.
--
-- Actor capture is always on; without it the recordings have no value
-- (the catalog of POIs is the whole point of crowdsourcing).
-- ---------------------------------------------------------------------------

local plugin_label   = 'warmap_recorder'
local plugin_version = '0.3'
console.print('Lua Plugin - WarMapRecorder v' .. plugin_version)

local gui = {}

local function cb(default, key)
    return checkbox:new(default, get_hash(plugin_label .. '_' .. key))
end
local function si(min, max, default, key)
    return slider_int:new(min, max, default, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

gui.elements = {
    main_tree     = tree_node:new(0),
    main_toggle   = cb(false, 'main_toggle'),
    auto_start    = cb(true,  'auto_start'),
    sample_hz     = si(1, 20, 5, 'sample_hz'),
    debug_mode    = cb(false, 'debug_mode'),
}

gui.render = function ()
    if not gui.elements.main_tree:push('WarMapRecorder v' .. plugin_version) then return end
    gui.elements.main_toggle:render('Enable recorder',
        'Master toggle. With auto_start on, the recorder will only buffer ' ..
        'samples while the player is in a known activity zone (helltide / ' ..
        'pit / NMD / undercity / hordes / town).')
    gui.elements.auto_start:render('Auto-start on activity zone',
        'Begin a new recording automatically when entering an activity ' ..
        'zone; finalize and write the NDJSON dump on zone exit.')
    gui.elements.sample_hz:render('Sample rate (Hz)',
        'Position samples per second while you are moving. 5 is a good default; ' ..
        'higher is denser data, larger files. Range 1-20. ' ..
        'When you stand still the recorder backs off to a low-rate heartbeat.')
    gui.elements.debug_mode:render('Debug logging',
        'Verbose console output: sample/event counts, idle transitions. Off by default.')
    gui.elements.main_tree:pop()
end

return gui
