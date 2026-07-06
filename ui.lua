local PARTY_UNITS = { "player", "party1", "party2", "party3", "party4" }
local ROW_HEIGHT  = 18
local PANEL_WIDTH = 280

-- ── Main button ──────────────────────────────────────────────────────────────

local mainButton = CreateFrame("Button", "BuffMeButton", UIParent, "UIPanelButtonTemplate")
mainButton:SetWidth(90)
mainButton:SetHeight(30)
mainButton:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
mainButton:SetText("Buff Me!")
mainButton:SetMovable(true)
mainButton:EnableMouse(true)
mainButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mainButton:RegisterForDrag("LeftButton")

-- Badge showing count of missing buffs
local badge = mainButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
badge:SetPoint("TOPRIGHT", mainButton, "TOPRIGHT", 4, 4)
badge:SetTextColor(1, 0.2, 0.2, 1)
badge:Hide()

-- Shift-drag to reposition
mainButton:SetScript("OnDragStart", function(self)
    if IsShiftKeyDown() then self:StartMoving() end
end)
mainButton:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
end)

mainButton:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then
        BuffMe_Cast()
    elseif button == "RightButton" then
        BuffMe_TogglePanel()
    end
end)

-- ── Expanded party panel ──────────────────────────────────────────────────────

local panel = CreateFrame("Frame", "BuffMePanel", UIParent)
panel:SetWidth(PANEL_WIDTH)
panel:SetPoint("BOTTOM", mainButton, "TOP", 0, 4)
panel:Hide()
panel:SetFrameStrata("HIGH")
panel:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 6, right = 6, top = 6, bottom = 6 },
})

local panelTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panelTitle:SetPoint("TOP", panel, "TOP", 0, -10)
panelTitle:SetText("Buff Me — Party Status")

-- Pre-create one row per possible party slot (player + 4 party members)
local rows = {}
for i = 1, 5 do
    local row = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row:SetWidth(PANEL_WIDTH - 24)
    row:SetJustifyH("LEFT")
    row:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -28 - (i - 1) * ROW_HEIGHT)
    row:Hide()
    rows[i] = row
end

-- ── Public API ───────────────────────────────────────────────────────────────

function BuffMe_UpdateBadge()
    if not BuffMeDB then return end
    local count = BuffMe_CountMissingBuffs()
    if count > 0 then
        badge:SetText(tostring(count))
        badge:Show()
    else
        badge:SetText("")
        badge:Hide()
    end
end

function BuffMe_RefreshPanel()
    if not panel:IsShown() or not BuffMeDB then return end

    local providers = BuffMe_GetProviderTypeGroups()
    local rowIdx    = 0

    for _, unit in ipairs(PARTY_UNITS) do
        if UnitExists(unit) then
            rowIdx = rowIdx + 1
            local row  = rows[rowIdx]
            local name = UnitName(unit) or unit

            -- Count missing typeGroups for this unit
            local unitAuras = {}
            local i = 1
            while true do
                local buffName = UnitBuff(unit, i)
                if not buffName then break end
                local normalName = BuffMe_NormalizeName(buffName)
                local typeGroup  = BuffMeDB.auraToTypeGroup[normalName] or normalName
                unitAuras[typeGroup] = true
                i = i + 1
            end

            local missing = 0
            for tg in pairs(providers) do
                if not unitAuras[tg] then missing = missing + 1 end
            end

            local color = missing == 0 and "|cff44ff44" or "|cffff4444"
            local status = missing == 0 and "Buffed" or (missing .. " missing")
            row:SetText(color .. name .. "|r  —  " .. status)
            row:Show()
        end
    end

    -- Hide unused rows
    for i = rowIdx + 1, 5 do
        rows[i]:Hide()
    end

    -- Resize panel to content
    local height = 28 + rowIdx * ROW_HEIGHT + 12
    panel:SetHeight(math.max(60, height))
end

function BuffMe_TogglePanel()
    if panel:IsShown() then
        panel:Hide()
    else
        BuffMe_RefreshPanel()
        panel:Show()
    end
end

function BuffMe_SetCombatState(combat)
    if combat then
        mainButton:Disable()
        mainButton:SetText("In Combat")
    else
        mainButton:Enable()
        mainButton:SetText("Buff Me!")
    end
end
