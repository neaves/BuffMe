-- Normalize an aura/spell name to a stable key: lowercase, letters and digits only
function BuffMe_NormalizeName(name)
    return name:lower():gsub("[^%a%d]", "")
end

-- Learn Mode (config: BuffMeDB.learnMode, default ON) gates whether BuffMe auto-registers
-- NEW spells/typeGroups/effectGroups beyond the shipped SpellDB.lua baseline. It never
-- gates behavioral safety corrections (selfOnly/partyOnly/ineligible flags) or per-target
-- cast preferences — those keep updating live regardless, since they're corrections to
-- already-known spells, not new discovery. See SpellDB.lua for the full rationale.
function BuffMe_LearnModeEnabled()
    return not BuffMeDB or BuffMeDB.learnMode ~= false
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

-- Split a pipe-joined sig into an ordered array of lines, plus its line count.
local function SigLines(sig)
    local lines, count = {}, 0
    for line in (sig .. "|"):gmatch("(.-)|") do
        if line ~= "" then
            count = count + 1
            lines[count] = line
        end
    end
    return lines, count
end

-- Filler/connector words inside tooltip lines that must never count toward a
-- "shared effect" line match on their own (e.g. "by", "and", "all" appear in nearly
-- every stat-buff tooltip regardless of which stats are actually affected).
local LINE_STOPWORDS = {
    ["by"] = true, ["and"] = true, ["all"] = true, ["the"] = true, ["a"] = true,
    ["an"] = true, ["for"] = true, ["your"] = true, ["you"] = true, ["are"] = true,
    ["is"] = true, ["to"] = true, ["of"] = true, ["with"] = true, ["at"] = true,
}

-- Tokenize a normalized tooltip line into a word->count multiset, dropping stopwords.
local function LineTokenCounts(line)
    local counts, n = {}, 0
    for word in line:gmatch("[%a#]+") do
        if not LINE_STOPWORDS[word] then
            counts[word] = (counts[word] or 0) + 1
            n = n + 1
        end
    end
    return counts, n
end

-- true if every token in `small` appears in `big` with at least as high a count.
local function TokensSubsetOf(small, big)
    for word, cnt in pairs(small) do
        if (big[word] or 0) < cnt then return false end
    end
    return true
end

-- Two tooltip lines describe the same effect if they're identical, one is a
-- contiguous substring of the other, OR every meaningful word of one appears in the
-- other (order-independent). The token check catches a clause *inserted mid-sentence*
-- rather than appended at the end — e.g. "Earthen Endurance" vs "Man'ari Intuition":
--   short: "increases armor by #, all attributes by # and all resistances by #."
--   long:  "increases armor by # and all attributes by #."
-- "all attributes by #" sits in the middle of the long line, so it's never a
-- contiguous substring of the short line (the words right after "armor by #" diverge:
-- "," vs "and") — only a word-level comparison catches it.
local function LinesShareEffect(lineA, lineB)
    if lineA == lineB then return true end
    if lineA:find(lineB, 1, true) or lineB:find(lineA, 1, true) then return true end
    local countsA, nA = LineTokenCounts(lineA)
    local countsB, nB = LineTokenCounts(lineB)
    if nA == 0 or nB == 0 then return false end
    return TokensSubsetOf(countsA, countsB) or TokensSubsetOf(countsB, countsA)
end

-- Two sigs are considered the same effect if they're identical, or if every line of the
-- shorter one shares its effect (per LinesShareEffect) with some unused line of the
-- longer one, within a small line-count gap.
local MAX_SIG_LINE_GAP = 2
function BuffMe_SigsMatch(sigA, sigB)
    if sigA == sigB then return true end
    if not sigA or sigA == "" or not sigB or sigB == "" then return false end
    local linesA, nA = SigLines(sigA)
    local linesB, nB = SigLines(sigB)
    if nA == 0 or nB == 0 then return false end
    if math.abs(nA - nB) > MAX_SIG_LINE_GAP then return false end
    local small, big = linesA, linesB
    if nA > nB then small, big = linesB, linesA end
    local usedBig = {}
    for _, sLine in ipairs(small) do
        local matched = false
        for bi, bLine in ipairs(big) do
            if not usedBig[bi] and LinesShareEffect(sLine, bLine) then
                usedBig[bi] = true
                matched = true
                break
            end
        end
        if not matched then return false end
    end
    return true
