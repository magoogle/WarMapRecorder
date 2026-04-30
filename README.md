# WarMapRecorder

QQT plugin that records D4 gameplay sessions and ships them to a
[WarMap server](https://github.com/magoogle/warmap-server) for
crowd-sourced map merging.

## What it captures

- **Walkable cells** — derived from the position-sample stream (every
  sample is a "player stood here" → walkable). No active probing in
  v0.2+; the host's pathfinder is canonical.
- **Actor catalog** — chests, shrines, portals, dungeon entrances, NPCs,
  vendors, bosses/elites, world events. Deduped by skin + rounded
  position + floor. Filters out pickups, decorative props, and other
  noise via `core/actor_capture.lua`'s `SKIN_IGNORE_SUBSTR`.
- **Zone metadata** — zone name, world id, activity kind (helltide,
  pit, undercity, hordes, nmd, overworld, town).

## Output

`scripts/WarMapRecorder/dumps/<session_id>.ndjson` — one NDJSON line
per record (header / sample / actor / event / footer). The companion
[WarMap uploader](https://github.com/magoogle/warmap-server) ships
completed sessions to the server.

## Performance contract

This plugin runs on the game thread. Per the host perf rules:

- Every per-pulse path is O(1) amortized
- No `table.remove(t, 1)`, no `os.execute`, no synchronous network I/O
- Hot-path classifiers (`ignored`, `classify`) are memoized per-skin
- The actor catalog evicts stale entries (last_t > 5 min) so GC pause
  time stays bounded in long sessions

## Repo layout

```
core/
  recorder.lua            -- on_update driver, session lifecycle
  actor_capture.lua       -- actors_manager scan, dedup, classify
  grid_probe.lua          -- (legacy) walkable probe
  stream_writer.lua       -- NDJSON file writer
  flush.lua               -- periodic flush
  activity_classifier.lua -- zone -> activity kind
  uploader_launcher.lua   -- spawns the uploader subprocess
  settings.lua
data/
  known_actors.lua        -- shared classification data
gui.lua
main.lua
```

## Distribution

End-users get this plugin via the WarMap player bundle:
[`magoogle/warmap-recorder` `tools/installer/install.bat`](https://github.com/magoogle/warmap-recorder).
The installer copies `core/` + `data/` + `gui.lua` + `main.lua` into
the user's QQT scripts folder.
