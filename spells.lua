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
    BuffMeDB.lastCastForGroup    = {}
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
    if BuffMeDB.showTargetIcon  == nil then BuffMeDB.showTargetIcon  = true  end
    if BuffMeDB.showSpellIcon   == nil then BuffMeDB.showSpellIcon   = true  end
    -- persistent diagnostic log (written to disk on /reload or logout)
    BuffMeDB.diagnosticLog = BuffMeDB.diagnosticLog or {}
    -- reverse name→key index for O(1) "already registered?" checks
    BuffMeDB.nameToKey = BuffMeDB.nameToKey or {}
    -- per-typeGroup per-target last-cast preference: [typeGroup][targetName] = spellKey
    BuffMeDB.lastCastForGroup = BuffMeDB.lastCastForGroup or {}
end

-- Record which spell was last cast for a typeGroup on a named target.
-- Called whenever CLEU or UNIT_AURA confirms a buff actually landed.
function BuffMe_RecordLastCast(typeGroup, targetName, spellKey)
    if not typeGroup or not targetName or not spellKey then return end
    local tg = BuffMeDB.lastCastForGroup[typeGroup]
    if not tg then
        tg = {}
        BuffMeDB.lastCastForGroup[typeGroup] = tg
    end
    tg[targetName] = spellKey
    BuffMe_Debug("Preference recorded: typeGroup \"" .. typeGroup ..
        "\" → \"" .. tostring(spellKey) .. "\" on " .. targetName)
end

-- Return the preferred spellKey for a typeGroup/target pair, or nil if none recorded.
function BuffMe_GetPreferredSpellKey(typeGroup, targetName)
    if not BuffMeDB.lastCastForGroup then return nil end
    local tg = BuffMeDB.lastCastForGroup[typeGroup]
    return tg and tg[targetName]
end

function BuffMe_GetSpell(spellId)
    return BuffMeDB.spells[spellId]
end

-- Register a buff spell we can cast (discovered via SPELL_AURA_APPLIED in combat log)
function BuffMe_RegisterSpell(spellId, spellName, auraName)
    if BuffMeDB.spells[spellId] then return end  -- already known

    -- Spells with a cooldown beyond the GCD (1.5 s) are combat/emergency buttons;
    -- flag them so they are excluded from the auto-buff rotation.
    local cdKey = type(spellId) == "number" and spellId or spellName
    local _, cdDuration = GetSpellCooldown(cdKey)
    local hasCooldown = cdDuration and cdDuration > 1.5 or nil

    BuffMeDB.spells[spellId] = {
        spellId    = spellId,
        name       = spellName,
        auraName   = auraName,
        priority   = 5,
        ineligible = hasCooldown,
    }
    BuffMeDB.nameToKey[spellName] = spellId  -- reverse index; any valid key works for lookup

    -- Bootstrap: each new aura gets its own typeGroup (will be merged later when we learn conflicts)
    local normalAura = BuffMe_NormalizeName(auraName)
    if not BuffMeDB.auraToTypeGroup[normalAura] then
        local typeGroup = normalAura
        BuffMeDB.auraToTypeGroup[normalAura] = typeGroup
        BuffMeDB.typeGroupMembers[typeGroup] = { normalAura }
    end

    if hasCooldown then
        BuffMe_Debug("Spell learned — INELIGIBLE (cooldown " .. cdDuration ..
            "s): \"" .. spellName .. "\" (key " .. tostring(spellId) .. ")")
    else
        BuffMe_Debug("Spell learned: " .. spellName .. " (key " .. tostring(spellId) ..
            ", typeGroup: " .. BuffMeDB.auraToTypeGroup[normalAura] .. ")")
    end
end

-- Mark a spell as self-only: its buff always applies to the caster regardless of target.
-- Detected when SPELL_AURA_APPLIED lands on the player despite being aimed at someone else.
-- Persists in SavedVariables; the optimizer will only ever suggest casting it on "player".
function BuffMe_MarkSelfOnly(key)
    local entry = BuffMeDB.spells[key]
    if entry and not entry.selfOnly then
        entry.selfOnly = true
        BuffMe_Debug("Marked self-only: \"" .. entry.name .. "\"")
        return true
    end
    return false
end

-- Mark a spell ineligible for auto-buffing (hostile-target requirement, cooldown, etc.).
-- Persists in SavedVariables so the decision survives reloads.
function BuffMe_MarkIneligible(key, reason)
    local entry = BuffMeDB.spells[key]
    if entry and not entry.ineligible then
        entry.ineligible = true
        BuffMe_Debug("Marked ineligible (" .. (reason or "?") .. "): \"" .. entry.name .. "\"")
        return true
    end
    return false
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

-- Return all spell entries that are currently in the player's spellbook and eligible
-- for auto-buffing (not flagged ineligible due to cooldown or hostile-target requirement).
function BuffMe_GetKnownBuffSpells()
    local result = {}
    for key, entry in pairs(BuffMeDB.spells) do
        if not entry.ineligible then
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
    end
    return result
end