end

-- Look up an effectGroups entry for a sig: exact key match first, falling back to a
-- partial (subset-of-lines) scan via BuffMe_SigsMatch. Returns the matched entry and the
-- canonical sig it's stored under (so callers register new members under the existing key
-- instead of creating a near-duplicate effectGroups entry).
function BuffMe_FindEffectGroup(sig)
    if not sig or sig == "" then return nil, nil end
    local exact = BuffMeCharDB.effectGroups[sig]
    if exact then return exact, sig end
    for existingSig, egEntry in pairs(BuffMeCharDB.effectGroups) do
        if BuffMe_SigsMatch(sig, existingSig) then
            return egEntry, existingSig
        end
    end
    return nil, nil
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

-- Filler/connector words that appear across unrelated spell names and must never
-- count as a "shared keyword" (e.g. "Presence of X" vs "Whispers of X" both contain
-- "of" but are unrelated effects). A pure length cutoff was tried first but it also
-- discarded short, distinctive family words like "Vow" (Vow of Grace/Light/Radiance),
-- which prevented those mutually-exclusive spells from ever being recognized as related.
-- "greater"/"lesser" are magnitude prefixes reused across dozens of unrelated buff
-- families on this server (Greater Essence of Nature, Greater Primal Instinct, Greater
-- Rite of Power, ...) — confirmed in a real raid (2026-08-03) that treating "greater" as
-- a meaningful keyword caused "Greater Whispers of N'zoth" to pre-group into the
-- "essenceofnature" typeGroup (its only shared word with "Essence of Nature" was
-- "greater"), and separately caused a same-frame buff-bar diff to merge "Greater Rite of
-- Power" with "Greater Primal Instinct" — two completely unrelated effects sharing
-- nothing else in their names.
local NAME_STOPWORDS = {
    ["of"] = true, ["the"] = true, ["and"] = true, ["for"] = true,
    ["you"] = true, ["your"] = true, ["are"] = true, ["now"] = true,
    ["greater"] = true, ["lesser"] = true,
}

-- Extract meaningful keywords (2+ letters, minus filler words) from a spell/buff name
local function GetNameKeywords(name)
    local keywords = {}
    for word in name:lower():gmatch("%a+") do
        if #word > 2 and not NAME_STOPWORDS[word] then
            keywords[word] = true
        end
    end
    return keywords
end

-- Returns true if name1 and name2 share at least one meaningful keyword.
-- Also exposed as BuffMe_KeywordOverlap for use in BuffMe.lua gate checks.
local function KeywordOverlap(name1, name2)
    local kw1 = GetNameKeywords(name1)
    for word in name2:lower():gmatch("%a+") do
        if #word > 2 and not NAME_STOPWORDS[word] and kw1[word] then
            return true
        end
    end
    return false
end
function BuffMe_KeywordOverlap(name1, name2) return KeywordOverlap(name1, name2) end

-- Wipe all learned spell data, preserving config settings and the diagnostic log.
-- Use this to evict stale entries (e.g. proc-registered spells) and start fresh.
-- The official SpellDB.lua baseline (spells/typeGroups/effectGroups verified good enough
-- to ship) is reloaded immediately after wiping, so a reset only discards in-progress
-- live-learned data, not the shipped ground truth.
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
    BuffMe_LoadOfficialDB()
end

