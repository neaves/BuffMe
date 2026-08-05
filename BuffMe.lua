local ADDON_NAME = "BuffMe"

function BuffMe_Debug(msg)
    if BuffMeCharDB and BuffMeCharDB.diagnosticMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888[BuffMe]|r " .. tostring(msg))
        local log = BuffMeCharDB.diagnosticLog
        if log then
            table.insert(log, date("%H:%M:%S") .. "  " .. tostring(msg))
            if #log > 500 then
                table.remove(log, 1)
            end
        end
    end
end

local inCombat        = false
local lastCastAttempt = nil  -- { spellId, unit, spellName } — for error-based learning
local rescanPending   = false

-- [guid] = true; units BuffMe cannot interact with at all this session ("Can't target
-- trivial" — on Ascension this fires for real, appropriately-leveled players who are
-- isolated by a challenge/instance mechanic like "Adventure Mode", not just low-level
-- targets). Session-only by design: in-memory, never written to SavedVariables, so it
-- clears itself on reload/logout and is also wiped on every party roster change.
local trivialTargets = {}

-- true if `unit` was rejected with "Can't target trivial" this session.
function BuffMe_IsTrivialTarget(unit)
    local guid = unit and UnitGUID(unit)
    return guid ~= nil and trivialTargets[guid] or false
end

-- Resolve a unit GUID to a unit token by checking every tracked unit (raid-wide when in a
-- raid, else player + party) plus target.
local function GUIDToUnit(guid)
    if not guid then return nil end
    for _, u in ipairs(BuffMe_GetTrackedUnits()) do
        if UnitGUID(u) == guid then return u end
    end
    if UnitExists("target") and UnitGUID("target") == guid then return "target" end
end
local pendingCast     = nil  -- { name, spellId } — for CLEU-less spells learned via UNIT_AURA
local playerBuffCache = {}   -- [buffName] = true; tracks current player buffs for diff
local pendingRemovals    = {}   -- [destGUID] = auraName; CLEU REMOVED waiting for paired APPLIED
local recentlyCastName   = nil  -- spell name from UNIT_SPELLCAST_SUCCEEDED; cleared each frame
local pendingSelfOnlyCheck = nil  -- { spellId, spellName } — REMOVED-on-player fired while
                                   -- targeting someone else; awaiting the paired APPLIED to
                                   -- tell true self-only toggle apart from a global-singleton
                                   -- relocation (e.g. "Bless") that legitimately lands on the target.
local pendingGroupCastGUIDs = {}  -- [spellName] = { [destGUID] = true, ... }; accumulates
                                   -- distinct destinations of a single self-cast within
                                   -- GROUP_CAST_WINDOW seconds, to detect "Greater"-style
                                   -- group-wide auras (see GROUP_CAST_WINDOW below).
local pendingGroupCastStart = {}  -- [spellName] = GetTime() when its gcSet was first created

-- Shared by SPELL_AURA_APPLIED and SPELL_AURA_REFRESH: a buff that's already active on the
-- caster only ever refreshes, never re-applies, so a spell kept permanently topped up (e.g.
-- a long-duration self-only ward) could go its whole life without a single APPLIED event —
-- and with it, without ever running this redirect check.
local function HandleSelfOnlyRedirect(destGUID, spellId, spellName, playerGUID)
    if destGUID == playerGUID
    and lastCastAttempt
    and lastCastAttempt.unit ~= "player"
    and lastCastAttempt.spellName == spellName then
        local selfKey = lastCastAttempt.spellId or spellId
        if selfKey and BuffMe_MarkSelfOnly(selfKey) then
            BuffMe_Debug("Self-only detected: \"" .. spellName ..
                "\" landed on caster despite targeting " .. lastCastAttempt.unit)
        end
    end
end

-- Same rationale as above, for group-cast detection: accumulate distinct destGUIDs per
-- spell name from both APPLIED and REFRESH so a mixed batch (some destinations freshly
-- applied, others already active and merely refreshed) still confirms group-cast.
-- Excludes the player's own pet: a self-buff that splashes onto a summoned pet (e.g.
-- Fetid Ward's "heals you and your minions" clause) lands on 2 distinct GUIDs from one
-- cast just like a real party-wide aura would, but it's still a self-only spell as far as
-- the optimizer's per-party-member coverage check is concerned — real party members never
-- receive it, so marking it groupCast=true made GetNextCast treat their permanent "gap" as
-- a reason to keep recasting it onto the player even while the player's own copy was active.
-- Does NOT require the triggering cast to have been self-targeted: the very first cast of
-- a not-yet-known "Greater X" spell gets aimed at whichever member has the gap (the optimizer
-- doesn't know yet that it's group-cast), so gating on unit=="player" here would mean it can
-- never be detected from that cast. A deliberately single-target spell cast repeatedly at
-- different people in quick succession (e.g. Razorice, needing 5 separate casts to cover a
-- full party) is still told apart correctly: pendingGroupCastGUIDs entries expire after
-- GROUP_CAST_WINDOW seconds (see below), and separate casts each need their own GCD/cast time.
--
-- GROUP_CAST_WINDOW: confirmed via a real 16-person raid (2026-08-03) that CLEU delivers a
-- single raid-wide splash cast's APPLIED events spread across ~1-2 real seconds, not one
-- frame — a real cast on Misulah/Esoteria/Cryin/... landed at 23:04:33 and the last of 10
-- recipients arrived at 23:04:34. The original per-frame wipe cleared the accumulator between
-- almost every one of those events, so groupCast never got confirmed for any spell in that
-- raid despite it visibly applying to everyone. A multi-second window is required at raid
-- scale; OnUpdate expires entries older than this instead of wiping unconditionally.
local GROUP_CAST_WINDOW = 3
local function AccumulateGroupCast(spellId, spellName, destGUID, playerGUID)
    if not (spellId and spellName and destGUID) then return end
    if UnitExists("pet") and destGUID == UnitGUID("pet") then return end
    if not (lastCastAttempt and lastCastAttempt.spellName == spellName) then
        return
    end
    local gcSet = pendingGroupCastGUIDs[spellName]
    if not gcSet then
        gcSet = {}
        pendingGroupCastGUIDs[spellName] = gcSet
        pendingGroupCastStart[spellName] = GetTime()
    end
    gcSet[destGUID] = true
    if gcSet[playerGUID] then
        local distinctCount = 0
        for _ in pairs(gcSet) do distinctCount = distinctCount + 1 end
        if distinctCount >= 2 then
            local gcEntry = BuffMeCharDB.spells[spellId]
            if gcEntry and not gcEntry.groupCast then
                BuffMe_MarkGroupCast(spellId)
                BuffMe_Debug("Group-cast confirmed: \"" .. spellName ..
                    "\" applied to " .. distinctCount ..
                    " units from one self-cast")
            end
        end
    end
end

-- Build a fresh snapshot of the player's current buffs without emitting diff messages.
-- Called on login/reload so the first real UNIT_AURA doesn't report every existing buff.
local function SnapshotPlayerBuffs()
    playerBuffCache = {}
    local i = 1
    while true do
        local name = UnitBuff("player", i)
        if not name then break end
        playerBuffCache[name] = true
        i = i + 1
    end
end

