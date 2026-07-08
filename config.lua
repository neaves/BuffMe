local panel = CreateFrame("Frame", "BuffMeOptionsPanel")
panel.name = "Buff Me"

-- ── Header ────────────────────────────────────────────────────────────────────

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Buff Me")

local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
subtitle:SetText("Smart party buff manager")

-- ── Section helper ────────────────────────────────────────────────────────────

local function SectionHeader(anchorTo, label)
    local hdr = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    hdr:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -20)
    hdr:SetTextColor(1, 0.82, 0)
    hdr:SetText(label)

    local line = panel:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("TOPLEFT",  hdr,   "BOTTOMLEFT",  0,    -3)
    line:SetPoint("TOPRIGHT", panel, "TOPRIGHT",   -16,    0)
    line:SetTexture("Interface\\Tooltips\\UI-Tooltip-Border")
    line:SetTexCoord(0, 1, 0, 0.05)

    return line  -- callers anchor their first child to this line
end

local function Checkbox(name, anchorTo, yOffset, labelText, tipText)
    local cb = CreateFrame("CheckButton", name, panel, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", -2, yOffset)

    local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetText(labelText)

    if tipText then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tipText, nil, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    return cb
end

-- ── GENERAL ───────────────────────────────────────────────────────────────────

local genLine = SectionHeader(subtitle, "General")

-- Show Target Icon checkbox
local showTargetCB = Checkbox("BuffMeShowTargetCB", genLine, -10, "Show Target Icon",
    "Display a portrait of the party member about to receive the next buff.\nMouse over the icon to see the unit tooltip.")

-- Show Spell Icon checkbox
local showSpellCB = Checkbox("BuffMeShowSpellCB", showTargetCB, -6, "Show Spell Icon",
    "Display the icon for the spell about to be cast.\nMouse over the icon to see the spell tooltip.")

-- Button Anchor
local anchorLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
anchorLabel:SetPoint("TOPLEFT", showSpellCB, "BOTTOMLEFT", 2, -18)
anchorLabel:SetText("Button Anchor")

local anchorDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
anchorDesc:SetPoint("TOPLEFT", anchorLabel, "BOTTOMLEFT", 0, -4)
anchorDesc:SetText("Lock the button in place to prevent accidental dragging.\nWhen unlocked, hover over the button and drag the title bar.")

local anchorBtn = CreateFrame("Button", "BuffMeAnchorToggleButton", panel, "UIPanelButtonTemplate")
anchorBtn:SetSize(140, 24)
anchorBtn:SetPoint("TOPLEFT", anchorDesc, "BOTTOMLEFT", 0, -10)

local resetBtn = CreateFrame("Button", "BuffMeResetPositionButton", panel, "UIPanelButtonTemplate")
resetBtn:SetSize(140, 24)
resetBtn:SetPoint("LEFT", anchorBtn, "RIGHT", 8, 0)
resetBtn:SetText("Reset Position")
resetBtn:SetScript("OnClick", function()
    if BuffMe_ResetPosition then BuffMe_ResetPosition() end
end)

-- ── ADVANCED ──────────────────────────────────────────────────────────────────

local advLine = SectionHeader(anchorBtn, "Advanced")

-- Diagnostics
local diagLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
diagLabel:SetPoint("TOPLEFT", advLine, "BOTTOMLEFT", 0, -14)
diagLabel:SetText("Diagnostics")

local diagDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
diagDesc:SetPoint("TOPLEFT", diagLabel, "BOTTOMLEFT", 0, -4)
diagDesc:SetText("Print debug messages to chat when spells are learned,\nauras change, or casts are rejected.")

local diagBtn = CreateFrame("Button", "BuffMeDiagToggleButton", panel, "UIPanelButtonTemplate")
diagBtn:SetSize(140, 24)
diagBtn:SetPoint("TOPLEFT", diagDesc, "BOTTOMLEFT", 0, -10)

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

-- Spell database
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

-- ── Refresh helpers ───────────────────────────────────────────────────────────

local function RefreshAnchorButton()
    if BuffMeDB and BuffMeDB.anchorLocked then
        anchorBtn:SetText("Unlock Anchor")
    else
        anchorBtn:SetText("Lock Anchor")
    end
end

local function RefreshDiagButton()
    if BuffMeDB and BuffMeDB.diagnosticMode then
        diagBtn:SetText("Disable Diagnostics")
    else
        diagBtn:SetText("Enable Diagnostics")
    end
end

function RefreshLogLabel()
    if BuffMeDB and BuffMeDB.diagnosticLog then
        logLabel:SetText(#BuffMeDB.diagnosticLog .. " entries in log (written to disk on /reload)")
    end
end

local function RefreshCheckboxes()
    showTargetCB:SetChecked(not BuffMeDB or BuffMeDB.showTargetIcon ~= false)
    showSpellCB:SetChecked( not BuffMeDB or BuffMeDB.showSpellIcon  ~= false)
end

-- ── Checkbox click handlers ───────────────────────────────────────────────────

showTargetCB:SetScript("OnClick", function(self)
    if not BuffMeDB then return end
    BuffMeDB.showTargetIcon = self:GetChecked()
    if BuffMe_UpdateContainerLayout then BuffMe_UpdateContainerLayout() end
    if BuffMe_UpdatePreviewIcons    then BuffMe_UpdatePreviewIcons()    end
end)

showSpellCB:SetScript("OnClick", function(self)
    if not BuffMeDB then return end
    BuffMeDB.showSpellIcon = self:GetChecked()
    if BuffMe_UpdateContainerLayout then BuffMe_UpdateContainerLayout() end
    if BuffMe_UpdatePreviewIcons    then BuffMe_UpdatePreviewIcons()    end
end)

-- ── Anchor button ─────────────────────────────────────────────────────────────

anchorBtn:SetScript("OnClick", function()
    if not BuffMeDB then return end
    BuffMeDB.anchorLocked = not BuffMeDB.anchorLocked
    RefreshAnchorButton()
    if BuffMe_UpdateLockIcon then BuffMe_UpdateLockIcon() end
end)

-- ── Diag button ───────────────────────────────────────────────────────────────

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

-- ── OnShow ────────────────────────────────────────────────────────────────────

panel:SetScript("OnShow", function()
    RefreshCheckboxes()
    RefreshAnchorButton()
    RefreshDiagButton()
    RefreshLogLabel()
end)

InterfaceOptions_AddCategory(panel)
