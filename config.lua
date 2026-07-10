local panel = CreateFrame("Frame", "BuffMeOptionsPanel")
panel.name = "Buff Me"

-- ── Scrollable content area ───────────────────────────────────────────────────
-- The InterfaceOptions panel is ~546px tall; our content exceeds that, so we
-- wrap everything in a scroll frame.

local optScroll = CreateFrame("ScrollFrame", "BuffMeOptionsScroll", panel, "UIPanelScrollFrameTemplate")
optScroll:SetPoint("TOPLEFT",     panel, "TOPLEFT",     10,  -6)
optScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28,  8)

local optContent = CreateFrame("Frame", "BuffMeOptionsContent", optScroll)
optContent:SetWidth(380)
optContent:SetHeight(420)
optScroll:SetScrollChild(optContent)

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Invisible 1px frame used as a top-of-content anchor for the first SectionHeader.
local _contentTop = CreateFrame("Frame", nil, optContent)
_contentTop:SetPoint("TOPLEFT", optContent, "TOPLEFT", 0, 0)
_contentTop:SetSize(1, 1)

local function SectionHeader(anchorTo, label, desc)
    local hdr = optContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    hdr:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -20)
    hdr:SetTextColor(1, 0.82, 0)
    hdr:SetText(label)

    if not desc then return hdr end

    local descFS = optContent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    descFS:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -4)
    descFS:SetWidth(360)
    descFS:SetJustifyH("LEFT")
    descFS:SetText(desc)
    return descFS
end

local function Checkbox(name, anchorTo, yOffset, labelText, tipText, parent)
    local cb = CreateFrame("CheckButton", name, parent or optContent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOffset)

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

local function ButtonTip(btn, text)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(text, nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- ── PAGE TITLE ────────────────────────────────────────────────────────────────

local pageTitle = optContent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
pageTitle:SetPoint("TOPLEFT", _contentTop, "BOTTOMLEFT", 0, -16)
pageTitle:SetTextColor(1, 0.82, 0)
pageTitle:SetText("General")

local pageTitleDesc = optContent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
pageTitleDesc:SetPoint("TOPLEFT", pageTitle, "BOTTOMLEFT", 0, -6)
pageTitleDesc:SetWidth(360)
pageTitleDesc:SetJustifyH("LEFT")
pageTitleDesc:SetText("Configure the Buff Me! button, icons, and appearance. Spell learning and diagnostics are managed per character.")

-- ── ICONS ─────────────────────────────────────────────────────────────────────

local genLine = SectionHeader(pageTitleDesc, "Icons",
    "Choose which icons appear alongside the button to preview the next action.")

local showTargetCB = Checkbox("BuffMeShowTargetCB", genLine, -14, "Show Target Icon",
    "Display a portrait of the party member about to receive the next buff.\nMouse over the icon to see the unit tooltip.")

local showSpellCB = Checkbox("BuffMeShowSpellCB", showTargetCB, -14, "Show Spell Icon",
    "Display the icon for the spell about to be cast.\nMouse over the icon to see the spell tooltip.\nRight-click the icon to ignore that spell.")

-- ── BUTTON ────────────────────────────────────────────────────────────────────

local btnLine = SectionHeader(showSpellCB, "Button",
    "Controls the button's position, scale, tooltip, and idle behaviour.")

-- Anchor controls
local anchorBtn = CreateFrame("Button", "BuffMeAnchorToggleButton", optContent, "UIPanelButtonTemplate")
anchorBtn:SetSize(140, 24)
anchorBtn:SetPoint("TOPLEFT", btnLine, "BOTTOMLEFT", 0, 0)
ButtonTip(anchorBtn, "Lock the button in place to prevent accidental dragging.\nWhen unlocked, hover the button and drag the title bar.")

local resetBtn = CreateFrame("Button", "BuffMeResetPositionButton", optContent, "UIPanelButtonTemplate")
resetBtn:SetSize(140, 24)
resetBtn:SetPoint("LEFT", anchorBtn, "RIGHT", 8, 0)
resetBtn:SetText("Reset Position")
resetBtn:SetScript("OnClick", function()
    if BuffMe_ResetPosition then BuffMe_ResetPosition() end
end)
ButtonTip(resetBtn, "Return the button to its default position on screen.")

-- Create Macro
local createMacroBtn = CreateFrame("Button", "BuffMeCreateMacroButton", optContent, "UIPanelButtonTemplate")
createMacroBtn:SetSize(140, 24)
createMacroBtn:SetPoint("TOPLEFT", anchorBtn, "BOTTOMLEFT", 0, -8)
createMacroBtn:SetText("Create Macro")
ButtonTip(createMacroBtn,
    "Create a general macro called \"Buff Me\" in your macro book.\n" ..
    "Drag it to your action bar to cast buffs from there.\n" ..
    "Clicking it is identical to clicking the Buff Me! button.")
createMacroBtn:SetScript("OnClick", function()
    local MACRO_NAME = "Buff Me"
    local MACRO_ICON = 1  -- numeric icon index required by this client build
    local MACRO_BODY = "/click BuffMeButton"

    local idx = GetMacroIndexByName(MACRO_NAME)
    if idx and idx > 0 then
        EditMacro(idx, MACRO_NAME, MACRO_ICON, MACRO_BODY, nil)
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Buff Me]|r Macro updated.")
    else
        local numGeneral = GetNumMacros()
        if numGeneral >= 18 then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffff4444[Buff Me]|r Cannot create macro: general macro slots are full (18/18).")
            return
        end
        CreateMacro(MACRO_NAME, MACRO_ICON, MACRO_BODY, nil)
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccff[Buff Me]|r Macro created! Open your macro book (Shift-click a bag slot or type /macro) " ..
            "and drag \"Buff Me\" to your action bar.")
    end
