local panel = CreateFrame("Frame", "BuffMeOptionsPanel")
panel.name = "Buff Me"

-- Title
local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Buff Me")

local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
subtitle:SetText("Smart party buff manager")

local divider = panel:CreateTexture(nil, "ARTWORK")
divider:SetHeight(1)
divider:SetPoint("TOPLEFT",  subtitle, "BOTTOMLEFT",  0, -12)
divider:SetPoint("TOPRIGHT", panel,    "TOPRIGHT",  -16, -64)
divider:SetTexture("Interface\\Tooltips\\UI-Tooltip-Border")
divider:SetTexCoord(0, 1, 0, 0.05)

-- ── Anchor lock ──────────────────────────────────────────────────────────────

local anchorLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
anchorLabel:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -16)
anchorLabel:SetText("Button Anchor")

local anchorDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
anchorDesc:SetPoint("TOPLEFT", anchorLabel, "BOTTOMLEFT", 0, -4)
anchorDesc:SetText("Lock the button in place to prevent accidental dragging.\nWhen unlocked, hover over the button and drag the title bar.")

local anchorBtn = CreateFrame("Button", "BuffMeAnchorToggleButton", panel, "UIPanelButtonTemplate")
anchorBtn:SetSize(140, 24)
anchorBtn:SetPoint("TOPLEFT", anchorDesc, "BOTTOMLEFT", 0, -10)

local function RefreshAnchorButton()
    if BuffMeDB and BuffMeDB.anchorLocked then
        anchorBtn:SetText("Unlock Anchor")
    else
        anchorBtn:SetText("Lock Anchor")
    end
end

anchorBtn:SetScript("OnClick", function()
    if not BuffMeDB then return end
    BuffMeDB.anchorLocked = not BuffMeDB.anchorLocked
    RefreshAnchorButton()
    if BuffMe_UpdateLockIcon then BuffMe_UpdateLockIcon() end
end)

local resetBtn = CreateFrame("Button", "BuffMeResetPositionButton", panel, "UIPanelButtonTemplate")
resetBtn:SetSize(140, 24)
resetBtn:SetPoint("LEFT", anchorBtn, "RIGHT", 8, 0)
resetBtn:SetText("Reset Position")
resetBtn:SetScript("OnClick", function()
    if BuffMe_ResetPosition then BuffMe_ResetPosition() end
end)

-- ── Diagnostic mode ──────────────────────────────────────────────────────────

local diagLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
diagLabel:SetPoint("TOPLEFT", anchorBtn, "BOTTOMLEFT", 0, -24)
diagLabel:SetText("Diagnostics")

local diagDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
diagDesc:SetPoint("TOPLEFT", diagLabel, "BOTTOMLEFT", 0, -4)
diagDesc:SetText("Print debug messages to chat when spells are learned,\nauras change, or casts are rejected.")

local diagBtn = CreateFrame("Button", "BuffMeDiagToggleButton", panel, "UIPanelButtonTemplate")
diagBtn:SetSize(140, 24)
diagBtn:SetPoint("TOPLEFT", diagDesc, "BOTTOMLEFT", 0, -10)

local function RefreshDiagButton()
    if BuffMeDB and BuffMeDB.diagnosticMode then
        diagBtn:SetText("Disable Diagnostics")
    else
        diagBtn:SetText("Enable Diagnostics")
    end
end

diagBtn:SetScript("OnClick", function()
    if not BuffMeDB then return end
    BuffMeDB.diagnosticMode = not BuffMeDB.diagnosticMode
    RefreshDiagButton()
    if BuffMeDB.diagnosticMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Buff Me]|r Diagnostic mode enabled.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Buff Me]|r Diagnostic mode disabled.")
    end
end)

local clearLogBtn = CreateFrame("Button", "BuffMeClearLogButton", panel, "UIPanelButtonTemplate")
clearLogBtn:SetSize(140, 24)
clearLogBtn:SetPoint("LEFT", diagBtn, "RIGHT", 8, 0)
clearLogBtn:SetText("Clear Log")
clearLogBtn:SetScript("OnClick", function()
    if not BuffMeDB then return end
    BuffMeDB.diagnosticLog = {}
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Buff Me]|r Diagnostic log cleared.")
    RefreshLogLabel()
end)

local logLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
logLabel:SetPoint("TOPLEFT", diagBtn, "BOTTOMLEFT", 0, -8)
logLabel:SetText("")

function RefreshLogLabel()
    if BuffMeDB and BuffMeDB.diagnosticLog then
        logLabel:SetText(#BuffMeDB.diagnosticLog .. " entries in log (written to disk on /reload)")
    end
end

-- ── Spell database ───────────────────────────────────────────────────────────

local dbLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
dbLabel:SetPoint("TOPLEFT", logLabel, "BOTTOMLEFT", 0, -20)
dbLabel:SetText("Spell Database")

local dbDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
dbDesc:SetPoint("TOPLEFT", dbLabel, "BOTTOMLEFT", 0, -4)
dbDesc:SetText("Clears all learned spells and exclusivity groups.\nUse if proc-sourced spells were incorrectly registered.")

local resetDBBtn = CreateFrame("Button", "BuffMeResetDBButton", panel, "UIPanelButtonTemplate")
resetDBBtn:SetSize(160, 24)
resetDBBtn:SetPoint("TOPLEFT", dbDesc, "BOTTOMLEFT", 0, -10)
resetDBBtn:SetText("Reset Spell Database")
resetDBBtn:SetScript("OnClick", function()
    if not BuffMeDB then return end
    BuffMe_ResetSpellDB()
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff00ccff[Buff Me]|r Spell database reset. " ..
        "Spells will be re-learned as you cast them.")
end)

-- Refresh button labels each time the panel is opened
local function RefreshPanel()
    RefreshAnchorButton()
    RefreshDiagButton()
    RefreshLogLabel()
end

panel:SetScript("OnShow", RefreshPanel)

InterfaceOptions_AddCategory(panel)
