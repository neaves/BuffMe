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

-- Resolve a unit GUID to a unit token by checking player + current party + target.
local function GUIDToUnit(guid)
    if not guid then return nil end
    if UnitGUID("player") == guid then return "player" end
    for i = 1, GetNumPartyMembers() do
        local u = "party" .. i
        if UnitGUID(u) == guid then return u end
    end
    if UnitExists("target") and UnitGUID("target") == guid then return "target" end
end
local pendingCast     = nil  -- { name, spellId } — for CLEU-less spells learned via UNIT_AURA
local playerBuffCache = {}   -- [buffName] = true; tracks current player buffs for diff
local pendingRemovals    = {}   -- [destGUID] = auraName; CLEU REMOVED waiting for paired APPLIED
local recentlyCastName   = nil  -- spell name from UNIT_SPELLCAST_SUCCEEDED; cleared each frame

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

-- Throttle: rescans accumulate and fire once per frame via OnUpdate
frame:SetScript("OnUpdate", function(self, elapsed)
    if next(pendingRemovals) then wipe(pendingRemovals) end  -- clear unmatched CLEU removals
    recentlyCastName = nil  -- proc guard: reset each frame after CLEU has had a chance to fire
    if rescanPending then
        rescanPending = false
        RefreshUI()
    end
end)

local function ScheduleRescan()
    rescanPending = true
end

function BuffMe_ForceRefresh()
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
                -- Blocker is not in our DB (external/unknown buff) — register it directly
                BuffMe_RegisterAuraInTypeGroup(blockingBuff, ourTG)
                BuffMe_Debug("Registered external blocker \"" .. blockingBuff .. "\" in typeGroup \"" .. ourTG .. "\"")
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
        BuffMe_ScanPartyForEffectGroups(nil)
        ScheduleRescan()

    elseif event == "PARTY_MEMBERS_CHANGED" then
        BuffMe_Debug("Party changed (" .. GetNumPartyMembers() .. " member(s))")
        BuffMe_ScanPartyForEffectGroups(nil)
        ScheduleRescan()

    elseif event == "UNIT_AURA" then
        local unit = ...
        local gained, lost = {}, {}
        if unit == "player" then
            gained, lost = DiffPlayerBuffs()
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

        BuffMe_ScanPartyForEffectGroups(unit)
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
            if isPlayer and isFriend then
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

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        BuffMe_Debug("Left combat — button re-enabled")
        if BuffMe_SetCombatState then BuffMe_SetCombatState(false) end
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
                lastCastAttempt = nil
                pendingCast = nil  -- refresh is a valid cast outcome; suppress "no new buff" warning
                ScheduleRescan()
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
                        BuffMe_RegisterSpell(spellId, spellName, spellName)
                        -- Capture the aura's tooltip sig for effect-group matching.
                        -- We use the live unit-buff tooltip (SetUnitBuff) as the sole
                        -- source so sigs are format-identical on both sides of comparisons.
                        local destUnit = GUIDToUnit(destGUID)
                        if destUnit then
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
                        if not isNew then
                            BuffMe_Debug("Aura applied: \"" .. spellName .. "\" (ID " .. spellId ..
                                ") → " .. (destName or "?"))
                        end
                        -- Self-only detection: buff landed on the caster despite being aimed at
                        -- someone else (e.g. "Boon of the Bear" — a toggle that only affects self).
                        -- Mark it so the optimizer never suggests casting it on party members.
                        if destGUID == playerGUID
                        and lastCastAttempt
                        and lastCastAttempt.unit ~= "player"
                        and lastCastAttempt.spellName == spellName then
                            local selfKey = lastCastAttempt.spellId or spellId
                            if BuffMe_MarkSelfOnly(selfKey) then
                                BuffMe_Debug("Self-only detected: \"" .. spellName ..
                                    "\" landed on caster despite targeting " .. lastCastAttempt.unit)
                            end
                        end
                        lastCastAttempt = nil
                        pendingCast = nil  -- CLEU handled it; cancel the UNIT_AURA fallback
                        ScheduleRescan()
                        end  -- isFriendlyDest
                    end
                end
            elseif destGUID == playerGUID then
                BuffMe_Debug("Untracked aura on player: \"" .. (spellName or "?") ..
                    "\" (ID " .. (spellId or "?") .. ") from " .. (sourceName or sourceGUID or "?"))
            end
        elseif eventType == "SPELL_AURA_REMOVED" and auraType == "BUFF" then
            if sourceGUID == playerGUID then
                if spellName then
                    BuffMe_Debug("Aura lost: \"" .. spellName .. "\" (ID " .. (spellId or "?") ..
                        ") left " .. (destName or "?"))

                    -- Self-only detection via toggle/redirect: we tried to cast on a party
                    -- member but the player's own buff dropped instead of landing on them.
                    -- Two patterns both produce this:
                    --   (a) True toggle: the spell is self-only and re-casting removes it
                    --       from the caster (Bear/Hawk/Wolf/Turtle). No APPLIED follows.
                    --   (b) Group-spread self-cast: the spell always fires on self and then
                    --       spreads (Lion 505217). The old application drops before the new
                    --       one lands, so REMOVED fires on the player first.
                    -- In both cases, targeting a party member never helps — the spell only
                    -- responds to "player" as the unit. Mark it self-only so the optimizer
                    -- stops targeting party members for this typeGroup slot.
                    if destGUID == playerGUID
                    and lastCastAttempt
                    and lastCastAttempt.unit ~= "player"
                    and lastCastAttempt.spellName == spellName then
                        local selfKey = lastCastAttempt.spellId
                            or (BuffMeCharDB.nameToKey and BuffMeCharDB.nameToKey[spellName])
                        if selfKey and BuffMe_MarkSelfOnly(selfKey) then
                            BuffMe_Debug("Self-only detected (toggle/redirect): \"" ..
                                spellName .. "\" — player buff dropped when targeting " ..
                                lastCastAttempt.unit)
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
    lastCastAttempt = { spellId = spellId, unit = targetUnit, spellName = entry.name }
    return entry.name, targetUnit
end