end)

-- Register with Clique (side-by-side with Create Macro)
local cliqueBtn = CreateFrame("Button", "BuffMeCliqueRegisterButton", optContent, "UIPanelButtonTemplate")
cliqueBtn:SetSize(140, 24)
cliqueBtn:SetPoint("LEFT", createMacroBtn, "RIGHT", 8, 0)
cliqueBtn:SetText("Register w/ Clique")
ButtonTip(cliqueBtn,
    "Add a Clique binding: Alt+click any unit frame to cast the best\n" ..
    "available buff on that unit.\n" ..
    "Requires the Clique addon to be loaded. You can change or\n" ..
    "remove the binding in Clique's settings (/clique).")
cliqueBtn:SetScript("OnClick", function()
    if not Clique then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffff4444[Buff Me]|r Clique is not loaded. Install and enable the Clique addon first.")
        return
    end
    -- Check for an existing BuffMeHoverButton binding to avoid duplicates
    if Clique.bindings then
        for _, binding in ipairs(Clique.bindings) do
            if binding.type == "macro" and binding.macrotext
               and binding.macrotext:find("BuffMeHoverButton", 1, true) then
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cff00ccff[Buff Me]|r Clique binding already registered.\n" ..
                    "Edit or remove it in Clique's settings (/clique).")
                return
            end
        end
    end
    local ok = Clique:AddBinding({
        key       = "ALT-BUTTON1",
        type      = "macro",
        macrotext = "/click BuffMeHoverButton",
        sets      = { default = true },
    })
    if ok then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccff[Buff Me]|r Clique binding registered!\n" ..
            "Alt+click any unit frame to cast the best available buff on that unit.\n" ..
            "Change the key in Clique settings (/clique).")
    else
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffff4444[Buff Me]|r Could not register Clique binding. " ..
            "Try again out of combat.")
    end
end)

-- Scale
local scaleLabel = optContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
scaleLabel:SetPoint("TOPLEFT", createMacroBtn, "BOTTOMLEFT", 0, -14)
scaleLabel:SetText("Button Scale")

local scaleSlider = CreateFrame("Slider", "BuffMeScaleSlider", optContent, "OptionsSliderTemplate")
scaleSlider:SetWidth(200)
scaleSlider:SetMinMaxValues(50, 200)
scaleSlider:SetValueStep(5)
scaleSlider:SetPoint("TOPLEFT", scaleLabel, "BOTTOMLEFT", 8, -8)
_G["BuffMeScaleSliderLow"]:SetText("50%")
_G["BuffMeScaleSliderHigh"]:SetText("200%")
_G["BuffMeScaleSliderText"]:SetText("")

local scaleValueText = optContent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
scaleValueText:SetPoint("LEFT", scaleSlider, "RIGHT", 10, 0)

scaleSlider:SetScript("OnValueChanged", function(self, value)
    value = math.floor(value / 5 + 0.5) * 5
    scaleValueText:SetText(value .. "%")
    if BuffMeDB then
        BuffMeDB.uiScale = value / 100
        if BuffMe_ApplyScale then BuffMe_ApplyScale(BuffMeDB.uiScale) end
    end
end)

