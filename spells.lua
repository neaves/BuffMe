-- Normalize an aura/spell name to a stable key: lowercase, letters and digits only
function BuffMe_NormalizeName(name)
    return name:lower():gsub("[^%a%d]", "")
end

-- Extract meaningful keywords (length > 3) from a spell/buff name
local function GetNameKeywords(name)
    local keywords = {}
    for word in name:lower():gmatch("%a+") do
        if #word > 3 then
            keywords[word] = true
        end
    end
    return keywords
end

-- Returns true if name1 and name2 share at least one meaningful keyword
local function KeywordOverlap(name1, name2)
    local kw1 = GetNameKeywords(name1)
    for word in name2:lower():gmatch("%a+") do
        if #word > 3 and kw1[word] then
            return true
        end
    end
    return false
end

-- Wipe all learned spell data, preserving config settings and the diagnostic log.
-- Use this to evict stale entries (e.g. proc-registered spells) and start fresh.
function BuffMe_ResetSpellDB()
    BuffMeDB.spells              = {}
    BuffMeDB.nameToKey           = {}
    BuffMeDB.auraToTypeGroup     = {}
    BuffMeDB.typeGroupMembers    = {}
    BuffMeDB.spellToTargetGroup  = {}
    BuffMeDB.targetGroupMembers  = {}
    BuffMeDB.spellToPlayerGroup  = {}
    BuffMeDB.playerGroupMembers  = {}
end

function BuffMe_InitDB()
    BuffMeDB = BuffMeDB or {}
    -- [spellId] = { spellId, name, auraName, priority }
    BuffMeDB.spells          = BuffMeDB.spells          or {}
    -- [normalizedAuraName] = typeGroup string
    BuffMeDB.auraToTypeGroup  = BuffMeDB.auraToTypeGroup  or {}
    -- [typeGroup] = { normalizedAuraName, ... }
    BuffMeDB.typeGroupMembers = BuffMeDB.typeGroupMembers or {}
    -- [spellId] = targetGroup string
    BuffMeDB.spellToTargetGroup  = BuffMeDB.spellToTargetGroup  or {}
    -- [targetGroup] = { spellId, ... }
    BuffMeDB.targetGroupMembers  = BuffMeDB.targetGroupMembers  or {}
    -- [spellId] = playerGroup string
    BuffMeDB.spellToPlayerGroup  = BuffMeDB.spellToPlayerGroup  or {}
    -- [playerGroup] = { spellId, ... }
    BuffMeDB.playerGroupMembers  = BuffMeDB.playerGroupMembers  or {}
    -- config settings
    if BuffMeDB.anchorLocked    == nil then BuffMeDB.anchorLocked    = false end
    if BuffMeDB.diagnosticMode  == nil then BuffMeDB.diagnosticMode  = false end
    -- persistent diagnostic log (written to disk on /reload or logout)
    BuffMeDB.diagnosticLog = BuffMeDB.diagnosticLog or {}
    -- reverse name→key index for O(1) "already registered?" checks
    BuffMeDB.nameToKey = BuffMeDB.nameToKey or {}
end

function BuffMe_GetSpell(spellId)
    return BuffMeDB.spells[spellId]
end

-- Register a buff spell we can cast (discovered via SPELL_AURA_APPLIED in combat log)
function BuffMe_RegisterSpell(spellId, spellName, auraName)
    if BuffMeDB.spells[spellId] then return end  -- already known

    BuffMeDB.spells[spellId] = {
        spellId  = spellId,
        name     = spellName,
        auraName = auraName,
        priority = 5,
    }
    BuffMeDB.nameToKey[spellName] = spellId  -- reverse index; any valid key works for lookup

    -- Bootstrap: each new aura gets its own typeGroup (will be merged later when we learn conflicts)
    local normalAura = BuffMe_NormalizeName(auraName)
    if not BuffMeDB.auraToTypeGroup[normalAura] then
        local typeGroup = normalAura
        BuffMeDB.auraToTypeGroup[normalAura] = typeGroup
        BuffMeDB.typeGroupMembers[typeGroup] = { normalAura }
    end

    BuffMe_Debug("Spell learned: " .. spellName .. " (ID " .. spellId .. ", typeGroup: " .. BuffMeDB.auraToTypeGroup[normalAura] .. ")")
end

