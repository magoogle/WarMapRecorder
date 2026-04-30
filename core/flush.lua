-- ---------------------------------------------------------------------------
-- JSON serialization + disk flush for WarMapRecorder.
--
-- Records buffer in memory; flush() writes the full record as one JSON
-- document. We don't try to do partial appends (mid-record schema_version
-- header complicates parsing) -- instead, on flush we rewrite the whole
-- session file. Files are small enough (<1MB per session) that this is fine.
-- ---------------------------------------------------------------------------

local M = {}

-- ---------------------------------------------------------------------------
-- Minimal JSON encoder. Avoids pulling in dkjson / cjson because we don't
-- know which (if any) the QQT host bundles, and our schema is small.
--
-- Handles: nil/null, bool, integer, float, string, array (#t > 0 or
-- explicit __array=true marker), object. Strings only need basic escaping
-- for our content.
-- ---------------------------------------------------------------------------

local encode  -- forward decl

local function escape_string(s)
    return (s:gsub('[\\"\b\f\n\r\t]', {
        ['\\'] = '\\\\', ['"'] = '\\"', ['\b'] = '\\b',
        ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
    }):gsub('[%z\1-\31]', function (c)
        return string.format('\\u%04x', string.byte(c))
    end))
end

local function is_array(t)
    if t.__array == true then return true end
    if next(t) == nil then return false end
    local n = 0
    for k, _ in pairs(t) do
        if type(k) ~= 'number' then return false end
        n = n + 1
    end
    return n == #t
end

encode = function (v)
    local tv = type(v)
    if v == nil then
        return 'null'
    elseif tv == 'boolean' then
        return v and 'true' or 'false'
    elseif tv == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return 'null' end
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return string.format('%d', v)
        end
        return string.format('%.4g', v)
    elseif tv == 'string' then
        return '"' .. escape_string(v) .. '"'
    elseif tv == 'table' then
        if is_array(v) then
            local parts = {}
            for i, item in ipairs(v) do
                parts[i] = encode(item)
            end
            return '[' .. table.concat(parts, ',') .. ']'
        else
            local parts = {}
            for k, item in pairs(v) do
                if k ~= '__array' then
                    parts[#parts+1] = '"' .. escape_string(tostring(k)) .. '":' .. encode(item)
                end
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end
    end
    return 'null'
end

M.encode = encode

-- ---------------------------------------------------------------------------
-- Disk write.  Path is computed once at module load via package.path so we
-- find the recorder's own folder relative to the QQT scripts root.
-- ---------------------------------------------------------------------------
local function get_dump_dir()
    local root = string.gmatch(package.path, '.*?\\?')()
    if not root then return nil end
    return root:gsub('?', '') .. 'dumps'
end

local DUMP_DIR = get_dump_dir()

-- Best-effort directory create. os.execute('mkdir ...') is the typical Lua
-- way; QQT runs on the game thread so we only do this once at module load.
local function ensure_dump_dir()
    if not DUMP_DIR then return false end
    -- Probe: open a tmp file inside the dir to see if it exists
    local probe = io.open(DUMP_DIR .. '\\.warmap_probe', 'a')
    if probe then
        probe:close()
        os.remove(DUMP_DIR .. '\\.warmap_probe')
        return true
    end
    -- Try to create it
    os.execute('mkdir "' .. DUMP_DIR .. '" 2> nul')
    return true
end

ensure_dump_dir()

-- Write the full record JSON to a file named <session_id>.json. Overwrites
-- on each flush -- safe because we always include the full sample/event
-- arrays, never partial.
M.write_record = function (record)
    if not DUMP_DIR then return false, 'no dump dir' end
    if not record or not record.session_id then return false, 'no session_id' end
    local path = DUMP_DIR .. '\\' .. record.session_id .. '.json'
    local f = io.open(path, 'w')
    if not f then return false, 'open failed: ' .. path end
    local ok, err = pcall(function ()
        f:write(encode(record))
    end)
    f:close()
    if not ok then return false, 'encode failed: ' .. tostring(err) end
    return true, path
end

M.dump_dir = DUMP_DIR

return M