-- Merge the shipped official spell/typeGroup/effectGroup baseline (SpellDB.lua) into this
-- character's learned DB. Runs every login regardless of Learn Mode — Learn Mode only
-- gates whether NEW spells/typeGroups/effectGroups get added beyond this baseline (see
-- BuffMe_RegisterSpell, BuffMe_MergeTypeGroups, BuffMe_RegisterInEffectGroup). Never
-- overwrites data the character has already learned/customized; official data only fills
-- gaps, so a hand-tuned priority or an already-discovered relationship always wins.
--
-- BuffMe_OfficialDB is keyed by realm name (GetRealmName()): "Classic" and "Conquest of
-- Azeroth" ruleset realms run non-overlapping spell sets, and Wildcard realms draw random
-- per-character spellbooks that would corrupt a shared baseline entirely — so there is no
-- realm-agnostic bucket, only per-realm ones populated by hand (see SpellDB.lua header).
-- A realm with no baseline entry yet (including any Wildcard realm) simply merges nothing
-- and falls back to pure Learn Mode discovery.
function BuffMe_LoadOfficialDB()
    local official = BuffMe_OfficialDB and BuffMe_OfficialDB[GetRealmName()]
    if not official then return end

    for spellId, off in pairs(official.spells or {}) do
        if not BuffMeCharDB.spells[spellId] then
            BuffMeCharDB.spells[spellId] = {
                spellId      = spellId,
                name         = off.name,
                auraName     = off.auraName or off.name,
                priority     = off.priority or 5,
                tooltipSig   = off.tooltipSig,
                tooltipValue = off.tooltipValue,
                selfOnly     = off.selfOnly or nil,
                partyOnly    = off.partyOnly or nil,
                ineligible   = off.ineligible or nil,
            }
            BuffMeCharDB.nameToKey[off.name] = spellId
            BuffMeCharDB.auraDisplayNames[BuffMe_NormalizeName(off.auraName or off.name)] = off.auraName or off.name
        end
    end

    for normalAura, typeGroup in pairs(official.auraToTypeGroup or {}) do
        if not BuffMeCharDB.auraToTypeGroup[normalAura] then
            BuffMeCharDB.auraToTypeGroup[normalAura] = typeGroup
            local members = BuffMeCharDB.typeGroupMembers[typeGroup]
            if not members then
                members = {}
                BuffMeCharDB.typeGroupMembers[typeGroup] = members
            end
            local found = false
            for _, m in ipairs(members) do if m == normalAura then found = true; break end end
            if not found then table.insert(members, normalAura) end
        end
    end

    for sig, offGroup in pairs(official.effectGroups or {}) do
        local group = BuffMeCharDB.effectGroups[sig]
        if not group then
            group = { typeGroup = offGroup.typeGroup, members = {} }
            BuffMeCharDB.effectGroups[sig] = group
        end
        for normalName, memberData in pairs(offGroup.members or {}) do
            if not group.members[normalName] then
                group.members[normalName] = { name = memberData.name, value = memberData.value or 0 }
            end
        end
    end
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
    if BuffMeDB.showTooltip         == nil then BuffMeDB.showTooltip         = true  end
    if BuffMeDB.greyWhenIdle        == nil then BuffMeDB.greyWhenIdle        = false end
    if BuffMeDB.idleOpacity         == nil then BuffMeDB.idleOpacity         = 1.0   end
    -- Learn Mode defaults ON until SpellDB.lua's official baseline is built out enough
    -- that most players never need live discovery at all. See BuffMe_LearnModeEnabled.
    if BuffMeDB.learnMode           == nil then BuffMeDB.learnMode           = true  end
    -- [typeGroup] = user-chosen display name; overlays the auto-generated typeGroup
    -- key in the UI only (matching/learning logic keeps using the real key).
    BuffMeDB.typeGroupDisplayNames = BuffMeDB.typeGroupDisplayNames or {}

    -- Per-character spell learning data, stored inside BuffMeDB keyed by character name.
    -- Ascension's /reload only flushes SavedVariables (BuffMeDB), not
    -- SavedVariablesPerCharacter (BuffMeCharDB). Storing per-char data inside BuffMeDB
    -- ensures it survives every /reload, not just proper logouts.
    local charName = UnitName("player") or "Unknown"
    BuffMeDB.chars = BuffMeDB.chars or {}
    -- One-time migration: copy existing per-character SavedVariables data into BuffMeDB
    -- so nothing is lost on the first load after this change.
    if not BuffMeDB.chars[charName] then
        BuffMeDB.chars[charName] = (BuffMeCharDB and next(BuffMeCharDB)) and BuffMeCharDB or {}
    end
    -- Alias: all code that reads/writes BuffMeCharDB now writes into BuffMeDB.chars[charName].
    BuffMeCharDB = BuffMeDB.chars[charName]
    -- Realm + class, refreshed every login. Used to key the official baseline
    -- (BuffMe_OfficialDB, see BuffMe_LoadOfficialDB) and, more importantly, to let the
    -- promotion tooling (Tools/Export-BuffMeDB.ps1) identify and exclude Wildcard
    -- characters (classToken "HERO") from SpellDB.lua — Wildcard spellbooks are drawn
    -- per-character at random, so one hero's learned spellGroups are meaningless (and
    -- actively misleading) for every other character on the account.
    BuffMeCharDB.realm = GetRealmName()
    local _, classToken = UnitClass("player")
    BuffMeCharDB.classToken = classToken
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
    -- [typeGroup] = true; learned when a spell's aura is observed moving from one
    -- destGUID to a different destGUID on the same cast (server allows only one live
    -- instance anywhere, e.g. "Bless"). The optimizer treats these typeGroups as
    -- covered party-wide once any unit has them, instead of per-unit.
    BuffMeCharDB.globalTypeGroups = BuffMeCharDB.globalTypeGroups or {}
    -- Unconfirmed "these two buffs displace each other" pairs, detected passively when one
    -- buff disappears the same instant another with a matching tooltip appears on the same
    -- unit. Held for user review (Candidate Merges panel) rather than auto-merged, since the
    -- units involved aren't the player's own confirmed casts.
    -- { key, nameA, nameB, unit, firstSeen, seenCount }
    BuffMeCharDB.candidatePairs = BuffMeCharDB.candidatePairs or {}
    -- [pairKey] = true; pairs the user explicitly rejected, never re-suggested
    BuffMeCharDB.rejectedPairs  = BuffMeCharDB.rejectedPairs  or {}
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

    -- One-time repair (2026-08-04): a real 16-person raid corrupted the "essenceofnature"
    -- typeGroup via two independent bugs, both now fixed at the source but already baked
    -- into saved data. Confirmed via diagnosticLog:
    --   1) A CLEU-less pendingCast resolution mis-attributed an EXTERNAL buff landing on the
    --      player ("Greater Whispers of N'zoth", cast by other raid members) as the aura
    --      produced by the player's own "Greater Grove Instinct" cast, because both changes
    --      landed in the same UNIT_AURA diff. The synthetic "__Greater Grove Instinct" entry's
    --      auraName is factually wrong — removed so it re-learns cleanly from a clean cast.
    --   2) "greater" was treated as a meaningful keyword (see NAME_STOPWORDS above), so
    --      "Greater Primal Instinct" got pre-grouped into "essenceofnature" via "Greater
    --      Essence of Nature" alone. General repair: re-derive every known spell's typeGroup
    --      from its own captured tooltipSig (authoritative, generalized tooltip matching)
    --      rather than trusting a possibly keyword-corrupted auraToTypeGroup assignment.
    if not BuffMeCharDB.greaterKeywordRepairV1 then
        local badKey   = "__Greater Grove Instinct"
        local badEntry = BuffMeCharDB.spells[badKey]
        if badEntry and badEntry.auraName == "Greater Whispers of N'zoth" then
            local normalAura = BuffMe_NormalizeName(badEntry.auraName)
            local tg = BuffMeCharDB.auraToTypeGroup[normalAura]
            if tg then
                local members = BuffMeCharDB.typeGroupMembers[tg]
                if members then
                    for i, m in ipairs(members) do
                        if m == normalAura then table.remove(members, i); break end
                    end
                end
                BuffMeCharDB.auraToTypeGroup[normalAura] = nil
            end
            if badEntry.tooltipSig then
                local eg = BuffMeCharDB.effectGroups[badEntry.tooltipSig]
                if eg then
                    eg.members[normalAura] = nil
                    if not next(eg.members) then
                        BuffMeCharDB.effectGroups[badEntry.tooltipSig] = nil
                    end
                end
            end
            BuffMeCharDB.nameToKey[badEntry.name] = nil
            BuffMeCharDB.auraDisplayNames[normalAura] = nil
            BuffMeCharDB.spells[badKey] = nil
            BuffMe_Debug("Repair: removed mis-registered \"" .. badKey ..
                "\" (auraName was actually another player's buff)")
        end

        for _, entry in pairs(BuffMeCharDB.spells) do
            if entry.tooltipSig and entry.tooltipSig ~= "" then
                local egEntry = BuffMe_FindEffectGroup(entry.tooltipSig)
                if egEntry then
                    local normalAura = BuffMe_NormalizeName(entry.auraName)
                    local oldTG = BuffMeCharDB.auraToTypeGroup[normalAura]
                    local newTG = egEntry.typeGroup
                    if oldTG and oldTG ~= newTG then
                        local oldMembers = BuffMeCharDB.typeGroupMembers[oldTG]
                        if oldMembers then
                            for i, m in ipairs(oldMembers) do
                                if m == normalAura then table.remove(oldMembers, i); break end
                            end
                        end
                        BuffMeCharDB.auraToTypeGroup[normalAura] = newTG
                        local newMembers = BuffMeCharDB.typeGroupMembers[newTG]
                        if newMembers then
                            local found = false
                            for _, m in ipairs(newMembers) do
                                if m == normalAura then found = true; break end
                            end
                            if not found then table.insert(newMembers, normalAura) end
                        end
                        BuffMe_Debug("Repair: moved \"" .. entry.auraName .. "\" from typeGroup \"" ..
                            oldTG .. "\" to \"" .. newTG .. "\" (tooltip sig disagreed)")
                    end
                end
            end
        end

        -- A candidate pair recommending a merge that's already true (or became true via the
        -- repair above) is just noise — drop any pair whose two sides already share a typeGroup.
        for i = #BuffMeCharDB.candidatePairs, 1, -1 do
            local p   = BuffMeCharDB.candidatePairs[i]
            local tgA = BuffMeCharDB.auraToTypeGroup[BuffMe_NormalizeName(p.nameA)]
            local tgB = BuffMeCharDB.auraToTypeGroup[BuffMe_NormalizeName(p.nameB)]
            if tgA and tgA == tgB then
                table.remove(BuffMeCharDB.candidatePairs, i)
            end
        end

        BuffMeCharDB.greaterKeywordRepairV1 = true
    end

    BuffMe_LoadOfficialDB()
