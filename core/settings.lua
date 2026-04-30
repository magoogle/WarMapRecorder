local gui = require 'gui'

-- Actor capture is always on (no GUI toggle).  Sensible defaults
-- hardcoded; expose via GUI later if a tunable becomes useful.
local settings = {
    plugin_label        = gui.plugin_label,
    plugin_version      = gui.plugin_version,
    enabled             = false,
    auto_start          = true,
    sample_hz           = 5,
    debug_mode          = false,
    capture_actors      = true,    -- always-on
    actor_scan_interval = 2,       -- 2s; cheap, plenty for stationary actors
}

settings.update_settings = function ()
    settings.enabled    = gui.elements.main_toggle:get()
    settings.auto_start = gui.elements.auto_start:get()
    settings.sample_hz  = gui.elements.sample_hz:get()
    settings.debug_mode = gui.elements.debug_mode:get()
end

return settings
