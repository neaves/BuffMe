-- Normalize an aura/spell name to a stable key: lowercase, letters and digits only
function BuffMe_NormalizeName(name)
    return name:lower():gsub("[^%a%d]", "")
end

-- Tooltip scan frame, created once on first use
local scanTT
local function GetScanTT()
    if scanTT then return scanTT end
    scanTT = CreateFrame("GameTooltip", "BuffMeScanTT", nil, "GameTooltipTemplate")
    scanTT:SetOwner(WorldFrame, "ANCHOR_NONE")
    return scanTT
end

-- Strip WoW color-code markup from a string (|cAARRGGBB...text...|r).
-- Unit buff tooltips can contain color codes (e.g. Boon descriptions), so we strip
-- them before building sigs to keep comparisons format-independent.
local function StripColorCodes(text)
    return text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
end

-- Reduce a tooltip line to a comparable signature: lowercase, all digit runs → "#"
local function NormTooltipLine(text)
    return (text:lower():gsub("%d+", "#"):gsub("%s+", " "):match("^(.-)%s*$"))
end

-- Collect body lines (2+) from the scan frame, stripping color codes.
-- We only call this on unit-buff tooltips (SetUnitBuff), which don't have
-- mana-cost or cast-time lines, so no metadata filtering is needed here.
local function ReadScanTTLines(tt)
    local lines = {}
    for line = 2, tt:NumLines() do
        local obj = _G["BuffMeScanTTTextLeft" .. line]
        if obj then
            local t = obj:GetText()
            if t and t ~= "" then
                t = StripColorCodes(t)
                local trimmed = t:match("^%s*(.-)%s*$")
                if trimmed ~= "" then lines[#lines + 1] = trimmed end
            end
        end
    end
    return lines
end

-- Normalize raw lines into a pipe-joined comparison signature (digits → #)
local function LinesToSig(lines)
    local parts = {}
    for _, t in ipairs(lines) do parts[#parts + 1] = NormTooltipLine(t) end
    return table.concat(parts, "|")
end

-- Extract the largest numeric value from raw tooltip lines for strength comparison
local function LinesToValue(lines)
    local best = 0
    for _, t in ipairs(lines) do
        for n in t:gmatch("%d+%.?%d*") do
            local v = tonumber(n)
            if v and v > best then best = v end
        end
    end
    return best
end

-- Return the cached aura-sourced sig and value for a spell entry.
-- Sigs are populated by BuffMe_CaptureAuraTooltip when a buff is observed landing;
-- returns nil/nil until the spell has been cast and the aura seen at least once.
function BuffMe_GetOurSpellInfo(entry)
    return entry.tooltipSig, entry.tooltipValue
end

-- Scan a unit's live buff list for entry.auraName, read its tooltip via SetUnitBuff,
-- and cache the sig+value on the entry. Also registers the entry in effectGroups.
-- Called from the CLEU SPELL_AURA_APPLIED and UNIT_AURA fallback handlers immediately
-- after a buff from the player is confirmed as landed on a unit.
function BuffMe_CaptureAuraTooltip(unit, entry)
    if entry.tooltipSig then return end  -- already captured
    if not UnitExists(unit) then return end
    local i = 1
    while true do
        local buffName = UnitBuff(unit, i)
        if not buffName then break end
        if buffName == entry.auraName then
            local sig, value = BuffMe_GetUnitBuffInfo(unit, i)
            if sig and sig ~= "" then
                entry.tooltipSig   = sig
                entry.tooltipValue = value
                local normalAura = BuffMe_NormalizeName(entry.auraName)
                local tg = BuffMeCharDB.auraToTypeGroup[normalAura]
                if tg then
                    BuffMe_RegisterInEffectGroup(sig, tg, normalAura, entry.auraName, value)
                    BuffMe_Debug("Effect group captured: \"" .. entry.auraName ..
                        "\" value=" .. value .. " tg=" .. tg)
                end
            end
            return
        end
        i = i + 1
    end
end

-- Return the tooltip signature and primary numeric value for a unit buff at index i.
-- Public so the optimizer can call it when scanning unknown buffs against effect groups.
function BuffMe_GetUnitBuffInfo(targetUnit, index)
    local tt = GetScanTT()
    tt:ClearLines()
    tt:SetUnitBuff(targetUnit, index)
    local lines = ReadScanTTLines(tt)
    return LinesToSig(lines), LinesToValue(lines)
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

-- Returns true if name1 and name2 share at least one meaningful keyword (>3 chars).
-- Also exposed as BuffMe_KeywordOverlap for use in BuffMe.lua gate checks.
local function KeywordOverlap(name1, name2)
    local kw1 = GetNameKeywords(name1)
    for word in name2:lower():gmatch("%a+") do
        if #word > 3 and kw1[word] then
            return true
        end
    end
    return false
end
function BuffMe_KeywordOverlap(name1, name2) return KeywordOverlap(name1, name2) end

-- Wipe all learned spell data, preserving config settings and the diagnostic log.
-- Use this to evict stale entries (e.g. proc-registered spells) and start fresh.
function BuffMe_ResetSpellDB()
    BuffMeCharDB.spells              = {}
    BuffMeCharDB.nameToKey           = {}
    BuffMeCharDB.auraToTypeGroup     = {}
    BuffMeCharDB.typeGroupMembers    = {}
    BuffMeCharDB.auraDisplayNames    = {}
    BuffMeCharDB.effectGroups        = {}
    BuffMeCharDB.spellToTargetGroup  = {}
    BuffMeCharDB.targetGroupMembers  = {}
    BuffMeCharDB.spellToPlayerGroup  = {}
    BuffMeCharDB.playerGroupMembers  = {}
    BuffMeCharDB.lastCastForGroup    = {}
end

function BuffMe_InitDB()
    -- Account-wide UI preferences (shared across all characters on this account)
    BuffMeDB = BuffMeDB or {}
    if BuffMeDB.anchorLocked        == nil then BuffMeDB.anchorLocked        = false end
    if BuffMeDB.showTargetIcon      == nil then BuffMeDB.showTargetIcon      = true  end
    if BuffMeDB.showSpellIcon       == nil then BuffMeDB.showSpellIcon       = true  end
    if BuffMeDB.compactSpellGroups  == nil then BuffMeDB.compactSpellGroups  = true  end
    if BuffMeDB.compactEffectGroups == nil then BuffMeDB.compactEffectGroups = true  end
    if BuffMeDB.uiScale             == nil then BuffMeDB.uiScale             = 1.0   end

    -- Per-character spell learning data (isolated per character)
    BuffMeCharDB = BuffMeCharDB or {}
    -- [spellId] = { spellId, name, auraName, priority }
    BuffMeCharDB.spells              = BuffMeCharDB.spells              or {}
    -- [normalizedAuraName] = typeGroup string
    BuffMeCharDB.auraToTypeGroup     = BuffMeCharDB.auraToTypeGroup     or {}
    -- [typeGroup] = { normalizedAuraName, ... }
    BuffMeCharDB.typeGroupMembers    = BuffMeCharDB.typeGroupMembers    or {}
    -- [spellId] = targetGroup string
    BuffMeCharDB.spellToTargetGroup  = BuffMeCharDB.spellToTargetGroup  or {}
    -- [targetGroup] = { spellId, ... }
    BuffMeCharDB.targetGroupMembers  = BuffMeCharDB.targetGroupMembers  or {}
    -- [spellId] = playerGroup string
    BuffMeCharDB.spellToPlayerGroup  = BuffMeCharDB.spellToPlayerGroup  or {}
    -- [playerGroup] = { spellId, ... }
    BuffMeCharDB.playerGroupMembers  = BuffMeCharDB.playerGroupMembers  or {}
    if BuffMeCharDB.diagnosticMode == nil then BuffMeCharDB.diagnosticMode = false end
    -- persistent diagnostic log (written to disk on /reload or logout)
    BuffMeCharDB.diagnosticLog    = BuffMeCharDB.diagnosticLog    or {}
    -- reverse name→key index for O(1) "already registered?" checks
    BuffMeCharDB.nameToKey        = BuffMeCharDB.nameToKey        or {}
    -- per-typeGroup per-target last-cast preference: [typeGroup][targetName] = spellKey
    BuffMeCharDB.lastCastForGroup = BuffMeCharDB.lastCastForGroup or {}
    -- [normalizedAuraName] = original display name; covers both castable spells and
    -- external auras registered via tooltip matching (which aren't in the spell DB)
    BuffMeCharDB.auraDisplayNames = BuffMeCharDB.auraDisplayNames or {}
    -- [tooltipSig] = { typeGroup, members = { [normalName] = { name, value } } }
    -- Keyed by normalized tooltip signature (digits→#); used by the optimizer to match
    -- unknown buffs on targets to our known effect groups by comparing tooltip text.
    BuffMeCharDB.effectGroups     = BuffMeCharDB.effectGroups     or {}
    -- One-time migration: sigs are now sourced exclusively from live aura tooltips
    -- (SetUnitBuff) rather than spellbook tooltips (SetSpell). Old spellbook-sourced
    -- sigs have mana-cost and cast-time lines that aura tooltips don't, so they can
    -- never match. Clear them so they are re-captured on next observed cast.
    if not BuffMeCharDB.auraSigV2 then
        BuffMeCharDB.effectGroups = {}
        if BuffMeCharDB.spells then
            for _, entry in pairs(BuffMeCharDB.spells) do
                entry.tooltipSig   = nil
                entry.tooltipValue = nil
            end
        end
        BuffMeCharDB.auraSigV2 = true
    end
end

-- Record which spell was last cast for a typeGroup on a named target.
-- Called whenever CLEU or UNIT_AURA confirms a buff actually landed.
function BuffMe_RecordLastCast(typeGroup, targetName, spellKey)
    if not typeGroup or not targetName or not spellKey then return end
    local tg = BuffMeCharDB.lastCastForGroup[typeGroup]
    if not tg then
        tg = {}
        BuffMeCharDB.lastCastForGroup[typeGroup] = tg
    end
    tg[targetName] = spellKey
    BuffMe_Debug("Preference recorded: typeGroup \"" .. typeGroup ..
        "\" → \"" .. tostring(spellKey) .. "\" on " .. targetName)
end

-- Return the preferred spellKey for a typeGroup/target pair, or nil if none recorded.
function BuffMe_GetPreferredSpellKey(typeGroup, targetName)
    if not BuffMeCharDB.lastCastForGroup then return nil end
    local tg = BuffMeCharDB.lastCastForGroup[typeGroup]
    return tg and tg[targetName]
end

function BuffMe_GetSpell(spellId)
    return BuffMeCharDB.spells[spellId]
end

-- Buff duration threshold below which a spell is treated as a combat active rather than
-- a persistent party buff.  UnitBuff returns total duration (not time remaining); 0 means
-- permanent.  Anything with a finite duration ≤ this value (in seconds) is auto-ineligible.
-- Covers short-lived shields (Rock Barrier, 10 s), burst cooldowns (Therazane's Rage, 10 s),
-- and charge-based abilities whose recharge period is short.
local SHORT_BUFF_THRESHOLD = 120

-- Register a buff spell we can cast (discovered via SPELL_AURA_APPLIED in combat log)
function BuffMe_RegisterSpell(spellId, spellName, auraName)
    if BuffMeCharDB.spells[spellId] then return end  -- already known

    local entry = {
        spellId  = spellId,
        name     = spellName,
        auraName = auraName,
        priority = 5,
    }
    BuffMeCharDB.spells[spellId] = entry
    BuffMeCharDB.nameToKey[spellName] = spellId
    BuffMeCharDB.auraDisplayNames[BuffMe_NormalizeName(auraName)] = auraName

    -- Short-duration detection: scan the player's current UnitBuff list for this aura.
    -- If the buff exists and has a finite duration ≤ SHORT_BUFF_THRESHOLD it is a combat
    -- active, not a sustained party buff — mark it ineligible immediately.
    -- UnitBuff fires before CLEU on Ascension, so the buff is already visible here.
    -- duration == 0 means permanent; we never mark those.
    do
        local i = 1
        while true do
            local buffName, _, _, _, _, duration = UnitBuff("player", i)
            if not buffName then break end
            if buffName == auraName then
                if duration and duration > 0 and duration <= SHORT_BUFF_THRESHOLD then
                    entry.ineligible = true
                    BuffMe_Debug("Auto-ineligible (short duration " ..
                        math.floor(duration) .. "s): \"" .. spellName .. "\"")
                end
                break
            end
            i = i + 1
        end
    end

    -- Bootstrap typeGroup for this new aura. Before creating a fresh group, scan the
    -- existing DB for any aura that shares a meaningful keyword (>3 chars) with this one.
    -- Spells with overlapping names (e.g. "Boon of the Bear" / "Boon of the Wolf", or
    -- "Grove Instinct" / "Primal Instinct") are very likely mutually exclusive variants
    -- of the same effect — pre-group them immediately so the optimizer treats them as a
    -- single covered slot from the very first cast, without needing to observe a replacement.
    local normalAura = BuffMe_NormalizeName(auraName)
    if not BuffMeCharDB.auraToTypeGroup[normalAura] then
        local matchedTG = nil
        for _, existingEntry in pairs(BuffMeCharDB.spells) do
            if KeywordOverlap(auraName, existingEntry.auraName) then
                local en = BuffMe_NormalizeName(existingEntry.auraName)
                matchedTG = BuffMeCharDB.auraToTypeGroup[en]
                if matchedTG then break end
            end
        end
        if matchedTG then
            BuffMeCharDB.auraToTypeGroup[normalAura] = matchedTG
            local members = BuffMeCharDB.typeGroupMembers[matchedTG]
            if members then
                local found = false
                for _, m in ipairs(members) do
                    if m == normalAura then found = true; break end
                end
                if not found then table.insert(members, normalAura) end
            end
            BuffMe_Debug("Pre-grouped \"" .. auraName .. "\" into typeGroup \"" ..
                matchedTG .. "\" (keyword overlap)")
        else
            local typeGroup = normalAura
            BuffMeCharDB.auraToTypeGroup[normalAura] = typeGroup
            BuffMeCharDB.typeGroupMembers[typeGroup] = { normalAura }
        end
    end

    -- Tracking abilities (Find Herbs, Find Minerals, etc.) don't appear in UnitBuff.
    -- Detect them via GetTrackingInfo and flag them so the optimizer can use
    -- the correct API to check their active state, and only considers them for the player.
    for i = 1, GetNumTrackingTypes() do
        local trackName = GetTrackingInfo(i)
        if trackName == spellName then
            entry.selfOnly   = true
            entry.isTracking = true
            BuffMe_Debug("Tracking ability detected: \"" .. spellName ..
                "\" (self-only, active state via GetTrackingInfo)")
            break
        end
    end

    BuffMe_Debug("Spell learned: " .. spellName .. " (key " .. tostring(spellId) ..
        ", typeGroup: " .. BuffMeCharDB.auraToTypeGroup[normalAura] .. ")")
end

-- Mark a spell as self-only: its buff always applies to the caster regardless of target.
-- Detected when SPELL_AURA_APPLIED lands on the player despite being aimed at someone else.
-- Persists in SavedVariables; the optimizer will only ever suggest casting it on "player".
-- Also propagates the flag to all other entries with the same spell name — one CLEU event
-- may register the same spell under multiple IDs (e.g. Boon of the Lion applying to the
-- player as ID 504856 and to their companion as ID 505217). When either is self-only, all are.
function BuffMe_MarkSelfOnly(key)
    local entry = BuffMeCharDB.spells[key]
    if entry and not entry.selfOnly then
        entry.selfOnly = true
        BuffMe_Debug("Marked self-only: \"" .. entry.name .. "\"")
        local sameName = entry.name
        for otherKey, otherEntry in pairs(BuffMeCharDB.spells) do
            if otherKey ~= key and otherEntry.name == sameName and not otherEntry.selfOnly then
                otherEntry.selfOnly = true
                BuffMe_Debug("Co-marked self-only: \"" .. otherEntry.name ..
                    "\" (key " .. tostring(otherKey) .. ")")
            end
        end
        return true
    end
    return false
end

-- Mark a spell ineligible for auto-buffing (hostile-target requirement, cooldown, etc.).
-- Persists in SavedVariables so the decision survives reloads.
function BuffMe_MarkIneligible(key, reason)
    local entry = BuffMeCharDB.spells[key]
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
    local tg1 = BuffMeCharDB.auraToTypeGroup[n1]
    local tg2 = BuffMeCharDB.auraToTypeGroup[n2]

    if not tg1 or not tg2 or tg1 == tg2 then return end

    BuffMe_Debug("TypeGroup merge: \"" .. tg2 .. "\" folded into \"" .. tg1 .. "\" (via " .. auraName1 .. " vs " .. auraName2 .. ")")

    -- Merge tg2 into tg1 (tg1 is canonical)
    local members = BuffMeCharDB.typeGroupMembers[tg2] or {}
    BuffMeCharDB.typeGroupMembers[tg1] = BuffMeCharDB.typeGroupMembers[tg1] or {}
    for _, aura in ipairs(members) do
        BuffMeCharDB.auraToTypeGroup[aura] = tg1
        local found = false
        for _, existing in ipairs(BuffMeCharDB.typeGroupMembers[tg1]) do
            if existing == aura then found = true; break end
        end
        if not found then
            table.insert(BuffMeCharDB.typeGroupMembers[tg1], aura)
        end
    end
    BuffMeCharDB.typeGroupMembers[tg2] = nil

    -- Migrate per-target cast preferences so lookups against tg1 find entries
    -- that were recorded under tg2 before the merge. Don't overwrite tg1 entries
    -- (tg1's preferences are more recent / more canonical).
    local src = BuffMeCharDB.lastCastForGroup[tg2]
    if src then
        local dst = BuffMeCharDB.lastCastForGroup[tg1] or {}
        BuffMeCharDB.lastCastForGroup[tg1] = dst
        for target, key in pairs(src) do
            if not dst[target] then dst[target] = key end
        end
        BuffMeCharDB.lastCastForGroup[tg2] = nil
    end
end

-- Link two spell IDs into the same targetGroup (they are mutually exclusive on any single target)
function BuffMe_LinkTargetGroup(spellId1, spellId2, groupName)
    groupName = groupName
        or BuffMeCharDB.spellToTargetGroup[spellId1]
        or BuffMeCharDB.spellToTargetGroup[spellId2]
        or tostring(spellId1)

    for _, sid in ipairs({ spellId1, spellId2 }) do
        local oldGroup = BuffMeCharDB.spellToTargetGroup[sid]
        if oldGroup and oldGroup ~= groupName then
            -- Migrate all members of the old group into the new group
            local members = BuffMeCharDB.targetGroupMembers[oldGroup] or {}
            BuffMeCharDB.targetGroupMembers[groupName] = BuffMeCharDB.targetGroupMembers[groupName] or {}
            for _, memberSid in ipairs(members) do
                BuffMeCharDB.spellToTargetGroup[memberSid] = groupName
                local found = false
                for _, m in ipairs(BuffMeCharDB.targetGroupMembers[groupName]) do
                    if m == memberSid then found = true; break end
                end
                if not found then
                    table.insert(BuffMeCharDB.targetGroupMembers[groupName], memberSid)
                end
            end
            BuffMeCharDB.targetGroupMembers[oldGroup] = nil
        end

        BuffMeCharDB.spellToTargetGroup[sid] = groupName
        BuffMeCharDB.targetGroupMembers[groupName] = BuffMeCharDB.targetGroupMembers[groupName] or {}
        local found = false
        for _, m in ipairs(BuffMeCharDB.targetGroupMembers[groupName]) do
            if m == sid then found = true; break end
        end
        if not found then
            table.insert(BuffMeCharDB.targetGroupMembers[groupName], sid)
        end
    end
end

-- Link two spell IDs into the same playerGroup (only one can be active on the caster at a time)
function BuffMe_LinkPlayerGroup(spellId1, spellId2, groupName)
    groupName = groupName
        or BuffMeCharDB.spellToPlayerGroup[spellId1]
        or BuffMeCharDB.spellToPlayerGroup[spellId2]
        or ("pg_" .. tostring(spellId1))

    for _, sid in ipairs({ spellId1, spellId2 }) do
        BuffMeCharDB.spellToPlayerGroup[sid] = groupName
        BuffMeCharDB.playerGroupMembers[groupName] = BuffMeCharDB.playerGroupMembers[groupName] or {}
        local found = false
        for _, m in ipairs(BuffMeCharDB.playerGroupMembers[groupName]) do
            if m == sid then found = true; break end
        end
        if not found then
            table.insert(BuffMeCharDB.playerGroupMembers[groupName], sid)
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
    local ourTG     = BuffMeCharDB.auraToTypeGroup[ourNormal]
    if ourTG then
        i = 1
        while true do
            local buffName = UnitBuff(targetUnit, i)
            if not buffName then break end
            local buffTG = BuffMeCharDB.auraToTypeGroup[BuffMe_NormalizeName(buffName)]
            if buffTG and buffTG == ourTG then
                return buffName
            end
            i = i + 1
        end
    end

    -- Pass 3: tooltip signature matching — catches name-dissimilar same-effect spells
    -- (e.g. "Grove Instinct" blocked by "Whispers of Y'shaarj": identical body text, higher numbers)
    local ourEntry = nil
    for _, entry in pairs(BuffMeCharDB.spells) do
        if entry.name == ourSpellName then
            ourEntry = entry
            break
        end
    end
    if ourEntry then
        local ourSig = BuffMe_GetOurSpellInfo(ourEntry)
        if ourSig and ourSig ~= "" then
            i = 1
            while true do
                local buffName = UnitBuff(targetUnit, i)
                if not buffName then break end
                local buffSig = BuffMe_GetUnitBuffInfo(targetUnit, i)
                if buffSig == ourSig then
                    BuffMe_Debug("Tooltip match: \"" .. buffName .. "\" blocks \"" .. ourSpellName .. "\" (sig: " .. ourSig .. ")")
                    return buffName
                end
                i = i + 1
            end
        end
    end

    return nil
end

-- Register an aura (castable or external) into an effect group keyed by tooltip signature.
-- typeGroup links the effect group back to the optimizer's typeGroup system.
-- value is the primary numeric value extracted from the tooltip (for strength comparison).
function BuffMe_RegisterInEffectGroup(sig, typeGroup, normalName, displayName, value)
    if not sig or sig == "" or not typeGroup or not normalName then return end
    local group = BuffMeCharDB.effectGroups[sig]
    if not group then
        group = { typeGroup = typeGroup, members = {} }
        BuffMeCharDB.effectGroups[sig] = group
    end
    group.members[normalName] = { name = displayName, value = value or 0 }
end

function BuffMe_RegisterAuraInTypeGroup(auraName, typeGroup)
    local n = BuffMe_NormalizeName(auraName)
    if BuffMeCharDB.auraToTypeGroup[n] then return end
    BuffMeCharDB.auraToTypeGroup[n] = typeGroup
    BuffMeCharDB.auraDisplayNames[n] = auraName  -- preserve original name for UI display
    local members = BuffMeCharDB.typeGroupMembers[typeGroup]
    if members then
        local found = false
        for _, m in ipairs(members) do if m == n then found = true; break end end
        if not found then table.insert(members, n) end
    end
end

-- Scan buff lists for tooltip sigs that match known effect groups, registering any
-- newly-discovered external auras into the matching group and typeGroup.
-- Pass a specific unit token to scan just that unit, or nil to scan all party members.
-- Called passively on UNIT_AURA and PARTY_MEMBERS_CHANGED so we discover weaker/equivalent
-- external effects (e.g. another player's "Earthen Endurance" sharing Grove Instinct's sig)
-- without waiting for a cast error to reveal them.
function BuffMe_ScanPartyForEffectGroups(specificUnit)
    if not next(BuffMeCharDB.effectGroups) then return end

    -- Build reverse index of normalNames already in some effectGroup (built once per call)
    local knownInEG = {}
    for _, egEntry in pairs(BuffMeCharDB.effectGroups) do
        for normalName in pairs(egEntry.members) do
            knownInEG[normalName] = true
        end
    end

    local units = specificUnit
        and { specificUnit }
        or { "player", "party1", "party2", "party3", "party4" }

    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local i = 1
            while true do
                local buffName = UnitBuff(unit, i)
                if not buffName then break end
                local normalName = BuffMe_NormalizeName(buffName)
                if not knownInEG[normalName] then
                    local sig, value = BuffMe_GetUnitBuffInfo(unit, i)
                    if sig and sig ~= "" then
                        local egEntry = BuffMeCharDB.effectGroups[sig]
                        if egEntry then
                            BuffMe_RegisterInEffectGroup(sig, egEntry.typeGroup, normalName, buffName, value)
                            BuffMe_RegisterAuraInTypeGroup(buffName, egEntry.typeGroup)
                            knownInEG[normalName] = true
                            BuffMe_Debug("Effect group match (passive): \"" .. buffName ..
                                "\" → typeGroup \"" .. egEntry.typeGroup .. "\" on " .. unit)
                        end
                    end
                end
                i = i + 1
            end
        end
    end
end

-- Return all spell entries that are currently castable: known, eligible, and off cooldown.
-- Cooldown is checked by spell NAME (not numeric ID) because on Ascension the cast spell
-- ID and the buff aura ID often differ — name-based lookup reliably finds the cast spell.
function BuffMe_GetKnownBuffSpells()
    local result = {}
    for key, entry in pairs(BuffMeCharDB.spells) do
        if not entry.ineligible then
            local available
            if type(key) == "number" then
                available = GetSpellInfo(key) ~= nil
            else
                available = GetSpellInfo(entry.name) ~= nil
            end
            if available then
                -- IsHarmfulSpell catches quest-item abilities (e.g. "Thrown Torch") that
                -- target enemies and slipped into the DB before the CLEU friendly-dest guard
                -- was added. Mark ineligible on first encounter so future sessions skip them.
                if IsHarmfulSpell(entry.name) then
                    entry.ineligible = true
                    BuffMe_Debug("Marked ineligible (harmful spell): \"" .. entry.name .. "\"")
                else
                    -- Skip spells currently on a real cooldown (longer than the GCD).
                    -- Using spell name instead of ID because Ascension's cast and aura
                    -- spell IDs often differ; name-based lookup always finds the cast spell.
                    local start, duration = GetSpellCooldown(entry.name)
                    local onCooldown = start and start > 0 and duration and duration > 1.5
                    if not onCooldown then
                        table.insert(result, entry)
                    end
                    -- Re-register in effectGroups on each scan (idempotent) so that if
                    -- the sig was captured after the last registration it gets indexed.
                    local sig, value = BuffMe_GetOurSpellInfo(entry)
                    if sig and sig ~= "" then
                        local normalAura = BuffMe_NormalizeName(entry.auraName)
                        local tg = BuffMeCharDB.auraToTypeGroup[normalAura]
                        if tg then
                            BuffMe_RegisterInEffectGroup(sig, tg, normalAura, entry.auraName, value)
                        end
                    end
                end
            end
        end
    end
    return result
end
