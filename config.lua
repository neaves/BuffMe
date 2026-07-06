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

-- Refresh button labels each time the panel is opened
local function RefreshPanel()
    RefreshAnchorButton()
    RefreshDiagButton()
end

panel:SetScript("OnShow", RefreshPanel)

InterfaceOptions_AddCategory(panel)