-- Show Tooltip
local showTooltipCB = Checkbox("BuffMeShowTooltipCB", scaleSlider, -12,
    "Show button tooltip",
    "Show a tooltip when hovering the button with the next spell, target, and queue count.")

showTooltipCB:SetScript("OnClick", function(self)
    if not BuffMeDB then return end
    BuffMeDB.showTooltip = self:GetChecked() and true or false
end)

-- Grey when idle
local greyWhenIdleCB = Checkbox("BuffMeGreyWhenIdleCB", showTooltipCB, -6,
    "Grey out when nothing to do",
    "Disable and grey out the button when all party members are fully buffed.\nIn combat the button is always greyed out regardless of this setting.")

greyWhenIdleCB:SetScript("OnClick", function(self)
    if not BuffMeDB then return end
    BuffMeDB.greyWhenIdle = self:GetChecked() and true or false
    if BuffMe_ApplyIdleState then BuffMe_ApplyIdleState() end
end)

-- Idle Opacity
local opacityLabel = optContent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
opacityLabel:SetPoint("TOPLEFT", greyWhenIdleCB, "BOTTOMLEFT", 0, -16)
opacityLabel:SetText("Idle Opacity")

local opacitySlider = CreateFrame("Slider", "BuffMeOpacitySlider", optContent, "OptionsSliderTemplate")
opacitySlider:SetWidth(200)
opacitySlider:SetMinMaxValues(0, 100)
opacitySlider:SetValueStep(5)
opacitySlider:SetPoint("TOPLEFT", opacityLabel, "BOTTOMLEFT", 8, -8)
_G["BuffMeOpacitySliderLow"]:SetText("0%")
_G["BuffMeOpacitySliderHigh"]:SetText("100%")
_G["BuffMeOpacitySliderText"]:SetText("")

local opacityValueText = optContent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
opacityValueText:SetPoint("LEFT", opacitySlider, "RIGHT", 10, 0)

opacitySlider:SetScript("OnValueChanged", function(self, value)
    value = math.floor(value / 5 + 0.5) * 5
    opacityValueText:SetText(value .. "%")
    if BuffMeDB then
        BuffMeDB.idleOpacity = value / 100
        if BuffMe_ApplyIdleState then BuffMe_ApplyIdleState() end
    end
end)

-- ── Refresh helpers ───────────────────────────────────────────────────────────

local function RefreshAnchorButton()
    if BuffMeDB and BuffMeDB.anchorLocked then
        anchorBtn:SetText("Unlock Anchor")
    else
        anchorBtn:SetText("Lock Anchor")
    end
end

local function RefreshCheckboxes()
    showTargetCB:SetChecked(not BuffMeDB or BuffMeDB.showTargetIcon ~= false)
    showSpellCB:SetChecked( not BuffMeDB or BuffMeDB.showSpellIcon  ~= false)
    showTooltipCB:SetChecked(not BuffMeDB or BuffMeDB.showTooltip ~= false)
    greyWhenIdleCB:SetChecked(BuffMeDB and BuffMeDB.greyWhenIdle or false)
end

-- ── Checkbox click handlers ───────────────────────────────────────────────────

showTargetCB:SetScript("OnClick", function(self)
    if not BuffMeDB then return end
    BuffMeDB.showTargetIcon = self:GetChecked() and true or false
    if BuffMe_UpdateContainerLayout then BuffMe_UpdateContainerLayout() end
    if BuffMe_UpdatePreviewIcons    then BuffMe_UpdatePreviewIcons()    end
end)

