-- Export a character's learned BuffMe data (BuffMeDB.chars[CharacterName]) to JSON, for
-- manual inspection and promotion into SpellDB.lua. Requires the Lua 5.4 interpreter
-- (installed via winget) since it loads the SavedVariables file as a real Lua chunk rather
-- than re-implementing a Lua parser.
--
-- Usage: lua ExportSavedVariables.lua <path-to-account-BuffMeDB.lua> <CharacterName> [out.json]

local svPath   = assert(arg[1], "usage: lua ExportSavedVariables.lua <BuffMeDB.lua path> <CharName> [out.json]")
local charName = assert(arg[2], "usage: lua ExportSavedVariables.lua <BuffMeDB.lua path> <CharName> [out.json]")
local outPath  = arg[3] or (charName .. ".json")

-- SavedVariables files are valid Lua chunks that just assign globals (BuffMeDB, etc.).
local chunk = assert(loadfile(svPath))
chunk()

local db = BuffMeDB and BuffMeDB.chars and BuffMeDB.chars[charName]
assert(db, "No BuffMeDB.chars[\"" .. charName .. "\"] found in " .. svPath)

-- classToken/realm are written by BuffMe_InitDB (spells.lua) on every login. Flag Wildcard
-- (classToken "HERO") characters loudly: their spellGroups are drawn per-character at random
-- and must never be promoted into SpellDB.lua's shared per-realm baseline.
if db.classToken == "HERO" then
    io.stderr:write("WARNING: " .. charName .. " is a Wildcard (HERO) character on realm '"
        .. tostring(db.realm) .. "' — do NOT promote spells/spellGroups from this export "
        .. "into SpellDB.lua.\n")
end

-- Minimal JSON encoder: just enough for this data shape (nested tables, strings, numbers,
-- booleans). Arrays are detected as tables with a contiguous 1..n integer key run;
-- everything else is encoded as an object with sorted keys for stable diffs.
local function isArray(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n == 0 then return false end
    for i = 1, n do if t[i] == nil then return false end end
    return true
end

local ESCAPES = {
    ["\\"] = "\\\\", ["\""] = "\\\"", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}
local function encodeString(s)
    return '"' .. s:gsub('[\\"\n\r\t]', ESCAPES) .. '"'
end

local encode
encode = function(v, indent)
    indent = indent or ""
    local nextIndent = indent .. "  "
    local t = type(v)
    if t == "string" then
        return encodeString(v)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        if next(v) == nil then return "{}" end
        if isArray(v) then
            local parts = {}
            for i, item in ipairs(v) do
                parts[i] = nextIndent .. encode(item, nextIndent)
            end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            local parts = {}
            for _, k in ipairs(keys) do
                parts[#parts + 1] = nextIndent .. encodeString(tostring(k)) .. ": " .. encode(v[k], nextIndent)
            end
            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
        end
    else
        return "null"
    end
end

local f = assert(io.open(outPath, "w"))
f:write(encode(db))
f:write("\n")
f:close()
print("Wrote " .. outPath)