end

-- Returns the user-chosen display name for a typeGroup, or the raw key if unset.
function BuffMe_GetGroupDisplayName(tg)
    local custom = BuffMeDB and BuffMeDB.typeGroupDisplayNames and BuffMeDB.typeGroupDisplayNames[tg]
    if custom and custom ~= "" then return custom end
    return tg
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
    -- Mounting fires SPELL_AURA_APPLIED/UNIT_AURA exactly like any other self-buff, so a
    -- mount would otherwise get registered as a castable "buff spell" — and then every
    -- other party member's different mount tooltip-matches into the same effect group via
    -- the shared "increases ground speed by #%." signature (observed: 11-member
    -- battletestedcresthorn typeGroup). IsMounted() is true by the time either registration
    -- call site (CLEU SPELL_AURA_APPLIED, UNIT_AURA fallback) observes the new aura, since
    -- the mounted state and the aura land together — skip registration outright rather than
    -- marking ineligible, so mounts never enter spells/auraToTypeGroup/effectGroups at all.
    if IsMounted() then
        BuffMe_Debug("Skipped registration (mount): \"" .. spellName .. "\"")
        return
    end
    if not BuffMe_LearnModeEnabled() then
        BuffMe_Debug("Learn mode off: skipping registration of unknown spell \"" .. spellName .. "\"")
        return
    end

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