-- Diff current player buffs against the cache; log changes, update cache.
-- Returns gained (list), lost (list) — always populated regardless of diagnostic mode,
-- so callers can use them for typeGroup learning even when diagnostics are off.
local function DiffPlayerBuffs()
    local current = {}
    local gained  = {}
    local lost    = {}
    local i = 1
    while true do
        local name = UnitBuff("player", i)
        if not name then break end
        current[name] = true
        i = i + 1
    end
    for name in pairs(current) do
        if not playerBuffCache[name] then
            table.insert(gained, name)
            BuffMe_Debug("Buff gained: \"" .. name .. "\"")
        end
    end
    for name in pairs(playerBuffCache) do
        if not current[name] then
            table.insert(lost, name)
            BuffMe_Debug("Buff lost: \"" .. name .. "\"")
        end
    end
    playerBuffCache = current
    return gained, lost
end

-- ── Passive raid-wide "displaces" detection (Candidate Merges) ────────────────────────────
-- Independent of DiffPlayerBuffs above (which drives trusted, auto-merged learning for the
-- player's own confirmed casts). This tracks every raid/party member's buff *names* (cheap,
-- no tooltip reads) so a clean 1-for-1 swap can be spotted on ANY unit, then opportunistically
-- caches the tooltip sig of anything newly gained so that if it's later the "lost" side of a
-- future swap, we still have its sig to compare — a buff's tooltip can't be read anymore once
-- it's gone, so the sig has to be captured while it was still active.
local unitBuffCache    = {}  -- [unit] = { [buffName] = true }
local unitBuffSigCache = {}  -- [unit] = { [normalName] = sig }

-- Locate a named buff's current index on a unit, or nil if not present.
local function FindBuffIndex(unit, buffName)
    local i = 1
    while true do
        local name = UnitBuff(unit, i)
        if not name then return nil end
        if name == buffName then return i end
        i = i + 1
    end
end

-- Snapshot only units not already cached (new joiners), so an existing member's cache
-- (and its accumulated sig cache) survives an unrelated roster change.
local function SnapshotNewTrackedUnits()
    for _, u in ipairs(BuffMe_GetTrackedUnits()) do
        if UnitExists(u) and not unitBuffCache[u] then
            local cache = {}
            local i = 1
            while true do
                local name = UnitBuff(u, i)
                if not name then break end
                cache[name] = true
                i = i + 1
            end
            unitBuffCache[u] = cache
        end
    end
end

-- Diff one unit's buffs against its cache; returns gained/lost name lists. Also opportunistically
-- caches a tooltip sig for each newly-gained buff (cheap: bounded to the delta, not the whole list).
local function DiffUnitBuffs(unit)
    local cache = unitBuffCache[unit] or {}
    local current, gained, lost = {}, {}, {}
    local i = 1
    while true do
        local name = UnitBuff(unit, i)
        if not name then break end
        current[name] = true
        if not cache[name] then table.insert(gained, name) end
        i = i + 1
    end
    for name in pairs(cache) do
        if not current[name] then table.insert(lost, name) end
    end
    unitBuffCache[unit] = current

    for _, name in ipairs(gained) do
        local normalName = BuffMe_NormalizeName(name)
        unitBuffSigCache[unit] = unitBuffSigCache[unit] or {}
        if not unitBuffSigCache[unit][normalName] then
            local idx = FindBuffIndex(unit, name)
            if idx then
                local sig = BuffMe_GetUnitBuffInfo(unit, idx)
                if sig and sig ~= "" then
                    unitBuffSigCache[unit][normalName] = sig
                end
            end
        end
    end

    return gained, lost
end

-- Non-combat only (matches the existing passive effect-group scanner's throttling — the
-- point of this feature is catching end-of-raid buffing, not adding per-event cost mid-fight).
-- A clean 1-for-1 swap whose old and new tooltip sigs match is strong evidence the two buffs
-- displace each other; queued for user review rather than auto-merged (see BuffMe_RecordCandidatePair).
local function CheckDisplacedBuffPair(unit)
    if inCombat or not BuffMe_LearnModeEnabled() then return end
    local gained, lost = DiffUnitBuffs(unit)
    if #gained == 1 and #lost == 1 and gained[1] ~= lost[1] then
        local gName, lName = gained[1], lost[1]
        local gSig = unitBuffSigCache[unit] and unitBuffSigCache[unit][BuffMe_NormalizeName(gName)]
        local lSig = unitBuffSigCache[unit] and unitBuffSigCache[unit][BuffMe_NormalizeName(lName)]
        if gSig and lSig and BuffMe_SigsMatch(gSig, lSig) then
            BuffMe_RecordCandidatePair(lName, gName, unit)
        end
    end
end

-- Scan the spellbook to find a spell ID by name; fallback when UNIT_SPELLCAST_SUCCEEDED
-- doesn't carry the ID (varies by server/emulator).
local function FindSpellIdInBook(spellName)
    for tab = 1, GetNumSpellTabs() do
        local _, _, offset, numSpells = GetSpellTabInfo(tab)
        for i = offset + 1, offset + numSpells do
            local spellType, spellId = GetSpellBookItemInfo(i, BOOKTYPE_SPELL)
            if spellType == "SPELL" and spellId then
                local name = GetSpellInfo(spellId)
                if name == spellName then return spellId end
            end
        end
    end
end

local frame = CreateFrame("Frame", "BuffMeFrame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
frame:RegisterEvent("RAID_ROSTER_UPDATE")
frame:RegisterEvent("UNIT_AURA")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("UI_ERROR_MESSAGE")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("UNIT_SPELLCAST_SENT")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("PLAYER_TALENT_UPDATE")

local function RefreshUI()
    if BuffMe_UpdateContainerLayout then BuffMe_UpdateContainerLayout() end
    if BuffMe_UpdateBadge           then BuffMe_UpdateBadge()           end
    if BuffMe_UpdatePreviewIcons    then BuffMe_UpdatePreviewIcons()    end
    if BuffMe_RefreshPanel          then BuffMe_RefreshPanel()          end
end

-- Throttle: rescans accumulate and fire at most once per REFRESH_THROTTLE seconds via
-- OnUpdate, instead of once per frame. RefreshUI does a full party aura scan plus the
-- optimizer pass (BuffMe_GetNextCast) — cheap for one call, but UNIT_AURA/roster/target
-- events can arrive in bursts (nameplates, procs, other party members' auras ticking) in
-- a dungeon, and re-running the full pass every single frame during such a burst is the
-- source of visible stutter. A few seconds of staleness on the badge/preview icons is a
-- non-issue since the button itself always resolves the live state on click.
-- The pendingRemovals wipe and recentlyCastName reset stay unconditional and per-frame —
-- they support CLEU learning, which keeps running in combat, and are trivial single-check
-- costs regardless of frequency.
local REFRESH_THROTTLE = 2
local lastRefreshTime = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    if next(pendingRemovals) then wipe(pendingRemovals) end  -- clear unmatched CLEU removals
    -- Expire group-cast accumulation batches older than GROUP_CAST_WINDOW (not unconditionally
    -- every frame — a raid-wide splash cast's APPLIED events can spread across several seconds).
    if next(pendingGroupCastGUIDs) then
        local now = GetTime()
        for spellName, startTime in pairs(pendingGroupCastStart) do
            if now - startTime > GROUP_CAST_WINDOW then
                pendingGroupCastGUIDs[spellName] = nil
                pendingGroupCastStart[spellName]  = nil
            end
        end
    end
    recentlyCastName = nil  -- proc guard: reset each frame after CLEU has had a chance to fire
    if not inCombat then
        local now = GetTime()
        if now - lastRefreshTime >= REFRESH_THROTTLE then
            lastRefreshTime = now
            -- Drain a batch of the effect-group discovery queue (tooltip reads — the
            -- expensive step) every tick. A match means new coverage data landed, so
            -- force a refresh even if nothing else requested one this tick.
            if BuffMe_ProcessScanQueue and BuffMe_ProcessScanQueue() then
                rescanPending = true
            end
            if rescanPending then
                rescanPending = false
                RefreshUI()
            end
        end
    end
end)

local function ScheduleRescan()
    rescanPending = true
end

function BuffMe_ForceRefresh()
    lastRefreshTime = GetTime()
    RefreshUI()
end

-- Detect "more powerful spell" error strings (localization may vary on private servers)
local ERROR_PATTERNS = {
    "more powerful",
    "already active",
    "cannot be cast",
}

-- Detect hostile-target-required errors.  These spells incidentally apply a buff to
-- the caster but cannot be used on party members — mark them ineligible permanently.
local HARM_TARGET_PATTERNS = {
    "hostile",
    "must be an enemy",
    "can only be used on enemies",
    "only use that on enemies",
    "requires a harmful",
    "requires an enemy",
}

-- Detect "can't target trivial" rejections. Despite the wording this isn't only a level
-- check on Ascension — it also fires for real, correctly-leveled players isolated by a
-- challenge/instance mechanic (e.g. "Adventure Mode"). Either way it's a per-target, not
-- per-spell, restriction: any buff would bounce the same way. Session-only exclusion.
local TRIVIAL_TARGET_PATTERNS = {
    "target trivial",
}

-- Detect "invalid target" rejections. Clear the in-flight cast attempt to stop the
-- retry cascade; do not permanently modify the spell DB (the error is too ambiguous).
local INVALID_TARGET_PATTERNS = {
    "invalid target",
    "you have selected an invalid target",
}

-- CLEU event types included in the diagnostic verbose dump.
-- SPELL_CAST_START and SPELL_CAST_FAILED are intentionally omitted: they fire for
-- every cast including combat spells and generate the bulk of diagnostic noise.
-- SPELL_CAST_SUCCESS is kept because it identifies CLEU-less spells (no AURA_APPLIED).
local CAST_AURA_EVENTS = {
    SPELL_CAST_SUCCESS      = true,
    SPELL_AURA_APPLIED      = true, SPELL_AURA_REMOVED      = true,
    SPELL_AURA_REFRESH      = true,
    SPELL_AURA_APPLIED_DOSE = true, SPELL_AURA_REMOVED_DOSE = true,
    SPELL_DISPEL            = true, SPELL_SUMMON            = true,
}

-- Every CLEU eventType this addon ever acts on (CAST_AURA_EVENTS above, used only for
-- the diagnostic dump, plus SPELL_CAST_FAILED, used for bounced-cast/ineligibility
-- learning). CLEU fires for every combat log line visible to the client -- SWING_DAMAGE,
-- SPELL_DAMAGE, SPELL_MISS, SPELL_PERIODIC_*, etc. -- from every combatant in the fight,
-- ally and enemy alike. That volume scales directly with how many units are actively
-- fighting (e.g. a necromancer's and knight's summoned minions all attacking at once),
-- so bailing out on this cheap table lookup before unpacking the event or calling
-- UnitGUID() matters: without it, every one of those irrelevant events still paid for a
-- 12-value vararg destructure and a UnitGUID("player") call before being discarded.
local RELEVANT_CLEU_EVENTS = { SPELL_CAST_FAILED = true }
for eventType in pairs(CAST_AURA_EVENTS) do
    RELEVANT_CLEU_EVENTS[eventType] = true
end

local function IsBouncedError(msg)
    if type(msg) ~= "string" then return false end
    local lower = msg:lower()
    for _, pat in ipairs(ERROR_PATTERNS) do
        if lower:find(pat, 1, true) then return true end
    end
    return false
end

local function IsHarmTargetError(msg)
    if type(msg) ~= "string" then return false end
    local lower = msg:lower()
    for _, pat in ipairs(HARM_TARGET_PATTERNS) do
        if lower:find(pat, 1, true) then return true end
    end
    return false
end

local function IsTrivialTargetError(msg)
    if type(msg) ~= "string" then return false end
    local lower = msg:lower()
    for _, pat in ipairs(TRIVIAL_TARGET_PATTERNS) do
        if lower:find(pat, 1, true) then return true end
    end
    return false
end

local function IsInvalidTargetError(msg)
    if type(msg) ~= "string" then return false end
    local lower = msg:lower()
    for _, pat in ipairs(INVALID_TARGET_PATTERNS) do
        if lower:find(pat, 1, true) then return true end
    end
    return false
end

-- Shared handler for "more powerful spell" rejections, called from both UI_ERROR_MESSAGE
-- and CLEU SPELL_CAST_FAILED (Ascension may fire one but not the other).
-- Reads and clears lastCastAttempt; safe to call when lastCastAttempt is nil.
local function HandleBouncedCast(source)
    if not lastCastAttempt then return end
    local targetUnit   = lastCastAttempt.unit
    local ourSpellName = lastCastAttempt.spellName
    local ourKey       = lastCastAttempt.spellId
    BuffMe_Debug("Cast rejected (" .. source .. "): \"" .. (ourSpellName or "?") .. "\"")
    if targetUnit and ourSpellName and UnitExists(targetUnit) then
        local blockingBuff = BuffMe_FindBlockingBuff(targetUnit, ourSpellName)
        if blockingBuff then
            BuffMe_Debug("Blocking aura found: \"" .. blockingBuff .. "\"")
            local blockerNorm = BuffMe_NormalizeName(blockingBuff)
            local ourNorm     = BuffMe_NormalizeName(ourSpellName)
            local blockerTG   = BuffMeCharDB.auraToTypeGroup[blockerNorm]
            local ourTG       = BuffMeCharDB.auraToTypeGroup[ourNorm]
            if not blockerTG and ourTG then
                -- Blocker is not in our DB (external/unknown buff) — register it directly.
                -- New-relationship discovery, gated by Learn Mode.
                if BuffMe_LearnModeEnabled() then
                    BuffMe_RegisterAuraInTypeGroup(blockingBuff, ourTG)
                    BuffMe_Debug("Registered external blocker \"" .. blockingBuff .. "\" in typeGroup \"" .. ourTG .. "\"")
                else
                    BuffMe_Debug("Learn mode off: skipping registration of external blocker \"" .. blockingBuff .. "\"")
                end
            else
                -- Both sides known — merge (or same TG already, merge is a no-op)
                BuffMe_MergeTypeGroups(ourSpellName, blockingBuff)
                for sid, entry in pairs(BuffMeCharDB.spells) do
                    if entry.auraName == blockingBuff then
                        BuffMe_Debug("Linking targetGroup: " .. tostring(ourKey) .. " + " .. tostring(sid))
                        BuffMe_LinkTargetGroup(ourKey, sid)
                        break
                    end
                end
            end
            -- Populate effect groups for both our spell and the blocker so the Effect Groups
            -- panel can display them and the optimizer can match them in future passes.
            local ourEntry = ourKey and BuffMeCharDB.spells[ourKey]
            local ourSig, ourValue = ourEntry and BuffMe_GetOurSpellInfo(ourEntry)
            if ourSig and ourSig ~= "" and (ourTG or BuffMeCharDB.auraToTypeGroup[ourNorm]) then
                local resolvedTG = ourTG or BuffMeCharDB.auraToTypeGroup[ourNorm]
                BuffMe_RegisterInEffectGroup(ourSig, resolvedTG, ourNorm, ourSpellName, ourValue)
                -- Scan the blocker's tooltip; if it matches our sig, register it too
                if UnitExists(targetUnit) then
                    local bi = 1
                    while true do
                        local bn = UnitBuff(targetUnit, bi)
                        if not bn then break end
                        if bn == blockingBuff then
                            local bSig, bValue = BuffMe_GetUnitBuffInfo(targetUnit, bi)
                            if bSig == ourSig then
                                BuffMe_RegisterInEffectGroup(ourSig, resolvedTG, blockerNorm, blockingBuff, bValue)
                                BuffMe_Debug("Effect group entry: \"" .. blockingBuff .. "\" value=" .. (bValue or 0))
                            end
                            break
                        end
                        bi = bi + 1
                    end
                end
            end
        else
            -- Dump every buff on the target so the user can identify the blocker manually.
            BuffMe_Debug("No blocking aura auto-identified on " .. targetUnit ..
                " for \"" .. ourSpellName .. "\" — dumping target buffs:")
            local bi = 1
            while true do
                local bn, _, _, _, _, _, _, caster = UnitBuff(targetUnit, bi)
                if not bn then break end
                BuffMe_Debug("  [" .. bi .. "] \"" .. bn .. "\" (caster: " .. (caster or "?") .. ")")
                bi = bi + 1
            end
        end
    end
    lastCastAttempt = nil
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            BuffMe_InitDB()
            if BuffMe_UpdateLockIcon then BuffMe_UpdateLockIcon() end
            if BuffMe_ApplyScale     then BuffMe_ApplyScale(BuffMeDB.uiScale or 1.0) end
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff00ccff[Buff Me]|r loaded. " ..
                "The spell database grows as you buff your party."
            )
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        SnapshotPlayerBuffs()
        SnapshotNewTrackedUnits()
        BuffMe_ScanPartyForEffectGroups(nil)
        ScheduleRescan()

    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        BuffMe_Debug("Roster changed (" .. #BuffMe_GetTrackedUnits() .. " tracked unit(s))")
        -- Roster changed — drop the session-only trivial-target set rather than risk
        -- staleness (a departed member's GUID is harmless to keep, but simplest to reset).
        trivialTargets = {}
        SnapshotNewTrackedUnits()
        -- Full roster tooltip scan — defer to the PLAYER_REGEN_ENABLED catch-up in combat.
        if not inCombat then
            BuffMe_ScanPartyForEffectGroups(nil)
        end
        ScheduleRescan()

    elseif event == "UNIT_AURA" then
        local unit = ...
        -- UNIT_AURA is registered without RegisterUnitEvent, so it fires for every unit
        -- token the client is tracking auras for — nameplates, nearby mobs, other players'
        -- pets, etc. — not just our group. In a dungeon/raid that's a constant stream of
        -- irrelevant events. Only player/party/raid/target auras can ever affect buff
        -- coverage, so bail immediately for anything else before doing any diffing,
        -- tooltip scanning, or triggering a rescan.
        if unit ~= "player" and unit ~= "target"
        and not unit:match("^party%d$") and not unit:match("^raid%d%d?$") then
            return
        end

        -- Raid-wide passive "displaces" detection — independent of everything below,
        -- runs for every tracked unit including player. "target" excluded: it isn't a
        -- stable roster member, so there's no meaningful buff-name cache to diff against.
        if unit ~= "target" then
            CheckDisplacedBuffPair(unit)
        end

        -- Only allocated for "player": DiffPlayerBuffs() is the sole producer, and every
        -- read of gained/lost below is itself guarded by `unit == "player"`. Avoiding the
        -- {} {} allocation for "target"/partyN events matters because those fire constantly
        -- during combat (e.g. a targeted unit's debuffs ticking) and would otherwise churn
        -- the GC on every one for tables that are never used.
        local gained, lost
        if unit == "player" then
            gained, lost = DiffPlayerBuffs()
        end

        -- CLEU-less spell cast on a non-player "target": pendingCast was set by
        -- UNIT_SPELLCAST_SUCCEEDED but the "player" guard below won't consume it,
        -- leaving it alive to be incorrectly consumed by a later player UNIT_AURA.
        -- Clear it here. Preference recording requires a buff diff which we don't
        -- maintain for non-player units; accept the omission for now.
        if pendingCast and unit == "target"
        and lastCastAttempt and lastCastAttempt.unit == "target"
        and lastCastAttempt.spellName == pendingCast.name then
            BuffMe_Debug("Cleared pendingCast: CLEU-less \"" .. pendingCast.name ..
                "\" cast on target (non-player — preference skipped)")
            pendingCast = nil
        end

        -- Resolve pending registration for CLEU-less spells (e.g. Grove Instinct).
        -- The spell name and aura name may differ (spell 10000 can apply aura 20000),
        -- so we use the diff list rather than name-matching.
        if pendingCast and unit == "player" then
            -- On Ascension, UNIT_AURA fires before CLEU. When a spell replaces another
            -- (e.g. Boon of the Bear replaces Boon of the Lion), UNIT_AURA fires TWICE:
            -- once for the removal (gained=[]) and once for the gain. Only consume
            -- pendingCast when we see actual new buffs; otherwise keep it alive so the
            -- second UNIT_AURA (or the CLEU APPLIED fallback) can complete registration.
            if #gained > 0 then
                local pending = pendingCast
                pendingCast = nil

                -- Pick the aura: prefer exact spell-name match, then sole new buff.
                local auraName = nil
                for _, buffName in ipairs(gained) do
                    if buffName == pending.name then auraName = buffName; break end
                end
                if not auraName and #gained == 1 then
                    auraName = gained[1]
                end

                if auraName then
                    local sid = pending.spellId or FindSpellIdInBook(pending.name)
                    if not sid then
                        -- Custom Ascension spell IDs (500000+) may not appear in the
                        -- client's GetSpellBookItemInfo scan — the server and client use
                        -- different ID spaces. Fall back to a synthetic string key, but
                        -- only when UNIT_SPELLCAST_SENT confirmed this was an active player
                        -- cast (that event doesn't fire for item/world-object interactions).
                        if lastCastAttempt and lastCastAttempt.spellName == pending.name then
                            sid = "__" .. pending.name
                        else
                            BuffMe_Debug("Skipped UNIT_AURA registration: \"" .. pending.name ..
                                "\" — no matching active cast (item or passive effect)")
                        end
                    end
                    if sid then
                        BuffMe_RegisterSpell(sid, pending.name, auraName)
                        -- Capture aura tooltip for effect-group matching (always self-applied).
                        local entry = BuffMeCharDB.spells[sid]
                        if entry then BuffMe_CaptureAuraTooltip("player", entry) end
                        -- Record last-cast preference (UNIT_AURA fallback is always player→player).
                        local normalAura = BuffMe_NormalizeName(auraName)
                        local tg = BuffMeCharDB.auraToTypeGroup[normalAura]
                        if tg then BuffMe_RecordLastCast(tg, UnitName("player"), sid) end
                        local idStr = type(sid) == "number" and ("ID " .. sid) or ("key \"" .. sid .. "\"")
                        if auraName ~= pending.name then
                            BuffMe_Debug("Registered via UNIT_AURA fallback: spell \"" .. pending.name ..
                                "\" → aura \"" .. auraName .. "\" (" .. idStr .. ")")
                        else
                            BuffMe_Debug("Registered via UNIT_AURA fallback: \"" .. pending.name ..
                                "\" (" .. idStr .. ")")
                        end
                        lastCastAttempt = nil
                    end
                elseif #gained > 1 then
                    BuffMe_Debug("Ambiguous registration after \"" .. pending.name .. "\": " ..
                        #gained .. " new buffs — try casting when no other buffs are applied")
                end
            end
        end

        -- TypeGroup learning for CLEU-less buff swaps (e.g. Grove Instinct replaced by Primal
        -- Instinct — no CLEU REMOVED fires, but diff captures both sides of the swap).
        -- Only act on unambiguous 1-for-1 swaps to avoid false merges.
        -- Also require keyword overlap: exclusive stances (e.g. Cultist "Presence of X"
        -- vs "Whispers of X") replace each other but are different effect types — no
        -- shared keywords means don't merge their typeGroups.
        if unit == "player" and #gained == 1 and #lost == 1 then
            local g, l = gained[1], lost[1]
            if g ~= l and BuffMe_KeywordOverlap(l, g) then
                BuffMe_Debug("Buff swap (diff): \"" .. l .. "\" → \"" .. g .. "\" — merging typeGroups")
                BuffMe_MergeTypeGroups(l, g)
            end
        end

        -- Passive effect-group discovery reads a tooltip for every unregistered buff on
        -- `unit` — far too costly to run per UNIT_AURA in combat (procs/HoTs/DoTs churn
        -- constantly). Skip it in combat; PLAYER_REGEN_ENABLED runs a full catch-up scan
        -- on exit so nothing discovered during the fight is permanently missed. The learning
        -- above (DiffPlayerBuffs, CLEU-less registration, 1-for-1 swap merges) still runs.
        if not inCombat then
            BuffMe_ScanPartyForEffectGroups(unit)
        end
        ScheduleRescan()

    elseif event == "SPELLS_CHANGED" then
        -- IsSpellKnown reflects the updated state immediately after this event fires,
        -- so a plain rescan is all that's needed — no spellbook scan required.
        ScheduleRescan()

    elseif event == "PLAYER_TALENT_UPDATE" then
        ScheduleRescan()

    elseif event == "PLAYER_TARGET_CHANGED" then
        if UnitExists("target") then
            local targetName = UnitName("target") or "?"
            local isPlayer   = UnitIsPlayer("target")
            local isFriend   = UnitIsFriend("player", "target")
            BuffMe_Debug("Target → " .. targetName ..
                (isPlayer and " [player]" or " [NPC]") ..
                (isFriend and " [friendly]" or " [hostile]"))
            if isPlayer and isFriend and not inCombat then
                BuffMe_ScanPartyForEffectGroups("target")
            end
        else
            BuffMe_Debug("Target cleared")
        end
        ScheduleRescan()

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        BuffMe_Debug("Entered combat — button disabled")
        if BuffMe_SetCombatState then BuffMe_SetCombatState(true) end
        -- The Buff Me button is combat-locked (BuffMe_PrepareCast refuses in combat), and
        -- CLEU learning only ever fires from the player's own buff casts — so there's
        -- nothing left for this event to do in combat. Unregistering it entirely avoids
        -- paying any per-event cost (even the cheap eventType-lookup bail) for the whole
        -- volume of combat log traffic, which spikes hard when several minions/pets are
        -- all fighting at once. Tradeoff: a buff manually cast mid-combat (not via the
        -- button) won't be learned/updated until it's cast again outside combat.
        self:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        BuffMe_Debug("Left combat — button re-enabled")
        if BuffMe_SetCombatState then BuffMe_SetCombatState(false) end
        self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        -- Catch-up: effect-group discovery was skipped for every UNIT_AURA / roster change
        -- during combat. One full-party scan here recovers anything learnable that appeared
        -- on the party mid-fight, then the deferred UI rescan flushes on the next frame.
        BuffMe_ScanPartyForEffectGroups(nil)
        ScheduleRescan()

    elseif event == "UI_ERROR_MESSAGE" then
        local a1, a2 = ...
        -- WotLK fires (message); some builds fire (errorType, message). Handle both.
        local msg = (type(a2) == "string" and a2 ~= "" and a2)
                 or (type(a1) == "string" and a1 ~= "" and a1)
                 or nil
        -- Log UI errors only when a buff cast is in flight (lastCastAttempt set).
        -- Generic combat errors ("Spell is not ready yet", "Interrupted", etc.) that arrive
        -- when no buff is being cast are noise; the actionable cases always have a lastCastAttempt.
        if lastCastAttempt then
            BuffMe_Debug("UI_ERROR [" .. tostring(a1) ..
                (a2 ~= nil and (", " .. tostring(a2)) or "") .. "]: " .. (msg or "(no string)") ..
                " [after \"" .. (lastCastAttempt.spellName or "?") .. "\"]")
        end
        if lastCastAttempt and IsHarmTargetError(msg) then
            -- Spell requires a hostile target; flag it ineligible permanently.
            if BuffMe_MarkIneligible(lastCastAttempt.spellId, "requires hostile target") then
                ScheduleRescan()
            end
            lastCastAttempt = nil
        elseif lastCastAttempt and IsTrivialTargetError(msg) then
            -- Per-target, not per-spell — any buff would bounce the same way. Exclude the
            -- unit (by GUID) from candidacy for the rest of this session; never persisted.
            local guid = UnitGUID(lastCastAttempt.unit)
            if guid then
                trivialTargets[guid] = true
                BuffMe_Debug("Marked trivial/unreachable target this session: \"" ..
                    (UnitName(lastCastAttempt.unit) or "?") .. "\"")
                ScheduleRescan()
            end
            lastCastAttempt = nil
        elseif lastCastAttempt and IsInvalidTargetError(msg) then
            -- "Invalid target" can mean many conditions (zone restriction, target state,
            -- faction, etc.) — safe to clear the attempt to stop the retry cascade, but
            -- don't permanently modify the spell DB based on this ambiguous error.
            lastCastAttempt = nil
        elseif lastCastAttempt and IsBouncedError(msg) then
            HandleBouncedCast("UI_ERROR")
        end

    elseif event == "UNIT_SPELLCAST_SENT" then
        -- Fires for ALL player casts (instant and cast-time) before the server result.
        -- Populates lastCastAttempt for manual buff casts so bounced-error learning works
        -- even when the cast was not initiated by the Buff Me button.
        -- Only tracks casts aimed at party members — ignores enemy-targeted spells.
        local unit, spellName, rank, target = ...
        if unit == "player" and spellName then
            if not lastCastAttempt or lastCastAttempt.spellName ~= spellName then
                local targetUnit = nil
                if target then
                    for _, u in ipairs({"player","party1","party2","party3","party4"}) do
                        if UnitExists(u) and UnitName(u) == target then
                            targetUnit = u; break
                        end
                    end
                end
                -- Self-casts arrive as the player's own name or an empty string.
                if not targetUnit and (not target or target == "" or target == UnitName("player")) then
                    targetUnit = "player"
                end
                -- Open-world friendly targets (not in party) — use the "target" unit token
                -- so UnitBuff scans still work. Skip hostile targets to avoid tracking damage casts.
                if not targetUnit and UnitExists("target") and UnitIsFriend("player", "target") then
                    targetUnit = "target"
                end
                if targetUnit then
                    local dbKey = BuffMeCharDB and BuffMeCharDB.nameToKey and BuffMeCharDB.nameToKey[spellName]
                    lastCastAttempt = { spellId = dbKey, unit = targetUnit, spellName = spellName }
                    BuffMe_Debug("Cast sent: \"" .. spellName .. "\" → " .. targetUnit ..
                        (target and target ~= "" and (" (\"" .. target .. "\")") or ""))
                end
            end
        end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, spellName, rank, lineID, spellId = ...
        if unit == "player" and spellName then
            BuffMe_Debug("Cast succeeded: \"" .. spellName .. "\"" ..
                (spellId and (" (ID " .. spellId .. ")") or " (no ID in event)"))
            -- Gate for CLEU proc detection: UNIT_SPELLCAST_SUCCEEDED fires only for active
            -- player casts, not passive procs. CLEU SPELL_AURA_APPLIED fires for both.
            -- By recording the name here, CLEU can distinguish "player cast this" from
            -- "proc applied this with playerGUID as source".
            recentlyCastName = spellName

            -- Queue a pending cast so the UNIT_AURA handler can confirm the buff landed
            -- and record last-cast preferences. Skip queueing only for spells already
            -- known under a numeric key (i.e. CLEU-backed) — CLEU records their preferences
            -- independently. Synthetic-key spells (CLEU-less, like Grove Instinct) must
            -- always queue so subsequent casts can still update preferences via UNIT_AURA.
            local numericKey = (spellId and BuffMeCharDB and BuffMeCharDB.spells[spellId] and spellId)
                or (BuffMeCharDB and BuffMeCharDB.nameToKey
                    and type(BuffMeCharDB.nameToKey[spellName]) == "number"
                    and BuffMeCharDB.nameToKey[spellName])
            if not numericKey then
                pendingCast = { name = spellName, spellId = spellId }
            end
        end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        -- Cheap bail before unpacking anything else: the overwhelming majority of CLEU
        -- volume in combat (damage, misses, periodic ticks) is never acted on below.
        if not RELEVANT_CLEU_EVENTS[(select(2, ...))] then return end

        local timestamp, eventType, sourceGUID, sourceName, sourceFlags,
              destGUID, destName, destFlags,
              spellId, spellName, spellSchool, auraType = ...

        local playerGUID = UnitGUID("player")

        -- Verbose dump: show all cast/aura events involving the player so we can
        -- identify spells that don't arrive as SPELL_AURA_APPLIED BUFF from playerGUID
        if BuffMeCharDB and BuffMeCharDB.diagnosticMode
        and (sourceGUID == playerGUID or destGUID == playerGUID)
        and CAST_AURA_EVENTS[eventType] then
            BuffMe_Debug("CLEU " .. eventType ..
                " | src=" .. (sourceName or "?") ..
                " → dst=" .. (destName or "?") ..
                " | spell=\"" .. (spellName or "?") .. "\"" ..
                (spellId  and (" ID="   .. spellId)  or "") ..
                (auraType and (" ["     .. auraType .. "]") or ""))
        end

        if eventType == "SPELL_AURA_REFRESH" and auraType == "BUFF" then
            if sourceGUID == playerGUID and spellId and spellName then
                BuffMe_Debug("Aura refreshed: \"" .. spellName .. "\" (ID " .. spellId ..
                    ") on " .. (destName or "?"))
                HandleSelfOnlyRedirect(destGUID, spellId, spellName, playerGUID)
                AccumulateGroupCast(spellId, spellName, destGUID, playerGUID)
                lastCastAttempt = nil
                pendingCast = nil  -- refresh is a valid cast outcome; suppress "no new buff" warning
                -- Bypass the throttle: this is confirmation of the player's own deliberate
                -- cast, so the next suggestion must be correct immediately, not up to
                -- REFRESH_THROTTLE seconds later. But only when the destination is a unit we
                -- actually track coverage for (player/party/target) — see the matching gate in
                -- the APPLIED branch below. Otherwise this is e.g. a still-alive summoned pet's
                -- buff refreshing (recasting "Animate: Skeletal Archer" while some archers from
                -- the last cast are still up), and a full optimizer/UI pass for that is wasted
                -- work that piles up fast when several such pets refresh in the same instant.
                if GUIDToUnit(destGUID) then
                    BuffMe_ForceRefresh()
                end
            elseif spellName and sourceGUID then
                -- Not our cast: learn who grants this buff (class only) for the Effect
                -- Groups "Source: <Class>" tooltip. Handled on REFRESH too, not just
                -- APPLIED — a buff already active before we joined the group/logged in
                -- would otherwise never fire APPLIED for us to observe (see
                -- feedback-refresh-bypasses-learning).
                local sourceUnit = GUIDToUnit(sourceGUID)
                if sourceUnit then
                    BuffMe_LearnAuraSource(spellName, sourceUnit)
                end
            end

        elseif eventType == "SPELL_AURA_APPLIED" and auraType == "BUFF" then
            if sourceGUID == playerGUID then
                if spellId and spellName then
                    local isNew = not BuffMeCharDB.spells[spellId]
                    if isNew and not (lastCastAttempt and lastCastAttempt.spellName == spellName) then
                        -- UNIT_SPELLCAST_SENT is the authoritative signal that the player issued a
                        -- deliberate cast from an action bar or button; it sets lastCastAttempt.
                        -- World/quest item interactions fire UNIT_SPELLCAST_SUCCEEDED (which set
                        -- recentlyCastName) but NOT UNIT_SPELLCAST_SENT, so lastCastAttempt is
                        -- never populated for them. Passive procs set neither. Requiring
                        -- lastCastAttempt to match is the tightest safe gate for new-spell
                        -- registration — it survives the OnUpdate timing gap (recentlyCastName
                        -- cleared before CLEU fires) and still rejects world-object auras.
                        BuffMe_Debug("Skipped registration (proc/item): \"" .. spellName ..
                            "\" (ID " .. spellId .. ") — no matching UNIT_SPELLCAST_SENT")
                    else
                        -- Only register/track spells that land on friendly targets.
                        -- Quest-item abilities (e.g. "Thrown Torch") fire UNIT_SPELLCAST_SENT
                        -- but apply to enemy targets; COMBATLOG_OBJECT_REACTION_FRIENDLY (0x10)
                        -- in destFlags identifies friendly targets reliably.
                        local isFriendlyDest = (destGUID == playerGUID)
                            or (bit.band(destFlags or 0, 0x00000010) ~= 0)
                        if not isFriendlyDest then
                            BuffMe_Debug("Skipped registration (enemy target): \"" .. spellName ..
                                "\" (ID " .. spellId .. ") → " .. (destName or "?"))
                            -- Retroactively mark existing entries ineligible when we observe
                            -- them being used on an enemy — handles spells registered in a
                            -- prior session before this guard existed.
                            if not isNew then
                                local existingEntry = BuffMeCharDB.spells[spellId]
                                if existingEntry and not existingEntry.ineligible then
                                    existingEntry.ineligible = true
                                    BuffMe_Debug("Marked ineligible (enemy-only): \"" .. spellName .. "\"")
                                end
                            end
                        else
                        -- Further require destGUID to resolve to a unit BuffMe actually tracks
                        -- coverage for (player/party/target). The friendly-reaction-flag check
                        -- above also passes for the caster's own summoned pets/minions — e.g.
                        -- "Animate: Skeletal Archer" applies a friendly buff to each of 5 new
                        -- archers in the same instant. Treating those as real buff-casts ran the
                        -- full registration pipeline (including BuffMe_ForceRefresh's full
                        -- optimizer/UI pass) once per minion, all at once — a visible frame-time
                        -- spike right when a summon spell enters combat. This isn't an enemy-only
                        -- spell (so don't mark ineligible below), just not a destination we track.
                        local destUnit = GUIDToUnit(destGUID)
                        if not destUnit then
                            BuffMe_Debug("Skipped registration (non-tracked destination): \"" .. spellName ..
                                "\" (ID " .. spellId .. ") → " .. (destName or "?"))
                        else
                        BuffMe_RegisterSpell(spellId, spellName, spellName)
                        -- Group-cast detection ("Greater" auras): a single self-targeted cast
                        -- that applies to the whole party/raid fires one SPELL_AURA_APPLIED per
                        -- destination, all within the same batch. Accumulate distinct destGUIDs
                        -- per spell name (wiped every frame in OnUpdate); once we've seen the
                        -- player plus at least one other unit for the same cast, it's confirmed
                        -- group-wide — mark it so the optimizer always casts it on "player"
                        -- regardless of which member's coverage gap triggered it.
                        AccumulateGroupCast(spellId, spellName, destGUID, playerGUID)
                        -- Capture the aura's tooltip sig for effect-group matching.
                        -- We use the live unit-buff tooltip (SetUnitBuff) as the sole
                        -- source so sigs are format-identical on both sides of comparisons.
                        do
                            local entry = BuffMeCharDB.spells[spellId]
                            if entry then BuffMe_CaptureAuraTooltip(destUnit, entry) end
                        end
                        -- Record last-cast preference for this typeGroup/target pair.
                        -- This is the authoritative confirmation the buff actually landed.
                        if destName then
                            local normalAura = BuffMe_NormalizeName(spellName)
                            local tg = BuffMeCharDB.auraToTypeGroup[normalAura]
                            if tg then BuffMe_RecordLastCast(tg, destName, spellId) end
                        end
                        -- TypeGroup learning: if a buff was removed on this target just before
                        -- this APPLIED (CLEU REMOVED fires before APPLIED within the same
                        -- server tick), they are mutually exclusive → merge typeGroups.
                        -- Require keyword overlap before merging: exclusive stances that replace
                        -- each other but provide different effects (e.g. Cultist "Presence of X"
                        -- vs "Whispers of X") share no keywords and must not be merged.
                        -- Tooltip-based merges in HandleBouncedCast remain ungated.
                        if pendingRemovals[destGUID] then
                            local removedName = pendingRemovals[destGUID]
                            pendingRemovals[destGUID] = nil
                            if removedName ~= spellName and BuffMe_KeywordOverlap(removedName, spellName) then
                                BuffMe_Debug("Buff replacement (CLEU): \"" .. removedName ..
                                    "\" → \"" .. spellName .. "\" — merging typeGroups")
                                BuffMe_MergeTypeGroups(removedName, spellName)
                            end
                        end
                        -- Global-singleton learning: if this exact spell name was just removed
                        -- from a DIFFERENT destGUID than the one it's landing on now, the server
                        -- only allows one live instance of it anywhere (e.g. "Bless" — recasting
                        -- on a new target strips it from whoever had it before). Mark its
                        -- typeGroup so the optimizer treats coverage as party-wide, not per-unit.
                        for otherGUID, removedName in pairs(pendingRemovals) do
                            if otherGUID ~= destGUID and removedName == spellName then
                                pendingRemovals[otherGUID] = nil
                                local normalAura = BuffMe_NormalizeName(spellName)
                                local tg = BuffMeCharDB.auraToTypeGroup[normalAura] or normalAura
                                if not BuffMeCharDB.globalTypeGroups[tg] then
                                    BuffMeCharDB.globalTypeGroups[tg] = true
                                    BuffMe_Debug("Global-singleton detected: \"" .. spellName ..
                                        "\" moved to " .. (destName or "?") ..
                                        " — typeGroup \"" .. tg .. "\" is now party-wide")
                                end
                                break
                            end
                        end
                        -- Resolve any pending self-only check (see SPELL_AURA_REMOVED) now that
                        -- we know where this paired APPLIED actually landed: back on the caster
                        -- confirms a true self-only toggle; landing on the intended target
                        -- confirms a global-singleton relocation instead — not self-only.
                        if pendingSelfOnlyCheck and pendingSelfOnlyCheck.spellName == spellName then
                            local check = pendingSelfOnlyCheck
                            pendingSelfOnlyCheck = nil
                            if destGUID == playerGUID then
                                if BuffMe_MarkSelfOnly(check.spellId) then
                                    BuffMe_Debug("Self-only detected (toggle/redirect): \"" .. spellName ..
                                        "\" — player buff dropped and re-landed on caster")
                                end
                            else
                                BuffMe_Debug("Not self-only (relocation confirmed): \"" .. spellName ..
                                    "\" landed on intended target " .. (destName or "?"))
                                -- Self-heal: a prior version of this heuristic could have
                                -- already mis-flagged this spell as self-only from an earlier
                                -- relocation. A confirmed relocation is proof otherwise.
                                local entry = BuffMeCharDB.spells[check.spellId]
                                if entry and entry.selfOnly then
                                    entry.selfOnly = nil
                                    BuffMe_Debug("Cleared incorrect self-only flag: \"" .. spellName .. "\"")
                                end
                            end
                        end
                        if not isNew then
                            BuffMe_Debug("Aura applied: \"" .. spellName .. "\" (ID " .. spellId ..
                                ") → " .. (destName or "?"))
                        end
                        -- Self-only detection: buff landed on the caster despite being aimed at
                        -- someone else (e.g. "Boon of the Bear" — a toggle that only affects self).
                        -- Mark it so the optimizer never suggests casting it on party members.
                        HandleSelfOnlyRedirect(destGUID, spellId, spellName, playerGUID)
                        lastCastAttempt = nil
                        pendingCast = nil  -- CLEU handled it; cancel the UNIT_AURA fallback
                        -- Bypass the throttle: this is confirmation of the player's own
                        -- deliberate cast, so the next suggestion must be correct
                        -- immediately, not up to REFRESH_THROTTLE seconds later.
                        BuffMe_ForceRefresh()
                        end  -- destUnit
                        end  -- isFriendlyDest
                    end
                end
            else
                if destGUID == playerGUID then
                    BuffMe_Debug("Untracked aura on player: \"" .. (spellName or "?") ..
                        "\" (ID " .. (spellId or "?") .. ") from " .. (sourceName or sourceGUID or "?"))
                end
                -- Not our cast (regardless of who it landed on): learn who grants this
                -- buff (class only) for the Effect Groups "Source: <Class>" tooltip.
                if spellName and sourceGUID then
                    local sourceUnit = GUIDToUnit(sourceGUID)
                    if sourceUnit then
                        BuffMe_LearnAuraSource(spellName, sourceUnit)
                    end
                end
            end
        elseif eventType == "SPELL_AURA_REMOVED" and auraType == "BUFF" then
            if sourceGUID == playerGUID then
                if spellName then
                    BuffMe_Debug("Aura lost: \"" .. spellName .. "\" (ID " .. (spellId or "?") ..
                        ") left " .. (destName or "?"))

                    -- Self-only detection via toggle/redirect: we tried to cast on a party
                    -- member but the player's own buff dropped instead of landing on them.
                    -- Three patterns can produce this:
                    --   (a) True toggle: the spell is self-only and re-casting removes it
                    --       from the caster (Bear/Hawk/Wolf/Turtle). No APPLIED follows.
                    --   (b) Group-spread self-cast: the spell always fires on self and then
                    --       spreads (Lion 505217). The old application drops before the new
                    --       one lands, so REMOVED fires on the player first.
                    --   (c) Global-singleton relocation (e.g. "Bless"): only one live instance
                    --       exists anywhere, so casting it on a party member legitimately
                    --       strips it from the player first, then lands on the intended
                    --       target — NOT self-only. REMOVED always fires before its paired
                    --       APPLIED within the same CLEU batch, so we can't yet tell (b) from
                    --       (c) here. Defer the verdict: stash a pending check and let the
                    --       APPLIED handler decide based on where the buff actually lands.
                    --       If no APPLIED confirms a relocation, mark self-only on a short
                    --       timer as the (a)/(b) fallback.
                    if destGUID == playerGUID
                    and lastCastAttempt
                    and lastCastAttempt.unit ~= "player"
                    and lastCastAttempt.spellName == spellName then
                        local selfKey = lastCastAttempt.spellId
                            or (BuffMeCharDB.nameToKey and BuffMeCharDB.nameToKey[spellName])
                        if selfKey then
                            local check = { spellId = selfKey, spellName = spellName }
                            pendingSelfOnlyCheck = check
                            C_Timer.After(0.2, function()
                                if pendingSelfOnlyCheck == check then
                                    pendingSelfOnlyCheck = nil
                                    if BuffMe_MarkSelfOnly(selfKey) then
                                        BuffMe_Debug("Self-only detected (toggle/redirect, no relocation seen): \"" ..
                                            spellName .. "\" — player buff dropped and stayed off")
                                    end
                                end
                            end)
                        end
                        lastCastAttempt = nil  -- consumed; prevents PrepareCast overwrite
                    end

                    pendingRemovals[destGUID] = spellName  -- paired APPLIED may follow this frame
                    ScheduleRescan()
                end
            elseif destGUID == playerGUID then
                BuffMe_Debug("Untracked aura left player: \"" .. (spellName or "?") ..
                    "\" (ID " .. (spellId or "?") .. ") from " ..
                    (sourceName or sourceGUID or "?"))
            end

        elseif eventType == "SPELL_CAST_FAILED" and sourceGUID == playerGUID then
            -- For SPELL_CAST_FAILED, the 12th CLEU arg (captured as auraType) is the
            -- failedType string — the same text that would appear in UI_ERROR_MESSAGE.
            -- Use this as a fallback for servers that don't fire UI_ERROR_MESSAGE.
            local failedType = auraType
            if failedType and IsBouncedError(failedType) then
                HandleBouncedCast("CLEU")
            elseif failedType and IsHarmTargetError(failedType) and lastCastAttempt then
                if BuffMe_MarkIneligible(lastCastAttempt.spellId, "requires hostile target") then
                    ScheduleRescan()
                end
                lastCastAttempt = nil
            end
        end
    end
end)

-- Called by the UI button's PreClick handler to prepare the next cast.
-- Sets lastCastAttempt and logs intent; returns (spellName, targetUnit) so the
-- button's SecureActionButtonTemplate can perform the actual cast via attributes,
-- bypassing the CastSpellByName restriction on Ascension's emulator.
-- Returns (nil, nil) when there is nothing to cast.
function BuffMe_PrepareCast()
    if inCombat then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Buff Me]|r Cannot buff while in combat.")
        return nil, nil
    end

    local spellId, targetUnit = BuffMe_GetNextCast()
    if not spellId or not targetUnit then
        if not BuffMeCharDB or not next(BuffMeCharDB.spells) then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff00ccff[Buff Me]|r Spell database is empty — cast your buff spells so Buff Me can learn them.")
            BuffMe_Debug("PrepareCast: spell DB empty")
        else
            local knownSpells = BuffMe_GetKnownBuffSpells()
            if #knownSpells == 0 then
                BuffMe_Debug("PrepareCast: no eligible spells on current spec (DB has " ..
                    (function() local n=0; for _ in pairs(BuffMeCharDB.spells) do n=n+1 end; return n end)() ..
                    " entries, all filtered)")
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cff00ccff[Buff Me]|r No eligible buff spells known on current spec.")
            else
                BuffMe_Debug("PrepareCast: all candidates buffed (" .. #knownSpells .. " spell(s) available)")
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Buff Me]|r All party members are buffed!")
            end
        end
        RefreshUI()
        return nil, nil
    end

    local entry = BuffMe_GetSpell(spellId)
    if not entry then return nil, nil end

    BuffMe_Debug("Casting: \"" .. entry.name .. "\" on " .. targetUnit)
    local attempt = { spellId = spellId, unit = targetUnit, spellName = entry.name }
    lastCastAttempt = attempt

    -- Some spells that require a party-member target don't return a UI_ERROR when cast
    -- on a non-party friendly "target" — the server silently rejects the target instead
    -- of failing the cast, so the client falls back to a manual targeting cursor instead
    -- of reporting an error. Left alone, that cursor stays live and fires the spell at
    -- whatever unit the player clicks next (e.g. the next party member). Detect this via
    -- a "nothing happened" timeout: if nothing has resolved lastCastAttempt a second later
    -- AND the targeting cursor is still up, mark the spell party-only so future casts never
    -- offer this target for it again.
    -- NOTE: SpellStopTargeting() cannot cancel the cursor for us — Ascension blocks it for
    -- addons entirely ("action only available to the Blizzard UI"), combat or not, so the
    -- call would be a silent no-op. Warn the player to clear it themselves (Esc / right-click)
    -- instead of pretending we handled it.
    if targetUnit == "target" then
        C_Timer.After(1, function()
            if lastCastAttempt == attempt and SpellIsTargeting() then
                BuffMe_Debug("No-op timeout: \"" .. entry.name ..
                    "\" left a targeting cursor active after casting on non-party target " ..
                    targetUnit .. " — marked party-only")
                if BuffMe_MarkPartyOnly(spellId) then
                    ScheduleRescan()
                end
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Buff Me]|r \"" .. entry.name ..
                    "\" requires a party member — press Escape or right-click to clear the " ..
                    "pending target cursor. It won't be suggested for this target again.")
                lastCastAttempt = nil
            end
        end)
    end

    return entry.name, targetUnit
end