showSpellCB:SetScript("OnClick", function(self)
    if not BuffMeDB then return end
    BuffMeDB.showSpellIcon = self:GetChecked() and true or false
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

-- ── OnShow ────────────────────────────────────────────────────────────────────

panel:SetScript("OnShow", function()
    RefreshCheckboxes()
    RefreshAnchorButton()
    scaleSlider:SetValue(math.floor((BuffMeDB and BuffMeDB.uiScale or 1.0) * 100 + 0.5))
    opacitySlider:SetValue(math.floor((BuffMeDB and BuffMeDB.idleOpacity or 1.0) * 100 + 0.5))
end)

InterfaceOptions_AddCategory(panel)

-- ── Shared scroll-row pool helper ─────────────────────────────────────────────
-- Creates Frame-based rows on demand and reuses them across refreshes.
-- Each row is a fixed-height frame parented to `content` with a text label.
local function MakeRowPool(content, rowHeight)
    local pool = {}
    return function(i)
        if not pool[i] then
            local f = CreateFrame("Frame", nil, content)
            f:SetHeight(rowHeight)
            f.text = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            f.text:SetPoint("LEFT", 2, 0)
            f.text:SetPoint("RIGHT", 0, 0)
            f.text:SetJustifyH("LEFT")
            pool[i] = f
        end
        return pool[i]
    end, pool
end

-- ── SPELL GROUPS sub-panel ─────────────────────────────────────────────────────

local groupsPanel = CreateFrame("Frame", "BuffMeGroupsPanel")
groupsPanel.name   = "Spell Groups"
groupsPanel.parent = "Buff Me"

local gpTitle = groupsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
gpTitle:SetPoint("TOPLEFT", 16, -16)
gpTitle:SetText("Spell Groups")

local gpDesc = groupsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
gpDesc:SetPoint("TOPLEFT", gpTitle, "BOTTOMLEFT", 0, -6)
gpDesc:SetText("Spells are organized into mutual-exclusivity groups. If any spell in a group is already active, all others in the group are skipped.")
gpDesc:SetWidth(400)
gpDesc:SetJustifyH("LEFT")

local gpCompactCB = Checkbox("BuffMeGroupsCompactCB", gpDesc, -6, "Compact view",
    "Hide groups that contain only a single spell.", groupsPanel)

local gpScroll = CreateFrame("ScrollFrame", "BuffMeGroupsScroll", groupsPanel, "UIPanelScrollFrameTemplate")
gpScroll:SetPoint("TOPLEFT", gpCompactCB, "BOTTOMLEFT", 2, -10)
gpScroll:SetPoint("BOTTOMRIGHT", groupsPanel, "BOTTOMRIGHT", -28, 8)

local gpContent = CreateFrame("Frame", "BuffMeGroupsContent", gpScroll)
gpContent:SetWidth(390)
gpContent:SetHeight(1)
gpScroll:SetScrollChild(gpContent)

local GetGpRow, gpRowPool = MakeRowPool(gpContent, 16)

local function RefreshGroupsPanel()
    if not BuffMeCharDB or not BuffMeCharDB.typeGroupMembers then return end

    -- Collect each unique typeGroup and the spells that belong to it
    local groups = {}
    for tg in pairs(BuffMeCharDB.typeGroupMembers) do
        local spells = {}
        for _, entry in pairs(BuffMeCharDB.spells) do
            local normalAura = BuffMe_NormalizeName(entry.auraName)
            if BuffMeCharDB.auraToTypeGroup[normalAura] == tg then
                table.insert(spells, entry)
            end
        end
        if #spells > 0 then
            table.sort(spells, function(a, b) return a.name < b.name end)
            table.insert(groups, { tg = tg, spells = spells })
        end
    end
    table.sort(groups, function(a, b) return a.tg < b.tg end)

    local rowIdx   = 0
    local y        = 0
    local compact  = BuffMeDB and BuffMeDB.compactSpellGroups
    local skipped  = 0

    for _, grp in ipairs(groups) do
        local memberCount = #grp.spells
        if compact and memberCount == 1 then
            skipped = skipped + 1
            -- fall through: do not emit rows for this group
        else
        -- Group header row
        rowIdx = rowIdx + 1
        local row = GetGpRow(rowIdx)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetWidth(390)
        row:Show()
        row.text:SetText(grp.tg .. "  (" .. memberCount .. " spell" .. (memberCount ~= 1 and "s" or "") .. ")")
        row.text:SetTextColor(1, 0.82, 0)
        y = y + 17

        -- One row per spell in this group
        for _, sp in ipairs(grp.spells) do
            -- Fetch rank from the API (e.g. "Rank 2"); nil or "" means unranked
            local rankStr
            if type(sp.spellId) == "number" then
                local _, r = GetSpellInfo(sp.spellId)
                if r and r ~= "" then rankStr = r end
            end

            local flags = {}
            if sp.selfOnly   then table.insert(flags, "self-only")  end
            if sp.isTracking then table.insert(flags, "tracking")   end
            if sp.ineligible then table.insert(flags, "ignored")    end
            local suffix = #flags > 0 and ("  [" .. table.concat(flags, ", ") .. "]") or ""

            local displayName = rankStr and (sp.name .. "  (" .. rankStr .. ")") or sp.name

            rowIdx = rowIdx + 1
            row = GetGpRow(rowIdx)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 16, -y)
            row:SetWidth(374)
            row:Show()
            row.text:SetText(displayName .. suffix)
            if sp.ineligible then
                row.text:SetTextColor(0.45, 0.45, 0.45)
            else
                row.text:SetTextColor(0.9, 0.9, 0.9)
            end
            y = y + 14
        end
        y = y + 5  -- gap between groups
        end  -- compact else
    end

    if skipped > 0 then
        rowIdx = rowIdx + 1
        local row = GetGpRow(rowIdx)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetWidth(390)
        row:Show()
        row.text:SetText(skipped .. " group" .. (skipped ~= 1 and "s" or "") .. " hidden")
        row.text:SetTextColor(0.5, 0.5, 0.5)
        y = y + 14
    end

    -- Hide rows beyond what we used this pass
    for i = rowIdx + 1, #gpRowPool do
        gpRowPool[i]:Hide()
    end

    gpContent:SetHeight(math.max(y, 1))
