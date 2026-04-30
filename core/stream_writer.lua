-- ---------------------------------------------------------------------------
-- Streaming NDJSON writer.
--
-- The previous design buffered the entire record in memory and rewrote
-- the full JSON file every flush_seconds. Cost grew linearly with session
-- length and produced visible game-thread pauses at ~30s intervals.
--
-- New design: the on-disk file is a sequence of newline-delimited JSON
-- objects ("NDJSON"). Each pulse appends only the entries that are new
-- since the last write. Per-pulse encoding cost is bounded to "what
-- changed", not "everything captured so far".
--
-- File layout:
--   {"type":"header", schema_version, session_id, activity_kind, zone, ...}
--   {"type":"sample", t, x, y, z, floor?, in_helltide?, cinders?}
--   {"type":"sample", ...}
--   {"type":"event",  t, kind, x, y, z, floor?, metadata?}
--   {"type":"actor",  skin, kind, x, y, z, floor, id?, type_id?, ...}
--   {"type":"grid",   floor, resolution, cells:[[cx,cy,w], ...]}    -- batched
--   {"type":"footer", ended_at, reason?}
--
-- The viewer + loader parse line-by-line and assemble the in-memory
-- record. Files without a footer line are treated as in-progress
-- (which means live mode "just works" -- the file is already valid
-- NDJSON for partial reads).
-- ---------------------------------------------------------------------------

local flush_mod = require 'core.flush'   -- for encode()

local M = {}

local current_path  = nil
local pending       = {}    -- array of already-encoded JSON strings (one per line)
local pending_count = 0
local last_io_t     = -math.huge
local fh            = nil    -- open file handle for the active session

-- Auto-flush thresholds: amortize syscall + AV overhead by batching, but
-- never let buffered data sit longer than FLUSH_TIME_S so live viewers
-- see fresh writes within ~1s of capture.
local FLUSH_LINE_THRESHOLD = 64
local FLUSH_TIME_S         = 1.0

local function now_t()
    return get_time_since_inject() or 0
end

-- Reset module-level state. Caller is responsible for closing fh first.
local function reset_state()
    current_path  = nil
    pending       = {}
    pending_count = 0
    last_io_t     = -math.huge
    fh            = nil
end

-- ---------------------------------------------------------------------------
-- start_session(path, header_obj)
--
-- Opens `path` for write, truncating any prior content, and writes the
-- header line. Subsequent append() calls will add lines to this file
-- until end_session() or another start_session().
-- ---------------------------------------------------------------------------
M.start_session = function (path, header_obj)
    if fh then
        pcall(function () fh:close() end)
        fh = nil
    end
    reset_state()
    current_path = path
    -- Truncate by opening with 'w' and immediately closing -- we'll re-open
    -- in append mode below. Doing it as one open also works but separates
    -- "create new file" from "stream into it".
    local trunc, err = io.open(path, 'w')
    if not trunc then
        console.print('[stream_writer] cannot open ' .. tostring(path) .. ': ' .. tostring(err))
        return false
    end
    trunc:close()
    -- Re-open in append mode and write header
    fh = io.open(path, 'a')
    if not fh then return false end
    local line = flush_mod.encode(header_obj) .. '\n'
    fh:write(line)
    fh:flush()
    last_io_t = now_t()
    return true
end

-- ---------------------------------------------------------------------------
-- append(obj)
--
-- Encode `obj` to JSON, push onto buffer. Auto-flushes when buffer
-- exceeds line/time threshold.
-- ---------------------------------------------------------------------------
M.append = function (obj)
    if not current_path or not fh then return false end
    pending[#pending + 1] = flush_mod.encode(obj) .. '\n'
    pending_count = pending_count + 1
    if pending_count >= FLUSH_LINE_THRESHOLD or
       (now_t() - last_io_t) >= FLUSH_TIME_S then
        M.flush()
    end
    return true
end

-- ---------------------------------------------------------------------------
-- flush()
--
-- Write any buffered lines to disk. Cheap when buffer is empty.
-- ---------------------------------------------------------------------------
M.flush = function ()
    if not fh or pending_count == 0 then return end
    fh:write(table.concat(pending))
    fh:flush()
    pending = {}
    pending_count = 0
    last_io_t = now_t()
end

-- ---------------------------------------------------------------------------
-- end_session(footer_obj?)
--
-- Optionally write a final footer line, flush, and close the file.
-- ---------------------------------------------------------------------------
M.end_session = function (footer_obj)
    if not fh then return end
    if footer_obj then M.append(footer_obj) end
    M.flush()
    pcall(function () fh:close() end)
    reset_state()
end

M.is_active = function () return fh ~= nil end
M.current_path = function () return current_path end

return M
