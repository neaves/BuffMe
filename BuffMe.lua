local ADDON_NAME = "BuffMe"

local inCombat        = false
local lastCastAttempt = nil  -- { spellId, unit, spellName } — for error-based learning
local rescanPending   = false

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

local function RefreshUI()
    if BuffMe_UpdateBadge  then BuffMe_UpdateBadge()  end
    if BuffMe_RefreshPanel then BuffMe_RefreshPanel() end
end

-- Throttle: rescans accumulate and fire once per frame via OnUpdate
frame:SetScript("OnUpdate", function(self, elapsed)
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
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff00ccff[Buff Me]|r loaded. " ..
                "The spell database grows as you buff your party."
            )
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        ScheduleRescan()

    elseif event == "PARTY_MEMBERS_CHANGED" then
        ScheduleRescan()

    elseif event == "UNIT_AURA" then
        ScheduleRescan()

    elseif event == "SPELLS_CHANGED" then
        ScheduleRescan()

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        if BuffMe_SetCombatState then BuffMe_SetCombatState(true) end

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        if BuffMe_SetCombatState then BuffMe_SetCombatState(false) end
        ScheduleRescan()

    elseif event == "UI_ERROR_MESSAGE" then
        local msg = ...
        if lastCastAttempt and IsBouncedError(msg) then
            -- Our last cast was rejected; learn which existing buff is blocking us
            local targetUnit  = lastCastAttempt.unit
            local ourSpellName = lastCastAttempt.spellName
            if targetUnit and ourSpellName and UnitExists(targetUnit) then
                local blockingBuff = BuffMe_FindBlockingBuff(targetUnit, ourSpellName)
                if blockingBuff then
                    -- Merge typeGroups: these two auras are mutually exclusive
                    BuffMe_MergeTypeGroups(ourSpellName, blockingBuff)

                    -- If the blocking buff is also one of our spells, link targetGroups too
                    for sid, entry in pairs(BuffMeDB.spells) do
                        if entry.auraName == blockingBuff then
                            BuffMe_LinkTargetGroup(lastCastAttempt.spellId, sid)
                            break
                        end
                    end
                end
            end
            lastCastAttempt = nil
        end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, eventType, sourceGUID, sourceName, sourceFlags,
              destGUID, destName, destFlags,
              spellId, spellName, spellSchool, auraType = ...

        local playerGUID = UnitGUID("player")

        if eventType == "SPELL_AURA_APPLIED" and auraType == "BUFF" and sourceGUID == playerGUID then
            -- We successfully applied a buff — add it to our learned DB
            if spellId and spellName then
                BuffMe_RegisterSpell(spellId, spellName, spellName)
                lastCastAttempt = nil  -- clear on success
                ScheduleRescan()
            end
        end
    end
end)

-- Called by the UI button on left-click
function BuffMe_Cast()
    if inCombat then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Buff Me]|r Cannot buff while in combat.")
        return
    end

    local spellId, targetUnit = BuffMe_GetNextCast()
    if not spellId or not targetUnit then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Buff Me]|r All party members are buffed!")
        RefreshUI()
        return
    end

    local entry = BuffMe_GetSpell(spellId)
    if not entry then return end

    -- Record attempt so UI_ERROR_MESSAGE can learn from any rejection
    lastCastAttempt = { spellId = spellId, unit = targetUnit, spellName = entry.name }

    if targetUnit == "player" then
        CastSpellByName(entry.name, true)  -- true = cast on self
    else
        TargetUnit(targetUnit)
        CastSpellByName(entry.name)
    end
end