end

gpCompactCB:SetScript("OnClick", function(self)
    if not BuffMeDB then return end
    BuffMeDB.compactSpellGroups = self:GetChecked() and true or false
    RefreshGroupsPanel()
end)

groupsPanel:SetScript("OnShow", function()
    gpCompactCB:SetChecked(BuffMeDB and BuffMeDB.compactSpellGroups or false)
    RefreshGroupsPanel()
end)
-- ── IGNORED SPELLS sub-panel ───────────────────────────────────────────────────

local ignorePanel = CreateFrame("Frame", "BuffMeIgnorePanel")
ignorePanel.name   = "Ignored Spells"
ignorePanel.parent = "Buff Me"

local ipTitle = ignorePanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
ipTitle:SetPoint("TOPLEFT", 16, -16)
ipTitle:SetText("Ignored Spells")

local ipDesc = ignorePanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
ipDesc:SetPoint("TOPLEFT", ipTitle, "BOTTOMLEFT", 0, -6)
ipDesc:SetText("Ignored spells are never suggested. Cast a spell at least once so it is learned, then enter its name below to exclude it permanently.")
ipDesc:SetWidth(400)
ipDesc:SetJustifyH("LEFT")

-- Input bar pinned to the bottom of the panel
local ipInputLabel = ignorePanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
ipInputLabel:SetPoint("BOTTOMLEFT", ignorePanel, "BOTTOMLEFT", 16, 44)
ipInputLabel:SetText("Spell name:")

local ipInput = CreateFrame("EditBox", "BuffMeIgnoreInput", ignorePanel, "InputBoxTemplate")
ipInput:SetSize(216, 20)
ipInput:SetPoint("LEFT", ipInputLabel, "RIGHT", 8, 0)
ipInput:SetAutoFocus(false)
ipInput:SetMaxLetters(80)

local ipApplyBtn = CreateFrame("Button", "BuffMeIgnoreApply", ignorePanel, "UIPanelButtonTemplate")
ipApplyBtn:SetSize(80, 22)
ipApplyBtn:SetPoint("LEFT", ipInput, "RIGHT", 6, 0)
ipApplyBtn:SetText("Ignore")

local ipFeedback = ignorePanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
ipFeedback:SetPoint("TOPLEFT", ipInputLabel, "TOPLEFT", 0, -22)
ipFeedback:SetWidth(380)
ipFeedback:SetJustifyH("LEFT")
ipFeedback:SetTextColor(1, 0.4, 0.4)
ipFeedback:SetText("")

-- Scrollable list of ignored spells (above the input bar)
local ipScroll = CreateFrame("ScrollFrame", "BuffMeIgnoreScroll", ignorePanel, "UIPanelScrollFrameTemplate")
ipScroll:SetPoint("TOPLEFT", ipDesc, "BOTTOMLEFT", 0, -10)
ipScroll:SetPoint("BOTTOMRIGHT", ignorePanel, "BOTTOMRIGHT", -28, 72)

local ipContent = CreateFrame("Frame", "BuffMeIgnoreContent", ipScroll)
ipContent:SetWidth(390)
ipContent:SetHeight(1)
ipScroll:SetScrollChild(ipContent)

