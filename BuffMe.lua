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
frame:RegisterEvent("UNIT_SPELLCAST_SENT")

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

-- Static set of CLEU event types relevant to cast/aura activity; used by the diagnostic dump.
local CAST_AURA_EVENTS = {
    SPELL_CAST_START        = true, SPELL_CAST_SUCCESS      = true,
    SPELL_CAST_FAILED       = true, SPELL_AURA_APPLIED      = true,
    SPELL_AURA_REMOVED      = true, SPELL_AURA_REFRESH      = true,
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
            BuffMe_Debug("Blocking aura found: \"" .. blockingBuff .. "\" → merging typeGroups")
            BuffMe_MergeTypeGroups(ourSpellName, blockingBuff)
            for sid, entry in pairs(BuffMeDB.spells) do
                if entry.auraName == blockingBuff then
                    BuffMe_Debug("Linking targetGroup: " .. tostring(ourKey) .. " + " .. tostring(sid))
                    BuffMe_LinkTargetGroup(ourKey, sid)
                    break
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
                -- Record last-cast preference (UNIT_AURA fallback is always player→player).
                local normalAura = BuffMe_NormalizeName(auraName)
                local tg = BuffMeDB.auraToTypeGroup[normalAura]
                if tg then BuffMe_RecordLastCast(tg, UnitName("player"), sid) end
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
        local a1, a2 = ...
        -- WotLK fires (message); some builds fire (errorType, message). Handle both.
        local msg = (type(a2) == "string" and a2 ~= "" and a2)
                 or (type(a1) == "string" and a1 ~= "" and a1)
                 or nil
        -- Log every error so unrecognised server strings are visible in diagnostic mode.
        BuffMe_Debug("UI_ERROR [" .. tostring(a1) ..
            (a2 ~= nil and (", " .. tostring(a2)) or "") .. "]: " .. (msg or "(no string)") ..
            (lastCastAttempt and (" [after \"" .. (lastCastAttempt.spellName or "?") .. "\"]") or ""))
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
                    local dbKey = BuffMeDB and BuffMeDB.nameToKey and BuffMeDB.nameToKey[spellName]
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

            -- Retroactive cooldown check: spells registered before the cooldown filter
            -- existed won't have ineligible set. Now that the spell was just cast, its
            -- cooldown is active — check it and mark ineligible if warranted.
            local existingKey = (spellId and BuffMeDB and BuffMeDB.spells[spellId] and spellId)
                or (BuffMeDB and BuffMeDB.nameToKey and BuffMeDB.nameToKey[spellName])
            if existingKey then
                local existing = BuffMeDB.spells[existingKey]
                if existing and not existing.ineligible then
                    local cdKey = type(existingKey) == "number" and existingKey or spellName
                    local _, cdDuration = GetSpellCooldown(cdKey)
                    if cdDuration and cdDuration > 1.5 then
                        existing.ineligible = true
                        BuffMe_Debug("Retroactive cooldown (" .. cdDuration ..
                            "s) — marked ineligible: \"" .. spellName .. "\"")
                        ScheduleRescan()
                    end
                end
            end

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
                        -- Record last-cast preference for this typeGroup/target pair.
                        -- This is the authoritative confirmation the buff actually landed.
                        if destName then
                            local normalAura = BuffMe_NormalizeName(spellName)
                            local tg = BuffMeDB.auraToTypeGroup[normalAura]
                            if tg then BuffMe_RecordLastCast(tg, destName, spellId) end
                        end
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
