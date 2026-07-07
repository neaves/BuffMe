local ADDON_NAME = "BuffMe"

function BuffMe_Debug(msg)
    if BuffMeDB and BuffMeDB.diagnosticMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888[BuffMe]|r " .. tostring(msg))
        local log = BuffMeDB.diagnosticLog
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

local function RefreshUI()
    if BuffMe_UpdateBadge  then BuffMe_UpdateBadge()  end
    if BuffMe_RefreshPanel then BuffMe_RefreshPanel() end
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

-- Detect "more powerful spell" error strings (localization may vary on private servers)
local ERROR_PATTERNS = {
    "more powerful",
    "already active",
    "cannot be cast",
}

-- Static set of CLEU event types relevant to cast/aura activity; used by the diagnostic dump.
local CAST_AURA_EVENTS = {
    SPELL_CAST_START        = true, SPELL_CAST_SUCCESS      = true,
    SPELL_CAST_FAILED       = true, SPELL_AURA_APPLIED      = true,
    SPELL_AURA_REMOVED      = true, SPELL_AURA_REFRESH      = true,
    SPELL_AURA_APPLIED_DOSE = true, SPELL_AURA_REMOVED_DOSE = true,
    SPELL_DISPEL            = true, SPELL_SUMMON            = true,
}

local function IsBouncedError(msg)
    if not msg then return false end
    local lower = msg:lower()
    for _, pat in ipairs(ERROR_PATTERNS) do
        if lower:find(pat) then return true end
    end
    return false
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            BuffMe_InitDB()
            if BuffMe_UpdateLockIcon then BuffMe_UpdateLockIcon() end
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff00ccff[Buff Me]|r loaded. " ..
                "The spell database grows as you buff your party."
            )
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        SnapshotPlayerBuffs()
        ScheduleRescan()

    elseif event == "PARTY_MEMBERS_CHANGED" then
        BuffMe_Debug("Party changed (" .. GetNumPartyMembers() .. " member(s))")
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
                    sid = "__" .. pending.name
                end
                BuffMe_RegisterSpell(sid, pending.name, auraName)
                local idStr = type(sid) == "number" and ("ID " .. sid) or ("key \"" .. sid .. "\"")
                if auraName ~= pending.name then
                    BuffMe_Debug("Registered via UNIT_AURA fallback: spell \"" .. pending.name ..
                        "\" → aura \"" .. auraName .. "\" (" .. idStr .. ")")
                else
                    BuffMe_Debug("Registered via UNIT_AURA fallback: \"" .. pending.name ..
                        "\" (" .. idStr .. ")")
                end
            elseif #gained > 1 then
                BuffMe_Debug("Ambiguous registration after \"" .. pending.name .. "\": " ..
                    #gained .. " new buffs — try casting when no other buffs are applied")
            else
                -- On Ascension, UNIT_AURA fires before CLEU, so SPELL_AURA_REFRESH
                -- hasn't had a chance to clear pendingCast yet for known-spell refreshes.
                -- Suppress the miss warning if the spell is already in the DB.
                local known = (pending.spellId and BuffMeDB.spells[pending.spellId])
                    or BuffMeDB.spells["__" .. pending.name]
                    or BuffMeDB.nameToKey[pending.name]
                if not known then
                    for _, e in pairs(BuffMeDB.spells) do
                        if e.name == pending.name then known = true; break end
                    end
                end
                if not known then
                    BuffMe_Debug("No new buff appeared after casting \"" .. pending.name ..
                        "\" — not registered")
                end
            end
        end

        -- TypeGroup learning for CLEU-less buff swaps (e.g. Grove Instinct replaced by Primal
        -- Instinct — no CLEU REMOVED fires, but diff captures both sides of the swap).
        -- Only act on unambiguous 1-for-1 swaps to avoid false merges.
        if unit == "player" and #gained == 1 and #lost == 1 then
            local g, l = gained[1], lost[1]
            if g ~= l then
                BuffMe_Debug("Buff swap (diff): \"" .. l .. "\" → \"" .. g .. "\" — merging typeGroups")
                BuffMe_MergeTypeGroups(l, g)
            end
        end

        ScheduleRescan()

    elseif event == "SPELLS_CHANGED" then
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
        local msg = ...
        if lastCastAttempt and IsBouncedError(msg) then
            local targetUnit   = lastCastAttempt.unit
            local ourSpellName = lastCastAttempt.spellName
            BuffMe_Debug("Cast rejected: \"" .. (ourSpellName or "?") .. "\" — " .. (msg or "unknown error"))
            if targetUnit and ourSpellName and UnitExists(targetUnit) then
                local blockingBuff = BuffMe_FindBlockingBuff(targetUnit, ourSpellName)
                if blockingBuff then
                    BuffMe_Debug("Blocking aura found: \"" .. blockingBuff .. "\" → merging typeGroups")
                    BuffMe_MergeTypeGroups(ourSpellName, blockingBuff)

                    for sid, entry in pairs(BuffMeDB.spells) do
                        if entry.auraName == blockingBuff then
                            BuffMe_Debug("Linking targetGroup: spell " .. lastCastAttempt.spellId .. " + spell " .. sid)
                            BuffMe_LinkTargetGroup(lastCastAttempt.spellId, sid)
                            break
                        end
                    end
                else
                    BuffMe_Debug("No blocking aura identified on " .. targetUnit)
                end
            end
            lastCastAttempt = nil
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
            -- Queue a buff-scan registration for spells that don't appear in CLEU.
            -- nameToKey covers spells registered via CLEU under a numeric key (the common
            -- case where UNIT_SPELLCAST_SUCCEEDED carries no spellId but CLEU fires later).
            local alreadyKnown = (spellId and BuffMeDB and BuffMeDB.spells[spellId])
                or (BuffMeDB and (BuffMeDB.spells["__" .. spellName]
                                  or BuffMeDB.nameToKey[spellName]))
            if not alreadyKnown then
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
        if BuffMeDB and BuffMeDB.diagnosticMode
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
                    local isNew = not BuffMeDB.spells[spellId]
                    if isNew and recentlyCastName ~= spellName then
                        -- No matching UNIT_SPELLCAST_SUCCEEDED this frame → likely a passive
                        -- proc or reactive ability rather than something the player can cast.
                        -- Log it in diagnostic mode but do not add it to the spell DB.
                        BuffMe_Debug("Skipped registration (proc?): \"" .. spellName ..
                            "\" (ID " .. spellId .. ") — no active cast for this spell this frame")
                    else
                        BuffMe_RegisterSpell(spellId, spellName, spellName)
                        -- TypeGroup learning: if a buff was removed on this target just before
                        -- this APPLIED (CLEU REMOVED fires before APPLIED within the same
                        -- server tick), they are mutually exclusive → merge typeGroups.
                        if pendingRemovals[destGUID] then
                            local removedName = pendingRemovals[destGUID]
                            pendingRemovals[destGUID] = nil
                            if removedName ~= spellName then
                                BuffMe_Debug("Buff replacement (CLEU): \"" .. removedName ..
                                    "\" → \"" .. spellName .. "\" — merging typeGroups")
                                BuffMe_MergeTypeGroups(removedName, spellName)
                            end
                        end
                        if not isNew then
                            BuffMe_Debug("Aura applied: \"" .. spellName .. "\" (ID " .. spellId ..
                                ") → " .. (destName or "?"))
                        end
                        lastCastAttempt = nil
                        pendingCast = nil  -- CLEU handled it; cancel the UNIT_AURA fallback
                        ScheduleRescan()
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
                    pendingRemovals[destGUID] = spellName  -- paired APPLIED may follow this frame
                    ScheduleRescan()
                end
            elseif destGUID == playerGUID then
                BuffMe_Debug("Untracked aura left player: \"" .. (spellName or "?") ..
                    "\" (ID " .. (spellId or "?") .. ") from " ..
                    (sourceName or sourceGUID or "?"))
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
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Buff Me]|r All party members are buffed!")
        RefreshUI()
        return nil, nil
    end

    local entry = BuffMe_GetSpell(spellId)
    if not entry then return nil, nil end

    BuffMe_Debug("Casting: \"" .. entry.name .. "\" on " .. targetUnit)
    lastCastAttempt = { spellId = spellId, unit = targetUnit, spellName = entry.name }
    return entry.name, targetUnit
end