-- Ignored rows also carry an Unignore button
local ipRowPool = {}
local function GetIpRow(i)
    if not ipRowPool[i] then
        local f = CreateFrame("Frame", nil, ipContent)
        f:SetHeight(22)
        f.text = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        f.text:SetPoint("LEFT", 2, 0)
        f.text:SetWidth(286)
        f.text:SetJustifyH("LEFT")
        f.unignoreBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        f.unignoreBtn:SetSize(90, 20)
        f.unignoreBtn:SetPoint("RIGHT", f, "RIGHT", 0, 0)
        f.unignoreBtn:SetText("Unignore")
        ipRowPool[i] = f
    end
    return ipRowPool[i]
end

local function RefreshIgnorePanel()
    if not BuffMeCharDB or not BuffMeCharDB.spells then return end

    local ignored = {}
    for key, entry in pairs(BuffMeCharDB.spells) do
        if entry.ineligible then
            table.insert(ignored, { key = key, entry = entry })
        end
    end
    table.sort(ignored, function(a, b) return a.entry.name < b.entry.name end)

    local y = 0
    for i, item in ipairs(ignored) do
        local row = GetIpRow(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetWidth(390)
        row:Show()
        row.text:SetText(item.entry.name)
        row.text:SetTextColor(0.9, 0.9, 0.9)
        -- Capture key for the closure
        local entryRef = item.entry
        row.unignoreBtn:SetScript("OnClick", function()
            entryRef.ineligible = nil
            if BuffMe_ForceRefresh then BuffMe_ForceRefresh() end
            ipFeedback:SetText("")
            RefreshIgnorePanel()
        end)
        y = y + 22
    end

    for i = #ignored + 1, #ipRowPool do
        ipRowPool[i]:Hide()
    end

    if #ignored == 0 then
        ipContent:SetHeight(1)
    else
        ipContent:SetHeight(math.max(y, 1))
    end
end

local function ApplyIgnore()
    local name = ipInput:GetText():match("^%s*(.-)%s*$")
    if name == "" then return end
    if not BuffMeCharDB or not BuffMeCharDB.nameToKey then return end

    local key = BuffMeCharDB.nameToKey[name]
    local entry = key and BuffMeCharDB.spells[key]
    if entry then
        entry.ineligible = true
        ipInput:SetText("")
        ipFeedback:SetText("")
        if BuffMe_ForceRefresh then BuffMe_ForceRefresh() end
        RefreshIgnorePanel()
    else
        ipFeedback:SetText("\"" .. name .. "\" not found — cast it first so Buff Me can learn it.")
    end
end

ipApplyBtn:SetScript("OnClick", ApplyIgnore)
ipInput:SetScript("OnEnterPressed", ApplyIgnore)
ipInput:SetScript("OnTextChanged", function() ipFeedback:SetText("") end)

ignorePanel:SetScript("OnShow", function()
    ipFeedback:SetText("")
    RefreshIgnorePanel()
end)
-- ── DIAGNOSTICS sub-panel ────────────────────────────────────────────────────

local diagPanel = CreateFrame("Frame", "BuffMeDiagnosticsPanel")
diagPanel.name   = "Diagnostics"
diagPanel.parent = "Buff Me"

local dpTitle = diagPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
dpTitle:SetPoint("TOPLEFT", 16, -16)
dpTitle:SetText("Diagnostics")

local dpDesc = diagPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
dpDesc:SetPoint("TOPLEFT", dpTitle, "BOTTOMLEFT", 0, -6)
dpDesc:SetWidth(400)
dpDesc:SetJustifyH("LEFT")
dpDesc:SetText("Tools for diagnosing spell learning and buff detection problems. Changes take effect immediately and are saved per character.")

local diagLabel = diagPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
diagLabel:SetPoint("TOPLEFT", dpDesc, "BOTTOMLEFT", 0, -16)
diagLabel:SetText("Debug Output")

local diagDesc = diagPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
diagDesc:SetPoint("TOPLEFT", diagLabel, "BOTTOMLEFT", 0, -4)
diagDesc:SetWidth(360)
diagDesc:SetJustifyH("LEFT")
diagDesc:SetText("Print debug messages to chat when spells are learned,\nauras change, or casts are rejected.")

local diagBtn = CreateFrame("Button", "BuffMeDiagToggleButton", diagPanel, "UIPanelButtonTemplate")
diagBtn:SetSize(140, 24)
diagBtn:SetPoint("TOPLEFT", diagDesc, "BOTTOMLEFT", 0, -10)

local clearLogBtn = CreateFrame("Button", "BuffMeClearLogButton", diagPanel, "UIPanelButtonTemplate")
clearLogBtn:SetSize(140, 24)
clearLogBtn:SetPoint("LEFT", diagBtn, "RIGHT", 8, 0)
clearLogBtn:SetText("Clear Log")

local logLabel = diagPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
logLabel:SetPoint("TOPLEFT", diagBtn, "BOTTOMLEFT", 0, -8)
logLabel:SetText("")

local dbLabel = diagPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
dbLabel:SetPoint("TOPLEFT", logLabel, "BOTTOMLEFT", 0, -24)
dbLabel:SetText("Spell Database")

local dbDesc = diagPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
dbDesc:SetPoint("TOPLEFT", dbLabel, "BOTTOMLEFT", 0, -4)
dbDesc:SetWidth(360)
dbDesc:SetJustifyH("LEFT")
dbDesc:SetText("Clears all learned spells and exclusivity groups.\nUse if proc-sourced spells were incorrectly registered.")

local resetDBBtn = CreateFrame("Button", "BuffMeResetDBButton", diagPanel, "UIPanelButtonTemplate")
resetDBBtn:SetSize(160, 24)
resetDBBtn:SetPoint("TOPLEFT", dbDesc, "BOTTOMLEFT", 0, -10)
resetDBBtn:SetText("Reset Spell Database")
resetDBBtn:SetScript("OnClick", function()
    if not BuffMeCharDB then return end
    BuffMe_ResetSpellDB()
    if BuffMe_ForceRefresh then BuffMe_ForceRefresh() end
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff00ccff[Buff Me]|r Spell database reset. " ..
        "Spells will be re-learned as you cast them.")
end)

