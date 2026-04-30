-- ---------------------------------------------------------------------------
-- WarMapRecorder v0.1 -- captures position + interaction data for D4 zones.
-- Source of truth for this code lives in WarMap/tools/recorder/.
-- It's deployed into the QQT scripts/ folder via deploy_recorder.ps1.
--
-- Read SCHEMA.md in the WarMap repo for the JSON contract; read RECORDING_GUIDE.md
-- for end-user workflow.
-- ---------------------------------------------------------------------------

local gui      = require 'gui'
local settings = require 'core.settings'
local recorder = require 'core.recorder'

local local_player

local function update_locals()
    local_player = get_local_player()
end

local function main_pulse()
    settings.update_settings()
    if not local_player then return end
    recorder.pulse()
end

local function render_pulse()
    if not local_player then return end
    if not settings.enabled then return end
    if not recorder.is_recording() then return end
    local rec = recorder.current()
    if not rec then return end
    local c = recorder.counts()
    local msg = string.format(
        'WarMapRecorder | %s | %s | samples=%d events=%d cells=%d actors=%d',
        rec.activity_kind, rec.zone, c.samples, c.events, c.cells, c.actors)
    local x = 24
    local y = get_screen_height() - 36
    graphics.text_2d(msg, vec2:new(x, y), 14, color_orange(220))
end

-- ---------------------------------------------------------------------------
-- Plugin global -- exposes a small public API for sibling plugins to inject
-- typed events into the active recording. e.g.
--   WarMapRecorderPlugin.note_event('chest_opened', { actor='...', x=..., y=... })
-- ---------------------------------------------------------------------------
WarMapRecorderPlugin = {
    is_recording = recorder.is_recording,
    note_event   = recorder.note_event,
    current      = recorder.current,
    counts       = recorder.counts,
}

on_update(function ()
    update_locals()
    main_pulse()
end)

on_render_menu(gui.render)
on_render(render_pulse)
