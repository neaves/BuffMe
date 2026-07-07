local PARTY_UNITS = { "player", "party1", "party2", "party3", "party4" }

-- UnitInRange returns nil for "player" on some builds; the player is always in range of themselves.
local function IsUnitInRange(unit)
    return unit == "player" or UnitInRange(unit)
end

-- Scan all live party members' buffs.
-- Returns: { [unit] = { [normalizedAuraName] = { auraName, caster, typeGroup } } }
local function ScanPartyAuras()
    local auraMap = {}
    for _, unit in ipairs(PARTY_UNITS) do
        if UnitExists(unit) then
            auraMap[unit] = {}
            local i = 1
            while true do
                local buffName, _, _, _, _, _, _, casterUnit = UnitBuff(unit, i)
                if not buffName then break end
                local normalName = BuffMe_NormalizeName(buffName)
                local typeGroup  = BuffMeDB.auraToTypeGroup[normalName] or normalName
                auraMap[unit][normalName] = {
                    auraName  = buffName,
                    caster    = casterUnit,
                    typeGroup = typeGroup,
                }
                i = i + 1
            end
        end
    end
    return auraMap
end

-- Build a table of typeGroup -> best spell entry that the player can currently cast.
-- Also returns the full knownSpells list so callers can reuse it without re-scanning.
function BuffMe_GetProviderTypeGroups()
    local providers   = {}
    local knownSpells = BuffMe_GetKnownBuffSpells()
    for _, entry in ipairs(knownSpells) do
        local normalAura = BuffMe_NormalizeName(entry.auraName)
        local typeGroup  = BuffMeDB.auraToTypeGroup[normalAura] or normalAura
        local existing   = providers[typeGroup]
        if not existing or (entry.priority or 5) > (existing.priority or 5) then
            providers[typeGroup] = entry
        end
    end
    return providers, knownSpells
end

-- Pick which spell to cast for a typeGroup on a specific unit.
-- Prefers the spell last successfully cast on that target in this typeGroup (if still
-- available in the spellbook), then falls back to the highest-priority castable spell.
local function SelectSpellForGroup(typeGroup, unit, knownSpells)
    local targetName   = UnitName(unit)
    local preferredKey = BuffMe_GetPreferredSpellKey(typeGroup, targetName)

    local preferred      = nil
    local fallback       = nil
    local fallbackPriority = -1

    for _, entry in ipairs(knownSpells) do
        local normalAura = BuffMe_NormalizeName(entry.auraName)
        local entryTG    = BuffMeDB.auraToTypeGroup[normalAura] or normalAura
        if entryTG == typeGroup then
            if preferredKey and entry.spellId == preferredKey then
                preferred = entry
            end
            local p = entry.priority or 5
            if p > fallbackPriority then
                fallbackPriority = p
                fallback         = entry
            end
        end
    end

    return preferred or fallback
end

-- Determine which playerGroups are already active on the caster
local function GetActivePlayerGroups(playerAuras)
    local active = {}
    for normalAura, auraData in pairs(playerAuras) do
        if auraData.caster == "player" then
            for spellId, entry in pairs(BuffMeDB.spells) do
                if BuffMe_NormalizeName(entry.auraName) == normalAura then
                    local pg = BuffMeDB.spellToPlayerGroup[spellId]
                    if pg then active[pg] = true end
                end
            end
        end
    end
    return active
end

-- Main: return (spellId, targetUnit) for the highest-priority missing buff, or nil, nil
function BuffMe_GetNextCast()
    local auraMap            = ScanPartyAuras()
    local providers, knownSpells = BuffMe_GetProviderTypeGroups()
    local playerAuras        = auraMap["player"] or {}
    local activePlayerGroups = GetActivePlayerGroups(playerAuras)

    local bestSpellId, bestUnit, bestPriority = nil, nil, -1

    for _, unit in ipairs(PARTY_UNITS) do
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) and IsUnitInRange(unit) then
            local unitAuras = auraMap[unit] or {}

            -- Build covered typeGroup set for this unit (covered by ANY caster)
            local coveredTG = {}
            for _, auraData in pairs(unitAuras) do
                coveredTG[auraData.typeGroup] = true
            end

            for typeGroup in pairs(providers) do
                local shouldSkip = false

                -- Skip if this typeGroup is already covered on this unit
                if coveredTG[typeGroup] then
                    shouldSkip = true
                end

                -- Select the preferred (or best available) spell for this unit/typeGroup
                local selectedEntry = nil
                if not shouldSkip then
                    selectedEntry = SelectSpellForGroup(typeGroup, unit, knownSpells)
                    if not selectedEntry then shouldSkip = true end
                end

                -- Skip if our playerGroup for this spell is already active
                if not shouldSkip then
                    local pg = BuffMeDB.spellToPlayerGroup[selectedEntry.spellId]
                    if pg and activePlayerGroups[pg] then
                        shouldSkip = true
                    end
                end

                -- Skip if unit already has a same-or-higher priority spell from our targetGroup
                if not shouldSkip then
                    local tg = BuffMeDB.spellToTargetGroup[selectedEntry.spellId]
                    if tg then
                        for _, tgSpellId in ipairs(BuffMeDB.targetGroupMembers[tg] or {}) do
                            local tgEntry = BuffMeDB.spells[tgSpellId]
                            if tgEntry then
                                local normalTGAura = BuffMe_NormalizeName(tgEntry.auraName)
                                if unitAuras[normalTGAura] and unitAuras[normalTGAura].caster == "player" then
                                    if (tgEntry.priority or 5) >= (selectedEntry.priority or 5) then
                                        shouldSkip = true
                                        break
                                    end
                                end
                            end
                        end
                    end
                end

                if not shouldSkip then
                    local priority = selectedEntry.priority or 5
                    if priority > bestPriority then
                        bestPriority = priority
                        bestSpellId  = selectedEntry.spellId
                        bestUnit     = unit
                    end
                end
            end
        end
    end

    return bestSpellId, bestUnit
end

-- Count total missing buff slots across all party members (for the button badge)
function BuffMe_CountMissingBuffs()
    local count    = 0
    local auraMap  = ScanPartyAuras()
    local providers = BuffMe_GetProviderTypeGroups()

    for _, unit in ipairs(PARTY_UNITS) do
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) and IsUnitInRange(unit) then
            local unitAuras = auraMap[unit] or {}
            local coveredTG = {}
            for _, auraData in pairs(unitAuras) do
                coveredTG[auraData.typeGroup] = true
            end
            for typeGroup in pairs(providers) do
                if not coveredTG[typeGroup] then
                    count = count + 1
                end
            end
        end
    end
    return count
end