local function RefreshDiagButton()
    if BuffMeCharDB and BuffMeCharDB.diagnosticMode then
        diagBtn:SetText("Disable Diagnostics")
    else
        diagBtn:SetText("Enable Diagnostics")
    end
end

local function RefreshLogLabel()
    if BuffMeCharDB and BuffMeCharDB.diagnosticLog then
        logLabel:SetText(#BuffMeCharDB.diagnosticLog .. " entries in log (written to disk on /reload)")
    end
end

clearLogBtn:SetScript("OnClick", function()
    if not BuffMeCharDB then return end
    BuffMeCharDB.diagnosticLog = {}
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Buff Me]|r Diagnostic log cleared.")
    RefreshLogLabel()
end)

diagBtn:SetScript("OnClick", function()
    if not BuffMeCharDB then return end
    BuffMeCharDB.diagnosticMode = not BuffMeCharDB.diagnosticMode
    RefreshDiagButton()
    if BuffMeCharDB.diagnosticMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Buff Me]|r Diagnostic mode enabled.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Buff Me]|r Diagnostic mode disabled.")
    end
end)

diagPanel:SetScript("OnShow", function()
    RefreshDiagButton()
    RefreshLogLabel()
end)
-- ── EFFECT GROUPS sub-panel ───────────────────────────────────────────────────
-- Shows every tooltip-signature group with all known spell/aura variants and their values.
-- Groups are keyed by normalized tooltip sig; members are sorted strongest first.
-- This lets you see which external buffs (e.g. "Whispers of Y'shaarj") the optimizer
-- recognizes as sharing an effect with one of your spells (e.g. "Grove Instinct").

local egPanel = CreateFrame("Frame", "BuffMeEffectGroupsPanel")
egPanel.name   = "Effect Groups"
egPanel.parent = "Buff Me"

local egTitle = egPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
egTitle:SetPoint("TOPLEFT", 16, -16)
egTitle:SetText("Effect Groups")

local egDesc = egPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
egDesc:SetPoint("TOPLEFT", egTitle, "BOTTOMLEFT", 0, -6)
egDesc:SetText("Effect families identified by tooltip pattern matching. Each group shows all spells and external auras that share the same effect, from any source. The number is the strongest value seen in each tooltip.")
egDesc:SetWidth(400)
egDesc:SetJustifyH("LEFT")

local egCompactCB = Checkbox("BuffMeEffectGroupsCompactCB", egDesc, -6, "Compact view",
    "Hide effect groups that contain only a single member.", egPanel)

local egScroll = CreateFrame("ScrollFrame", "BuffMeEffectGroupsScroll", egPanel, "UIPanelScrollFrameTemplate")
egScroll:SetPoint("TOPLEFT", egCompactCB, "BOTTOMLEFT", 2, -10)
egScroll:SetPoint("BOTTOMRIGHT", egPanel, "BOTTOMRIGHT", -28, 8)