-- Merge the typeGroups of two aura names when we learn they are mutually exclusive
function BuffMe_MergeTypeGroups(auraName1, auraName2)
    local n1  = BuffMe_NormalizeName(auraName1)
    local n2  = BuffMe_NormalizeName(auraName2)
    local tg1 = BuffMeDB.auraToTypeGroup[n1]
    local tg2 = BuffMeDB.auraToTypeGroup[n2]

    if not tg1 or not tg2 or tg1 == tg2 then return end

    BuffMe_Debug("TypeGroup merge: \"" .. tg2 .. "\" folded into \"" .. tg1 .. "\" (via " .. auraName1 .. " vs " .. auraName2 .. ")")

    -- Merge tg2 into tg1 (tg1 is canonical)
    local members = BuffMeDB.typeGroupMembers[tg2] or {}
    BuffMeDB.typeGroupMembers[tg1] = BuffMeDB.typeGroupMembers[tg1] or {}
    for _, aura in ipairs(members) do
        BuffMeDB.auraToTypeGroup[aura] = tg1
        local found = false
        for _, existing in ipairs(BuffMeDB.typeGroupMembers[tg1]) do
            if existing == aura then found = true; break end
        end
        if not found then
            table.insert(BuffMeDB.typeGroupMembers[tg1], aura)
        end
    end
    BuffMeDB.typeGroupMembers[tg2] = nil
end

-- Link two spell IDs into the same targetGroup (they are mutually exclusive on any single target)
function BuffMe_LinkTargetGroup(spellId1, spellId2, groupName)
    groupName = groupName
        or BuffMeDB.spellToTargetGroup[spellId1]
        or BuffMeDB.spellToTargetGroup[spellId2]
        or tostring(spellId1)

    for _, sid in ipairs({ spellId1, spellId2 }) do
        local oldGroup = BuffMeDB.spellToTargetGroup[sid]
        if oldGroup and oldGroup ~= groupName then
            -- Migrate all members of the old group into the new group
            local members = BuffMeDB.targetGroupMembers[oldGroup] or {}
            BuffMeDB.targetGroupMembers[groupName] = BuffMeDB.targetGroupMembers[groupName] or {}
            for _, memberSid in ipairs(members) do
                BuffMeDB.spellToTargetGroup[memberSid] = groupName
                local found = false
                for _, m in ipairs(BuffMeDB.targetGroupMembers[groupName]) do
                    if m == memberSid then found = true; break end
                end
                if not found then
                    table.insert(BuffMeDB.targetGroupMembers[groupName], memberSid)
                end
            end
            BuffMeDB.targetGroupMembers[oldGroup] = nil
        end

        BuffMeDB.spellToTargetGroup[sid] = groupName
        BuffMeDB.targetGroupMembers[groupName] = BuffMeDB.targetGroupMembers[groupName] or {}
        local found = false
        for _, m in ipairs(BuffMeDB.targetGroupMembers[groupName]) do
            if m == sid then found = true; break end
        end
        if not found then
            table.insert(BuffMeDB.targetGroupMembers[groupName], sid)
        end
    end
end

-- Link two spell IDs into the same playerGroup (only one can be active on the caster at a time)
function BuffMe_LinkPlayerGroup(spellId1, spellId2, groupName)
    groupName = groupName
        or BuffMeDB.spellToPlayerGroup[spellId1]
        or BuffMeDB.spellToPlayerGroup[spellId2]
        or ("pg_" .. tostring(spellId1))

    for _, sid in ipairs({ spellId1, spellId2 }) do
        BuffMeDB.spellToPlayerGroup[sid] = groupName
        BuffMeDB.playerGroupMembers[groupName] = BuffMeDB.playerGroupMembers[groupName] or {}
        local found = false
        for _, m in ipairs(BuffMeDB.playerGroupMembers[groupName]) do
            if m == sid then found = true; break end
        end
        if not found then
            table.insert(BuffMeDB.playerGroupMembers[groupName], sid)
        end
    end
end

-- Find the buff on targetUnit most likely blocking our spell (for typeGroup/targetGroup learning)
function BuffMe_FindBlockingBuff(targetUnit, ourSpellName)
    if not UnitExists(targetUnit) then return nil end

    -- Pass 1: keyword overlap (highest confidence)
    local i = 1
    while true do
        local buffName = UnitBuff(targetUnit, i)
        if not buffName then break end
        if KeywordOverlap(ourSpellName, buffName) then
            return buffName
        end
        i = i + 1
    end

    -- Pass 2: shared typeGroup in existing DB
    local ourNormal = BuffMe_NormalizeName(ourSpellName)
    local ourTG     = BuffMeDB.auraToTypeGroup[ourNormal]
    if ourTG then
        i = 1
        while true do
            local buffName = UnitBuff(targetUnit, i)
            if not buffName then break end
            local buffTG = BuffMeDB.auraToTypeGroup[BuffMe_NormalizeName(buffName)]
            if buffTG and buffTG == ourTG then
                return buffName
            end
            i = i + 1
        end
    end

    return nil
end

-- Return all spell entries that are currently in the player's spellbook.
-- Handles both numeric IDs (checked via GetSpellInfo) and synthetic string keys
-- (checked via GetSpellInfo(name) — used when no numeric ID could be determined).
function BuffMe_GetKnownBuffSpells()
    local result = {}
    for key, entry in pairs(BuffMeDB.spells) do
        local available
        if type(key) == "number" then
            available = GetSpellInfo(key) ~= nil
        else
            available = GetSpellInfo(entry.name) ~= nil
        end
        if available then
            table.insert(result, entry)
        end
    end
    return result
end