-- Mark a spell as party-member-only: it can only be validly cast on "player" or a
-- partyN unit, never the current non-party friendly "target". Detected when casting on
-- a non-party target leaves the manual targeting cursor active with no CLEU/aura/UI_ERROR
-- response — the server silently rejects the target instead of returning an error, so the
-- client falls back to click-to-cast mode instead of failing the cast outright.
-- Persists in SavedVariables; the optimizer will never offer the "target" unit for it again.
-- Propagates to same-named entries under other keys, mirroring BuffMe_MarkSelfOnly.
function BuffMe_MarkPartyOnly(key)
    local entry = BuffMeCharDB.spells[key]
    if entry and not entry.partyOnly then
        entry.partyOnly = true
        BuffMe_Debug("Marked party-only: \"" .. entry.name .. "\"")
        local sameName = entry.name
        for otherKey, otherEntry in pairs(BuffMeCharDB.spells) do
            if otherKey ~= key and otherEntry.name == sameName and not otherEntry.partyOnly then
                otherEntry.partyOnly = true
                BuffMe_Debug("Co-marked party-only: \"" .. otherEntry.name ..
                    "\" (key " .. tostring(otherKey) .. ")")
            end
        end
        return true
    end
    return false
end

-- Mark a spell as group-cast: a single self-targeted cast applies the aura to every
-- party/raid member simultaneously (e.g. "Greater" blessings), regardless of line of
-- sight. Detected when a CLEU SPELL_AURA_APPLIED batch from one cast lands on 2+ distinct
-- destGUIDs including the player. The optimizer still evaluates coverage per-unit as
-- normal (each member gets a real aura instance, so gaps are detected correctly), but the
-- actual cast must always target "player" — these spells reject/ignore any other target.
-- Propagates to same-named entries under other keys, mirroring BuffMe_MarkSelfOnly.
function BuffMe_MarkGroupCast(key)
    local entry = BuffMeCharDB.spells[key]
    if entry and not entry.groupCast then
        entry.groupCast = true
        BuffMe_Debug("Marked group-cast: \"" .. entry.name .. "\"")
        local sameName = entry.name
        for otherKey, otherEntry in pairs(BuffMeCharDB.spells) do
            if otherKey ~= key and otherEntry.name == sameName and not otherEntry.groupCast then
                otherEntry.groupCast = true
                BuffMe_Debug("Co-marked group-cast: \"" .. otherEntry.name ..
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
    if not BuffMe_LearnModeEnabled() then
        BuffMe_Debug("Learn mode off: skipping typeGroup merge (" .. auraName1 .. " vs " .. auraName2 .. ")")
        return
    end

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

-- Order-independent lookup key for a pair of aura names.
local function PairKey(nameA, nameB)
    local nA, nB = BuffMe_NormalizeName(nameA), BuffMe_NormalizeName(nameB)
    if nA > nB then nA, nB = nB, nA end
    return nA .. "|" .. nB
end

-- Record (or bump the seen-count of) a passively-observed "these two displace each other"
-- pair for later user review — see BuffMeCharDB.candidatePairs above. Not gated on Learn
-- Mode: reviewing/accepting is itself the confirmation step, so recording the observation
-- is safe even with Learn Mode off (nothing is auto-registered here).
function BuffMe_RecordCandidatePair(nameA, nameB, unit)
    if not BuffMeCharDB or nameA == nameB then return end
    local key = PairKey(nameA, nameB)
    if BuffMeCharDB.rejectedPairs[key] then return end
    -- Already linked into the same typeGroup — nothing left to review.
    local tgA = BuffMeCharDB.auraToTypeGroup[BuffMe_NormalizeName(nameA)]
    local tgB = BuffMeCharDB.auraToTypeGroup[BuffMe_NormalizeName(nameB)]
    if tgA and tgA == tgB then return end

    for _, p in ipairs(BuffMeCharDB.candidatePairs) do
        if p.key == key then
            p.seenCount = (p.seenCount or 1) + 1
            p.lastSeen  = date("%H:%M:%S")
            return
        end
    end
    table.insert(BuffMeCharDB.candidatePairs, {
        key = key, nameA = nameA, nameB = nameB, unit = unit,
        firstSeen = date("%H:%M:%S"), seenCount = 1,
    })
    BuffMe_Debug("Candidate pair recorded: \"" .. nameA .. "\" <-> \"" .. nameB .. "\" on " .. tostring(unit))
end

-- Accept a candidate pair: link both auras into the same typeGroup (creating one if neither
-- side has one yet), then drop it from the review queue.
function BuffMe_AcceptCandidatePair(key)
    if not BuffMeCharDB then return end
    for i, p in ipairs(BuffMeCharDB.candidatePairs) do
        if p.key == key then
            local nA, nB = BuffMe_NormalizeName(p.nameA), BuffMe_NormalizeName(p.nameB)
            local tgA = BuffMeCharDB.auraToTypeGroup[nA]
            local tgB = BuffMeCharDB.auraToTypeGroup[nB]
            if tgA and tgB then
                BuffMe_MergeTypeGroups(p.nameA, p.nameB)
            elseif tgA then
                BuffMe_RegisterAuraInTypeGroup(p.nameB, tgA)
            elseif tgB then
                BuffMe_RegisterAuraInTypeGroup(p.nameA, tgB)
            else
                local newTG = nA
                BuffMeCharDB.typeGroupMembers[newTG] = BuffMeCharDB.typeGroupMembers[newTG] or {}
                BuffMe_RegisterAuraInTypeGroup(p.nameA, newTG)
                BuffMe_RegisterAuraInTypeGroup(p.nameB, newTG)
            end
            BuffMe_Debug("Candidate pair accepted: \"" .. p.nameA .. "\" + \"" .. p.nameB .. "\"")
            table.remove(BuffMeCharDB.candidatePairs, i)
            return
        end
    end
end

-- Reject a candidate pair: drop it and remember not to re-suggest it.
function BuffMe_RejectCandidatePair(key)
    if not BuffMeCharDB then return end
    BuffMeCharDB.rejectedPairs[key] = true
    for i, p in ipairs(BuffMeCharDB.candidatePairs) do
        if p.key == key then
            table.remove(BuffMeCharDB.candidatePairs, i)
            return
        end
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
                if BuffMe_SigsMatch(buffSig, ourSig) then
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
        -- Creating a brand-new effect group is "new discovery" — gated by Learn Mode.
        -- Adding a member to an already-known group (below) is not; it always runs.
        if not BuffMe_LearnModeEnabled() then
            BuffMe_Debug("Learn mode off: skipping new effect group for \"" .. displayName .. "\"")
            return
        end
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

-- Returns every unit token BuffMe should watch: raid1..N when in a raid (WotLK has no
-- party1-4 tokens once you're grouped as a raid), otherwise player + party1-4.
function BuffMe_GetTrackedUnits()
    local raidSize = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raidSize and raidSize > 0 then
        local units = {}
        for i = 1, raidSize do units[i] = "raid" .. i end
        return units
    end
    local units = { "player" }
    for i = 1, GetNumPartyMembers() do units[#units + 1] = "party" .. i end
    return units
end

-- Substrings (checked against the lowercased tooltip sig) that flag a passively-observed,
-- not-yet-known buff as worth a diagnostic callout — e.g. raid consumables/world buffs that
-- don't overlap with anything the player casts, so they'd otherwise never surface. "reduc"
-- (not "reduce"/"reduced") deliberately catches every inflection in one substring check.
local CANDIDATE_KEYWORDS = { "increase", "restore", "reduc" }

local function SigHasCandidateKeyword(sig)
    for _, kw in ipairs(CANDIDATE_KEYWORDS) do
        if sig:find(kw, 1, true) then return true end
    end
    return false
end

-- Effect-group discovery is split into a cheap enqueue phase (this function — just table
-- lookups over UnitBuff, no tooltip reads) and a throttled batch-drain phase
-- (BuffMe_ProcessScanQueue) that resolves the actual expensive step, one tooltip read per
-- unregistered aura, a handful at a time. Without this split, entering a dungeon with
-- several party members each carrying multiple unrecognized buffs would resolve all of
-- them synchronously in one frame — a visible stutter.
local scanQueue = {}
local scanQueueSeen = {}  -- "unit\0normalName" -> true, de-dupes pending queue entries
-- normalNames already tooltip-read and resolved (matched or dismissed) this session, so
-- ProcessScanQueue never re-reads the same irrelevant buff's tooltip on every rescan.
local scanResolved = {}

-- Scan buff lists for auras not yet known to any effect group and queue them for batched
-- tooltip resolution. Pass a specific unit token to scan just that unit, or nil to scan
-- every tracked unit (raid-wide when in a raid, else party). Called passively on UNIT_AURA
-- and roster-change events so we discover weaker/equivalent external effects (e.g. another
-- player's "Earthen Endurance" sharing Grove Instinct's sig) without waiting for a cast
-- error to reveal them.
function BuffMe_ScanPartyForEffectGroups(specificUnit)
    -- Build reverse index of normalNames already in some effectGroup (built once per call)
    local knownInEG = {}
    for _, egEntry in pairs(BuffMeCharDB.effectGroups) do
        for normalName in pairs(egEntry.members) do
            knownInEG[normalName] = true
        end
    end

    local units = specificUnit and { specificUnit } or BuffMe_GetTrackedUnits()

    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local i = 1
            while true do
                local buffName = UnitBuff(unit, i)
                if not buffName then break end
                local normalName = BuffMe_NormalizeName(buffName)
                if not knownInEG[normalName] and not scanResolved[normalName] then
                    local key = unit .. "\0" .. normalName
                    if not scanQueueSeen[key] then
                        scanQueueSeen[key] = true
                        scanQueue[#scanQueue + 1] = { unit = unit, normalName = normalName }
                    end
                end
                i = i + 1
            end
        end
    end
end

local SCAN_BATCH_SIZE = 50

-- Drains up to SCAN_BATCH_SIZE entries from the discovery queue, doing the actual tooltip
-- read (the expensive part) for each. Called every idle tick from BuffMe.lua's OnUpdate
-- throttle — cheap no-op when the queue is empty, so it costs nothing in the steady state.
function BuffMe_ProcessScanQueue()
    if #scanQueue == 0 then return false end

    local knownInEG = {}
    for _, egEntry in pairs(BuffMeCharDB.effectGroups) do
        for normalName in pairs(egEntry.members) do
            knownInEG[normalName] = true
        end
    end

    local processed = 0
    local matched = false
    while processed < SCAN_BATCH_SIZE and #scanQueue > 0 do
        local job = table.remove(scanQueue, 1)
        scanQueueSeen[job.unit .. "\0" .. job.normalName] = nil
        processed = processed + 1

        if UnitExists(job.unit) and not knownInEG[job.normalName] then
            -- Re-locate the buff's current index — it may have shifted or the aura may
            -- have expired since it was enqueued; a stale index would read the wrong buff.
            local i = 1
            while true do
                local buffName = UnitBuff(job.unit, i)
                if not buffName then break end
                if BuffMe_NormalizeName(buffName) == job.normalName then
                    local sig, value = BuffMe_GetUnitBuffInfo(job.unit, i)
                    if sig and sig ~= "" then
                        local egEntry, matchedSig = BuffMe_FindEffectGroup(sig)
                        if egEntry then
                            BuffMe_RegisterInEffectGroup(matchedSig, egEntry.typeGroup, job.normalName, buffName, value)
                            BuffMe_RegisterAuraInTypeGroup(buffName, egEntry.typeGroup)
                            BuffMe_Debug("Effect group match (passive): \"" .. buffName ..
                                "\" → typeGroup \"" .. egEntry.typeGroup .. "\" on " .. job.unit)
                            matched = true
                        elseif SigHasCandidateKeyword(sig) then
                            -- Doesn't match anything we already track, but its tooltip reads
                            -- like a stat buff/debuff worth reviewing as a new spell group
                            -- candidate (e.g. a raid consumable or another class's buff).
                            BuffMe_Debug("Candidate spell group: \"" .. buffName .. "\" on " ..
                                job.unit .. " — sig: " .. sig)
                        end
                        scanResolved[job.normalName] = true
                    end
                    break
                end
                i = i + 1
            end
        end
    end

    return matched
end

-- Return all spell entries that are currently castable: known, eligible, and off cooldown.
-- Cooldown is checked by spell NAME (not numeric ID) because on Ascension the cast spell
-- ID and the buff aura ID often differ — name-based lookup reliably finds the cast spell.
function BuffMe_GetKnownBuffSpells()
    local result = {}
    for key, entry in pairs(BuffMeCharDB.spells) do
        if not entry.ineligible then
            -- IsSpellKnown(id) checks the client's live "known spells" list, which is
            -- updated by the server on spec/talent changes. Unlike GetSpellInfo, it
            -- returns nil for spells that exist in the game database but that the player
            -- doesn't currently know — exactly what we need for spec-change filtering.
            -- Ascension's GetNumSpellTabs() always returns 0 (custom spellbook UI), so
            -- spellbook-scan approaches don't work here; IsSpellKnown operates at a
            -- lower level and is populated by standard learn/unlearn server packets.
            --
            -- For synthetic keys ("__SpellName"): no numeric ID is available, so fall
            -- back to GetSpellInfo. These are edge-case spells where CLEU never gave us
            -- an ID; spec-awareness for them is best-effort.
            local available
            if type(key) == "number" then
                available = IsSpellKnown(key)
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
