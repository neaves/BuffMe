local PARTY_UNITS = { "player", "party1", "party2", "party3", "party4" }

-- UnitInRange was designed for party/raid frames; on Ascension's build it returns nil
-- (not false) for non-party unit tokens like "target". Treat nil as "unknown / in range"
-- for "target" — the player deliberately selected this unit, and a genuine out-of-range
-- cast will fail with a clear error. Only a hard false from UnitInRange should exclude it.
-- true if `unit` is the player or a party-member token — used to gate partyOnly spells,
-- which can be targeted via any non-party unit token (the BuffMe button's "target",
-- Clique's "mouseover", etc.), not just "target".
local function IsPartyUnit(unit)
    for _, u in ipairs(PARTY_UNITS) do
        if u == unit then return true end
    end
    return false
end

local function IsUnitInRange(unit)
    if unit == "player" then return true end
    local inRange = UnitInRange(unit)
    if inRange == nil and unit == "target" then return true end
    return inRange
end

-- Build the live candidate unit list: party members + current friendly non-party target.
-- "target" is appended only when outside combat, the target is a player, is friendly,
-- cannot be attacked by the player (guards against PvP-flagged same-faction players and
-- opposite-faction targets where UnitIsFriend may behave unexpectedly on private servers),
-- and is not already one of the party tokens (avoids double-counting a party member
-- who is also the current target).
local function GetCandidateUnits()
    local units = {}
    for _, u in ipairs(PARTY_UNITS) do
        if not (UnitExists(u) and BuffMe_IsTrivialTarget(u)) then
            units[#units + 1] = u
        end
    end
    if not InCombatLockdown()
       and UnitExists("target")
       and UnitIsPlayer("target")
       and UnitIsFriend("player", "target")
       and not UnitCanAttack("player", "target")
       and not BuffMe_IsTrivialTarget("target") then
        local alreadyIn = false
        for _, u in ipairs(PARTY_UNITS) do
            if UnitExists(u) and UnitIsUnit("target", u) then
                alreadyIn = true
                break
            end
        end
        if not alreadyIn then
            units[#units + 1] = "target"
        end
    end
    return units
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
    for sig, egEntry in pairs(BuffMeCharDB.effectGroups) do
        for normalName in pairs(egEntry.members) do
            effectSigByNorm[normalName] = sig
        end
    end

    local candidates = GetCandidateUnits()
    local auraMap = {}
    for _, unit in ipairs(candidates) do
        if UnitExists(unit) then
            auraMap[unit] = {}
            local i = 1
            while true do
                local buffName, _, _, _, _, _, _, casterUnit = UnitBuff(unit, i)
                if not buffName then break end
                local normalName = BuffMe_NormalizeName(buffName)
                local typeGroup = BuffMeCharDB.auraToTypeGroup[normalName]
                if not typeGroup and next(BuffMeCharDB.effectGroups) then
                    -- Unknown buff: try to identify it via effectGroup tooltip matching
                    local sig, value = BuffMe_GetUnitBuffInfo(unit, i)
                    if sig and sig ~= "" then
                        local egEntry, matchedSig = BuffMe_FindEffectGroup(sig)
                        if egEntry then
                            BuffMe_RegisterAuraInTypeGroup(buffName, egEntry.typeGroup)
                            BuffMe_RegisterInEffectGroup(matchedSig, egEntry.typeGroup, normalName, buffName, value)
                            typeGroup = egEntry.typeGroup
                            effectSigByNorm[normalName] = matchedSig  -- index for this session
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
                    if isActive and trackName and BuffMeCharDB.nameToKey[trackName] then
                        local normalName = BuffMe_NormalizeName(trackName)
                        if not auraMap[unit][normalName] then
                            local typeGroup = BuffMeCharDB.auraToTypeGroup[normalName] or normalName
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
    return auraMap, candidates
end

-- Build a table of typeGroup -> best spell entry that the player can currently cast.
-- Also returns the full knownSpells list so callers can reuse it without re-scanning.
function BuffMe_GetProviderTypeGroups()
    local providers   = {}
    local knownSpells = BuffMe_GetKnownBuffSpells()
    for _, entry in ipairs(knownSpells) do
        local normalAura = BuffMe_NormalizeName(entry.auraName)
        local typeGroup  = BuffMeCharDB.auraToTypeGroup[normalAura] or normalAura
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
        -- Party-only spells (rejected by the server on non-party targets — see
        -- BuffMe_MarkPartyOnly) are never offered for a non-party unit token.
        if not (entry.selfOnly and unit ~= "player") and not (entry.partyOnly and not IsPartyUnit(unit)) then
            local normalAura = BuffMe_NormalizeName(entry.auraName)
            local entryTG    = BuffMeCharDB.auraToTypeGroup[normalAura] or normalAura
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
            for spellId, entry in pairs(BuffMeCharDB.spells) do
                if BuffMe_NormalizeName(entry.auraName) == normalAura then
                    local pg = BuffMeCharDB.spellToPlayerGroup[spellId]
                    if pg then active[pg] = true end
                end
            end
        end
    end
    return active
end

-- Typegroups learned as "global singleton" (server allows only one live instance
-- anywhere, e.g. "Bless") are covered for every unit as soon as any one unit has
-- them — recasting elsewhere only relocates the buff, it never adds coverage.
local function GetGloballyCoveredTypeGroups(auraMap, candidates)
    local covered = {}
    for _, unit in ipairs(candidates) do
        for _, auraData in pairs(auraMap[unit] or {}) do
            if not auraData.effectSig and BuffMeCharDB.globalTypeGroups[auraData.typeGroup] then
                covered[auraData.typeGroup] = true
            end
        end
    end
    return covered
end

-- Main: return (spellId, targetUnit) for the highest-priority missing buff, or nil, nil
function BuffMe_GetNextCast()
    local auraMap, candidates = ScanPartyAuras()
    local providers, knownSpells = BuffMe_GetProviderTypeGroups()
    local playerAuras        = auraMap["player"] or {}
    local activePlayerGroups = GetActivePlayerGroups(playerAuras)
    local globallyCoveredTG  = GetGloballyCoveredTypeGroups(auraMap, candidates)

    local providerCount = 0
    for _ in pairs(providers) do providerCount = providerCount + 1 end
    if providerCount == 0 then
        BuffMe_Debug("GetNextCast: 0 provider spells — DB empty or all filtered by spec/cooldown")
        return nil, nil
    end

    local bestSpellId, bestUnit, bestPriority = nil, nil, -1

    for _, unit in ipairs(candidates) do
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) and IsUnitInRange(unit) then
            if unit == "target" then
                local n = UnitName("target") or "?"
                local coveredCount = 0
                for _ in pairs(auraMap["target"] or {}) do coveredCount = coveredCount + 1 end
                BuffMe_Debug("GetNextCast: evaluating target=" .. n ..
                    " (" .. coveredCount .. " aura(s) scanned)")
            end
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

                -- Skip if this typeGroup is already fully covered (our spell is up),
                -- or if it's a global-singleton typeGroup already covered on another unit.
                if coveredTG[typeGroup] or globallyCoveredTG[typeGroup] then
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
                    local pg = BuffMeCharDB.spellToPlayerGroup[selectedEntry.spellId]
                    if pg and activePlayerGroups[pg] then
                        shouldSkip = true
                    end
                end

                -- Skip if unit already has a same-or-higher priority spell from our targetGroup
                if not shouldSkip then
                    local tg = BuffMeCharDB.spellToTargetGroup[selectedEntry.spellId]
                    if tg then
                        for _, tgSpellId in ipairs(BuffMeCharDB.targetGroupMembers[tg] or {}) do
                            local tgEntry = BuffMeCharDB.spells[tgSpellId]
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

    -- Group-cast spells ("Greater" auras) apply to the whole party/raid from a single
    -- self-cast and reject any other target. Coverage is still correctly detected per-unit
    -- above (each member gets a real aura instance), but the actual cast must always be
    -- aimed at "player" regardless of which member's gap triggered the selection.
    if bestSpellId then
        local bestSpellEntry = BuffMe_GetSpell(bestSpellId)
        if bestSpellEntry and bestSpellEntry.groupCast then
            bestUnit = "player"
        end
    end

    return bestSpellId, bestUnit
end

-- Return (spellId, spellEntry) for the best buff to cast on a single unit.
-- Used by BuffMeHoverButton (Clique integration) so it can target "mouseover"
-- independently of the full party-queue logic in BuffMe_GetNextCast.
function BuffMe_GetBestCastForUnit(unit)
    if not BuffMeCharDB then return nil, nil end
    if not UnitExists(unit) or UnitIsDeadOrGhost(unit) then return nil, nil end

    local effectSigByNorm = {}
    for sig, egEntry in pairs(BuffMeCharDB.effectGroups) do
        for normalName in pairs(egEntry.members) do
            effectSigByNorm[normalName] = sig
        end
    end

    -- Scan the target unit's auras into coverage buckets
    local coveredTG       = {}
    local coveredSigs     = {}
    local unitPlayerAuras = {}   -- normalName set for player-cast buffs (targetGroup check)
    local i = 1
    while true do
        local buffName, _, _, _, _, _, _, casterUnit = UnitBuff(unit, i)
        if not buffName then break end
        local normalName = BuffMe_NormalizeName(buffName)
        local typeGroup  = BuffMeCharDB.auraToTypeGroup[normalName] or normalName
        local effectSig  = (casterUnit ~= "player") and effectSigByNorm[normalName] or nil
        if effectSig then
            coveredSigs[effectSig] = true
        else
            coveredTG[typeGroup] = true
        end
        if casterUnit == "player" then
            unitPlayerAuras[normalName] = true
        end
        i = i + 1
    end

    -- Scan player's own buffs to find which playerGroups are already active
    local playerAuras = {}
    i = 1
    while true do
        local buffName, _, _, _, _, _, _, casterUnit = UnitBuff("player", i)
        if not buffName then break end
        playerAuras[BuffMe_NormalizeName(buffName)] = { caster = casterUnit }
        i = i + 1
    end
    local activePlayerGroups = GetActivePlayerGroups(playerAuras)

    local providers, knownSpells = BuffMe_GetProviderTypeGroups()
    local bestSpellId, bestEntry, bestPriority = nil, nil, -1

    for typeGroup in pairs(providers) do
        if not coveredTG[typeGroup] then
            local selectedEntry = SelectSpellForGroup(typeGroup, unit, knownSpells, coveredSigs)
            if selectedEntry then
                local pg = BuffMeCharDB.spellToPlayerGroup[selectedEntry.spellId]
                if not (pg and activePlayerGroups[pg]) then
                    local shouldSkip = false
                    local tg = BuffMeCharDB.spellToTargetGroup[selectedEntry.spellId]
                    if tg then
                        for _, tgSpellId in ipairs(BuffMeCharDB.targetGroupMembers[tg] or {}) do
                            local tgEntry = BuffMeCharDB.spells[tgSpellId]
                            if tgEntry then
                                local normalTGAura = BuffMe_NormalizeName(tgEntry.auraName)
                                if unitPlayerAuras[normalTGAura] then
                                    if (tgEntry.priority or 5) >= (selectedEntry.priority or 5) then
                                        shouldSkip = true
                                        break
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
                            bestEntry    = selectedEntry
                        end
                    end
                end
            end
        end
    end

    return bestSpellId, bestEntry
end

-- Count total missing buff slots across all party members (for the button badge)
function BuffMe_CountMissingBuffs()
    local count    = 0
    local auraMap, candidates = ScanPartyAuras()
    local providers, knownSpells = BuffMe_GetProviderTypeGroups()
    local globallyCoveredTG  = GetGloballyCoveredTypeGroups(auraMap, candidates)

    for _, unit in ipairs(candidates) do
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
            for typeGroup in pairs(providers) do
                -- No top-level selfOnly/partyOnly pre-filter here: a typeGroup can contain
                -- a mix of member spells (e.g. "Boon of the Turtle" is selfOnly but sibling
                -- "Boon of the Bear" isn't), so gating on one arbitrary representative entry
                -- (as BuffMe_GetProviderTypeGroups picks) incorrectly skips the whole group.
                -- SelectSpellForGroup already applies selfOnly/partyOnly per individual
                -- entry — its nil/non-nil return is the only signal needed, matching
                -- BuffMe_GetNextCast so the badge count and the suggested-cast icon agree.
                if not coveredTG[typeGroup] and not globallyCoveredTG[typeGroup] then
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
    return count
end
