local PARTY_UNITS = { "player", "party1", "party2", "party3", "party4" }

-- UnitInRange returns nil for "player" on some builds; the player is always in range of themselves.
local function IsUnitInRange(unit)
    return unit == "player" or UnitInRange(unit)
end

-- Scan all live party members' buffs.
-- Returns: { [unit] = { [normalizedAuraName] = { auraName, caster, typeGroup, effectSig } } }
-- effectSig is set only for external buffs (caster ~= "player") matched via effectGroups.
-- It lets GetNextCast distinguish "our spell covers the typeGroup" from "an external buff
-- covers only this specific effect sig" — the latter still leaves room for sibling spells
-- in the same typeGroup whose effects haven't been covered.
local function ScanPartyAuras()
    -- Build a reverse index: normalName → sig, from the persisted effectGroups table.
    -- This lets us tag already-registered external buffs with their sig in O(1) without
    -- re-reading tooltips on every scan (tooltip reads are only needed for truly new buffs).
    local effectSigByNorm = {}
    for sig, egEntry in pairs(BuffMeDB.effectGroups) do
        for normalName in pairs(egEntry.members) do
            effectSigByNorm[normalName] = sig
        end
    end

    local auraMap = {}
    for _, unit in ipairs(PARTY_UNITS) do
        if UnitExists(unit) then
            auraMap[unit] = {}
            local i = 1
            while true do
                local buffName, _, _, _, _, _, _, casterUnit = UnitBuff(unit, i)
                if not buffName then break end
                local normalName = BuffMe_NormalizeName(buffName)
                local typeGroup = BuffMeDB.auraToTypeGroup[normalName]
                if not typeGroup and next(BuffMeDB.effectGroups) then
                    -- Unknown buff: try to identify it via effectGroup tooltip matching
                    local sig, value = BuffMe_GetUnitBuffInfo(unit, i)
                    if sig and sig ~= "" then
                        local egEntry = BuffMeDB.effectGroups[sig]
                        if egEntry then
                            BuffMe_RegisterAuraInTypeGroup(buffName, egEntry.typeGroup)
                            BuffMe_RegisterInEffectGroup(sig, egEntry.typeGroup, normalName, buffName, value)
                            typeGroup = egEntry.typeGroup
                            effectSigByNorm[normalName] = sig  -- index for this session
                            BuffMe_Debug("Effect group match: \"" .. buffName .. "\" → typeGroup \"" .. egEntry.typeGroup .. "\"")
                        end
                    end
                end
                typeGroup = typeGroup or normalName
                -- effectSig: only meaningful for non-player casters; used by GetNextCast
                -- to cover only the specific effect sig rather than the whole typeGroup.
                local effectSig = (casterUnit ~= "player") and effectSigByNorm[normalName] or nil
                auraMap[unit][normalName] = {
                    auraName  = buffName,
                    caster    = casterUnit,
                    typeGroup = typeGroup,
                    effectSig = effectSig,
                }
                i = i + 1
            end

            -- Tracking abilities (Find Herbs, Find Minerals, etc.) are flagged isTracking
            -- at registration because UnitBuff never returns them. For the player only,
            -- check GetTrackingInfo to inject active tracking into the aura map so the
            -- optimizer doesn't see them as perpetually missing.
            if unit == "player" then
                for j = 1, GetNumTrackingTypes() do
                    local trackName, _, isActive = GetTrackingInfo(j)
                    if isActive and trackName and BuffMeDB.nameToKey[trackName] then
                        local normalName = BuffMe_NormalizeName(trackName)
                        if not auraMap[unit][normalName] then
                            local typeGroup = BuffMeDB.auraToTypeGroup[normalName] or normalName
                            auraMap[unit][normalName] = {
                                auraName  = trackName,
                                caster    = "player",
                                typeGroup = typeGroup,
                            }
                        end
                    end
                end
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
-- coveredSigs: set of effect sigs already covered by external buffs on this unit.
--   Spells whose tooltipSig appears in coveredSigs are skipped — their effect is already
--   provided by a stronger external source. Other spells in the same typeGroup (with
--   different sigs) remain valid so the optimizer can still fill a useful buff slot.
-- Falls back to highest-priority castable spell whose effect isn't already covered.
local function SelectSpellForGroup(typeGroup, unit, knownSpells, coveredSigs)
    local targetName   = UnitName(unit)
    local preferredKey = BuffMe_GetPreferredSpellKey(typeGroup, targetName)

    local preferred      = nil
    local fallback       = nil
    local fallbackPriority = -1

    for _, entry in ipairs(knownSpells) do
        -- Self-only spells (toggleable auras that only affect the caster) are never
        -- cast on party members — skip them when evaluating non-player units.
        if not (entry.selfOnly and unit ~= "player") then
            local normalAura = BuffMe_NormalizeName(entry.auraName)
            local entryTG    = BuffMeDB.auraToTypeGroup[normalAura] or normalAura
            if entryTG == typeGroup then
                -- Skip if this spell's specific effect is already covered by an external
                -- buff (e.g. "Whispers of Y'shaarj" covers "Grove Instinct"'s sig, but
                -- not "Primal Instinct"'s sig — so Primal remains a valid candidate).
                local sigCovered = entry.tooltipSig and coveredSigs[entry.tooltipSig]
                if not sigCovered then
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

            -- Split coverage into two buckets:
            --   coveredTG  — typeGroup fully blocked (our own spell is up, or another
            --                player's registered spell covers the slot)
            --   coveredSigs — specific effect sigs covered by external effectGroup-matched
            --                 buffs (e.g. "Whispers of Y'shaarj" has same sig as Grove
            --                 Instinct). These block only that sig; sibling spells in the
            --                 same typeGroup with different sigs remain valid candidates.
            local coveredTG   = {}
            local coveredSigs = {}
            for _, auraData in pairs(unitAuras) do
                if auraData.effectSig then
                    coveredSigs[auraData.effectSig] = true
                else
                    coveredTG[auraData.typeGroup] = true
                end
            end

            for typeGroup in pairs(providers) do
                local shouldSkip = false

                -- Skip if this typeGroup is already fully covered (our spell is up)
                if coveredTG[typeGroup] then
                    shouldSkip = true
                end

                -- Select the preferred (or best available) spell for this unit/typeGroup,
                -- excluding spells whose specific effect sig is already externally covered.
                local selectedEntry = nil
                if not shouldSkip then
                    selectedEntry = SelectSpellForGroup(typeGroup, unit, knownSpells, coveredSigs)
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
    local providers, knownSpells = BuffMe_GetProviderTypeGroups()

    for _, unit in ipairs(PARTY_UNITS) do
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) and IsUnitInRange(unit) then
            local unitAuras = auraMap[unit] or {}
            local coveredTG   = {}
            local coveredSigs = {}
            for _, auraData in pairs(unitAuras) do
                if auraData.effectSig then
                    coveredSigs[auraData.effectSig] = true
                else
                    coveredTG[auraData.typeGroup] = true
                end
            end
            for typeGroup, providerEntry in pairs(providers) do
                if not (providerEntry.selfOnly and unit ~= "player") then
                    if not coveredTG[typeGroup] then
                        -- typeGroup not fully covered; count as missing only if at least
                        -- one spell in it has an uncovered (or unknown) effect sig.
                        local hasCastable = SelectSpellForGroup(typeGroup, unit, knownSpells, coveredSigs)
                        if hasCastable then
                            count = count + 1
                        end
                    end
                end
            end
        end
    end
    return count
end