local egContent = CreateFrame("Frame", "BuffMeEffectGroupsContent", egScroll)
egContent:SetWidth(390)
egContent:SetHeight(1)
egScroll:SetScrollChild(egContent)

local GetEgRow, egRowPool = MakeRowPool(egContent, 16)

local function RefreshEffectGroupsPanel()
    if not BuffMeCharDB or not BuffMeCharDB.effectGroups then return end

    -- Build set of castable aura names for colour distinction
    local castableAuras = {}
    if BuffMeCharDB.spells then
        for _, entry in pairs(BuffMeCharDB.spells) do
            castableAuras[BuffMe_NormalizeName(entry.auraName)] = true
        end
    end

    -- Collect all effect groups and sort by typeGroup then sig
    local groups = {}
    for sig, egEntry in pairs(BuffMeCharDB.effectGroups) do
        if next(egEntry.members) then
            table.insert(groups, { sig = sig, tg = egEntry.typeGroup, members = egEntry.members })
        end
    end
    table.sort(groups, function(a, b)
        if a.tg ~= b.tg then return a.tg < b.tg end
        return a.sig < b.sig
    end)

    local rowIdx  = 0
    local y       = 0
    local compact = BuffMeDB and BuffMeDB.compactEffectGroups
    local skipped = 0

    for _, grp in ipairs(groups) do
        -- Build human-readable label from the first component of the sig
        -- Sig lines are joined with "|"; take the first, capitalize it
        local label = grp.sig:match("^([^|]+)") or grp.sig
        label = label:sub(1,1):upper() .. label:sub(2)
        if #label > 60 then label = label:sub(1, 57) .. "..." end

        -- Count members
        local memberCount = 0
        for _ in pairs(grp.members) do memberCount = memberCount + 1 end

        if compact and memberCount == 1 then
            skipped = skipped + 1
        else
        -- Group header
        rowIdx = rowIdx + 1
        local row = GetEgRow(rowIdx)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetWidth(390)
        row:Show()
        row.text:SetText(label)
        row.text:SetTextColor(1, 0.82, 0)
        y = y + 17

        -- Sort members alphabetically (value used for ordering intent but not displayed)
        local sorted = {}
        for normalName, data in pairs(grp.members) do
            table.insert(sorted, { normalName = normalName, name = data.name, value = data.value or 0 })
        end
        table.sort(sorted, function(a, b) return a.name < b.name end)

        for _, m in ipairs(sorted) do
            local isCastable = castableAuras[m.normalName]

            rowIdx = rowIdx + 1
            row = GetEgRow(rowIdx)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 16, -y)
            row:SetWidth(374)
            row:Show()
            row.text:SetText(m.name)
            if isCastable then
                row.text:SetTextColor(0.9, 0.9, 0.9)
            else
                row.text:SetTextColor(0.6, 0.8, 1)  -- light blue for external sources
            end
            y = y + 14
        end
        y = y + 5
        end  -- compact else
    end

    if skipped > 0 then
        rowIdx = rowIdx + 1
        local row = GetEgRow(rowIdx)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetWidth(390)
        row:Show()
        row.text:SetText(skipped .. " effect" .. (skipped ~= 1 and "s" or "") .. " hidden")
        row.text:SetTextColor(0.5, 0.5, 0.5)
        y = y + 14
    end

    if rowIdx == 0 then
        rowIdx = 1
        local row = GetEgRow(1)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetWidth(390)
        row:Show()
        row.text:SetText("No effect groups learned yet. Cast your buff spells and let Buff Me observe what gets blocked.")
        row.text:SetTextColor(0.6, 0.6, 0.6)
        y = y + 14
    end

    for i = rowIdx + 1, #egRowPool do
        egRowPool[i]:Hide()
    end

    egContent:SetHeight(math.max(y, 1))
end

egCompactCB:SetScript("OnClick", function(self)
    if not BuffMeDB then return end
    BuffMeDB.compactEffectGroups = self:GetChecked() and true or false
    RefreshEffectGroupsPanel()
end)

egPanel:SetScript("OnShow", function()
    egCompactCB:SetChecked(BuffMeDB and BuffMeDB.compactEffectGroups or false)
    RefreshEffectGroupsPanel()
end)
InterfaceOptions_AddCategory(ignorePanel)
InterfaceOptions_AddCategory(groupsPanel)
InterfaceOptions_AddCategory(egPanel)
InterfaceOptions_AddCategory(diagPanel)
