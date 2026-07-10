local PARTY_UNITS    = { "player", "party1", "party2", "party3", "party4" }
local ROW_HEIGHT     = 18
local PANEL_WIDTH    = 280
local FADE_TIME      = CHAT_FRAME_FADE_TIME or 0.5
local BUTTON_HEIGHT  = 30
local TITLE_HEIGHT   = 16
local ICON_STEP      = 30   -- 28px icon + 2px gap
local BTN_WIDTH      = 90
local ICON_MARGIN    = 2    -- left margin when any icon is shown

-- ── Container: encloses both title tab and button ─────────────────────────────
-- Sized to cover the full hover area so IsMouseOver() stays true while the
-- mouse travels between the button and the title tab above it.

local container = CreateFrame("Frame", "BuffMeContainer", UIParent)
container:SetWidth(BTN_WIDTH + 2 * ICON_STEP + ICON_MARGIN)  -- both icons shown by default
container:SetHeight(TITLE_HEIGHT + BUTTON_HEIGHT)  -- 46
container:SetMovable(true)
container:EnableMouse(true)
container:RegisterForDrag("LeftButton")
-- Anchor so the button portion sits at the same screen position as before
container:SetPoint("BOTTOM", UIParent, "CENTER", 0, -215)

-- ── Title tab (alpha 0; fades in on hover — mirrors StopwatchTabFrame) ────────

local titleTab = CreateFrame("Frame", "BuffMeTitleTab", container)
titleTab:SetHeight(TITLE_HEIGHT)
titleTab:SetPoint("TOPLEFT",  container, "TOPLEFT",  0, 0)
titleTab:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
titleTab:SetAlpha(0)
titleTab:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    tile = true, tileSize = 8,
})
titleTab:SetBackdropColor(0, 0, 0, 0.7)

local titleText = titleTab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
titleText:SetPoint("TOPLEFT",     titleTab, "TOPLEFT",     4,   0)
titleText:SetPoint("BOTTOMRIGHT", titleTab, "BOTTOMRIGHT", -30, 0)
titleText:SetJustifyH("LEFT")
titleText:SetText("Buff Me")
titleText:SetTextColor(1, 0.82, 0)

-- ── Title bar icon buttons ────────────────────────────────────────────────────
-- Lock/unlock toggle — right side of title bar
local lockIcon = CreateFrame("Button", "BuffMeLockIcon", titleTab)
lockIcon:SetSize(12, 12)
lockIcon:SetPoint("TOPRIGHT", titleTab, "TOPRIGHT", -16, -2)
lockIcon:SetNormalTexture("Interface\\GLUES\\CharacterSelect\\Glues-AddOn-Icons")
lockIcon:SetHighlightTexture("Interface\\GLUES\\CharacterSelect\\Glues-AddOn-Icons")
lockIcon:SetPushedTexture("Interface\\GLUES\\CharacterSelect\\Glues-AddOn-Icons")
lockIcon:GetHighlightTexture():SetAlpha(0.5)

lockIcon:SetScript("OnClick", function()
    if not BuffMeDB then return end
    BuffMeDB.anchorLocked = not BuffMeDB.anchorLocked
    BuffMe_UpdateLockIcon()
end)
lockIcon:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(BuffMeDB and BuffMeDB.anchorLocked and "Unlock Anchor" or "Lock Anchor", 1, 1, 1)
    GameTooltip:Show()
end)
lockIcon:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Config button — opens Interface > AddOns > Buff Me
local configIcon = CreateFrame("Button", "BuffMeConfigIcon", titleTab)
configIcon:SetSize(12, 12)
configIcon:SetPoint("TOPRIGHT", titleTab, "TOPRIGHT", -2, -2)
configIcon:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
configIcon:SetHighlightTexture("Interface\\Buttons\\UI-OptionsButton")
configIcon:SetPushedTexture("Interface\\Buttons\\UI-OptionsButton")
configIcon:GetHighlightTexture():SetAlpha(0.5)

configIcon:SetScript("OnClick", function()
    InterfaceOptionsFrame_OpenToCategory("Buff Me")
    InterfaceOptionsFrame_OpenToCategory("Buff Me")
end)
configIcon:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Buff Me Options", 1, 1, 1)
    GameTooltip:Show()
end)
configIcon:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ── Pending-cast preview icons ────────────────────────────────────────────────
-- Left icon: portrait of the unit about to be buffed.
-- Right icon: spell icon for the spell about to be cast.
-- Both updated by BuffMe_UpdatePreviewIcons() on each UI refresh.

local pendingSpellId  = nil
local pendingUnit     = nil
local lastLayoutState = nil   -- cached (showTarget*2 + showSpell) to skip redundant layout work

local function CreatePreviewIcon(name)
    local f = CreateFrame("Frame", name, container)
    f:SetSize(28, 28)
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = true, tileSize = 8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(0, 0, 0, 1)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    f:EnableMouse(true)
    f:Hide()

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT",     f, "TOPLEFT",     1, -1)
    tex:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1,  1)

    return f, tex
end

local targetIcon, targetPortrait = CreatePreviewIcon("BuffMeTargetIcon")
targetIcon:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 2, 1)
targetIcon:SetScript("OnEnter", function(self)
    if not pendingUnit or not UnitExists(pendingUnit) then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetUnit(pendingUnit)
    GameTooltip:Show()
end)
targetIcon:SetScript("OnLeave", function() GameTooltip:Hide() end)

local spellIcon, spellTexture = CreatePreviewIcon("BuffMeSpellIcon")
spellIcon:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 32, 1)  -- 2+28+2
spellIcon:SetScript("OnEnter", function(self)
    if not pendingSpellId then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if type(pendingSpellId) == "number" then
        GameTooltip:SetHyperlink("spell:" .. pendingSpellId)
    else
        local entry = BuffMe_GetSpell(pendingSpellId)
        if entry then GameTooltip:SetText(entry.name, 1, 1, 1) end
    end
    GameTooltip:AddLine("Right-click to ignore this spell", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
spellIcon:SetScript("OnLeave", function() GameTooltip:Hide() end)
spellIcon:SetScript("OnMouseUp", function(self, button)
    if button ~= "RightButton" or not pendingSpellId then return end
    BuffMe_MarkIneligible(pendingSpellId, "manual")
    if BuffMe_ForceRefresh then BuffMe_ForceRefresh() end
end)

-- ── Main button (inside container, bottom portion) ────────────────────────────

local mainButton = CreateFrame("Button", "BuffMeButton", container, "SecureActionButtonTemplate,UIPanelButtonTemplate")
mainButton:SetHeight(BUTTON_HEIGHT)
mainButton:SetWidth(90)
mainButton:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
mainButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mainButton:SetText("Buff Me!")

-- Badge: missing buff count (child of button so it sits at the button's corner)
local badge = mainButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
badge:SetPoint("TOPRIGHT", mainButton, "TOPRIGHT", 4, 4)
badge:SetTextColor(1, 0.2, 0.2, 1)
badge:Hide()

-- ── Hover detection (mirrors StopwatchFrame_OnUpdate) ────────────────────────

container.prevMouseIsOver = false

local function OnUpdateHover(self)
    if self.prevMouseIsOver then
        if not self:IsMouseOver() then
            UIFrameFadeOut(titleTab, FADE_TIME)
            self.prevMouseIsOver = false
        end
    else
        if self:IsMouseOver() then
            UIFrameFadeIn(titleTab, FADE_TIME)
            self.prevMouseIsOver = true
        end
    end
end

container:SetScript("OnUpdate", OnUpdateHover)

-- Reset on hide (mirrors StopwatchFrame_OnHide)
container:SetScript("OnHide", function(self)
    UIFrameFadeRemoveFrame(titleTab)
    titleTab:SetAlpha(0)
    self.prevMouseIsOver = false
end)

-- ── Drag handling ─────────────────────────────────────────────────────────────
-- Both the container (title area) and the button (button area) can initiate a
-- drag; both move the container.

-- Pause hover detection while mouse is held (mirrors StopwatchFrame_OnMouseDown/Up)
local function pauseHover()  container:SetScript("OnUpdate", nil)           end
local function resumeHover() container:SetScript("OnUpdate", OnUpdateHover) end

-- Drag: only the container (title area) initiates movement; no shift required
container:SetScript("OnDragStart", function(self)
    if BuffMeDB and BuffMeDB.anchorLocked then return end
    self:StartMoving()
end)
container:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    resumeHover()  -- mirrors StopwatchFrame_OnDragStop calling OnMouseUp
end)
container:SetScript("OnMouseDown", pauseHover)
container:SetScript("OnMouseUp",   resumeHover)

-- Button: clicks only; pause/resume hover during press, no drag.
-- HookScript (not SetScript) avoids tainting the SecureActionButtonTemplate frame.
mainButton:HookScript("OnMouseDown", function(self) pauseHover() end)
mainButton:HookScript("OnMouseUp",   function(self) resumeHover() end)

-- ── Button clicks ─────────────────────────────────────────────────────────────
-- PreClick runs before the SecureActionButtonTemplate's native handler.
-- It determines the spell and sets type/spell/unit attributes so the secure
-- template can cast without ever calling the restricted CastSpellByName API.
-- PostClick handles right-click (panel) since that has no secure action.

mainButton:SetScript("PreClick", function(self, mouseButton, down)
    if mouseButton == "RightButton" then
        self:SetAttribute("type", "")  -- suppress secure action; PostClick shows panel
        return
    end
    local spellName, targetUnit = BuffMe_PrepareCast()
    if not spellName then
        self:SetAttribute("type", "")  -- nothing to cast
        return
    end
    self:SetAttribute("type", "spell")
    self:SetAttribute("spell", spellName)
    self:SetAttribute("unit", targetUnit)
end)

mainButton:SetScript("PostClick", function(self, mouseButton)
    if mouseButton == "RightButton" then
        BuffMe_TogglePanel()
    end
end)

-- ── Expanded party panel ──────────────────────────────────────────────────────

local panel = CreateFrame("Frame", "BuffMePanel", UIParent)
panel:SetWidth(PANEL_WIDTH)
panel:SetPoint("BOTTOM", container, "TOP", 0, 4)
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
panelTitle:SetText("Buff Me - Party Status")

local rows = {}
for i = 1, 5 do
    local row = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row:SetWidth(PANEL_WIDTH - 24)
    row:SetJustifyH("LEFT")
    row:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -28 - (i - 1) * ROW_HEIGHT)
    row:Hide()
    rows[i] = row
end

-- ── Public API ────────────────────────────────────────────────────────────────

function BuffMe_UpdateBadge()
    if not BuffMeCharDB then return end
    local count = BuffMe_CountMissingBuffs()
    if count > 0 then
        badge:SetText(tostring(count))
        badge:Show()
    else
        badge:SetText("")
        badge:Hide()
    end
end

-- Reposition icons and resize the container based on showTargetIcon / showSpellIcon flags.
-- Skips work when nothing has changed (compares against lastLayoutState).
function BuffMe_UpdateContainerLayout()
    if not BuffMeDB then return end
    local showT = BuffMeDB.showTargetIcon ~= false
    local showS = BuffMeDB.showSpellIcon  ~= false
    local state = (showT and 2 or 0) + (showS and 1 or 0)
    if state == lastLayoutState then return end
    lastLayoutState = state

    local offset = ICON_MARGIN
    if showT then
        targetIcon:ClearAllPoints()
        targetIcon:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", offset, 1)
        offset = offset + ICON_STEP
    else
        targetIcon:Hide()
    end

    if showS then
        spellIcon:ClearAllPoints()
        spellIcon:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", offset, 1)
    else
        spellIcon:Hide()
    end

    local iconCount = (showT and 1 or 0) + (showS and 1 or 0)
    container:SetWidth(BTN_WIDTH + iconCount * ICON_STEP + (iconCount > 0 and ICON_MARGIN or 0))
end

function BuffMe_UpdatePreviewIcons()
    if not BuffMeDB then
        targetIcon:Hide()
        spellIcon:Hide()
        return
    end

    local showT = BuffMeDB.showTargetIcon ~= false
    local showS = BuffMeDB.showSpellIcon  ~= false

    local spellId, unit = BuffMe_GetNextCast()
    pendingSpellId = spellId
    pendingUnit    = unit

    if spellId and unit and UnitExists(unit) then
        if showT then
            SetPortraitTexture(targetPortrait, unit)
            targetIcon:Show()
        end
        if showS then
            local _, _, icon
            if type(spellId) == "number" then
                _, _, icon = GetSpellInfo(spellId)
            else
                local entry = BuffMe_GetSpell(spellId)
                if entry then _, _, icon = GetSpellInfo(entry.name) end
            end
            if icon then
                spellTexture:SetTexture(icon)
                spellTexture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                spellIcon:Show()
            end
        end
    else
        pendingSpellId = nil
        pendingUnit    = nil
        targetIcon:Hide()
        spellIcon:Hide()
    end
end

function BuffMe_RefreshPanel()
    if not panel:IsShown() or not BuffMeCharDB then return end

    local providers = BuffMe_GetProviderTypeGroups()
    local rowIdx    = 0

    for _, unit in ipairs(PARTY_UNITS) do
        if UnitExists(unit) then
            rowIdx = rowIdx + 1
            local row  = rows[rowIdx]
            local name = UnitName(unit) or unit

            local unitAuras = {}
            local i = 1
            while true do
                local buffName = UnitBuff(unit, i)
                if not buffName then break end
                local normalName = BuffMe_NormalizeName(buffName)
                local typeGroup  = BuffMeCharDB.auraToTypeGroup[normalName] or normalName
                unitAuras[typeGroup] = true
                i = i + 1
            end

            local missing = 0
            for tg in pairs(providers) do
                if not unitAuras[tg] then missing = missing + 1 end
            end

            local color  = missing == 0 and "|cff44ff44" or "|cffff4444"
            local status = missing == 0 and "Buffed" or (missing .. " missing")
            row:SetText(color .. name .. "|r  -  " .. status)
            row:Show()
        end
    end

    for i = rowIdx + 1, 5 do
        rows[i]:Hide()
    end

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

-- Sync the lock icon texcoords to the current anchorLocked state
function BuffMe_UpdateLockIcon()
    if not BuffMeDB then return end
    -- Glues-AddOn-Icons sprite: left quarter = locked, second quarter = unlocked
    local l, r = BuffMeDB.anchorLocked and 0 or 0.25,
                  BuffMeDB.anchorLocked and 0.25 or 0.5
    lockIcon:GetNormalTexture():SetTexCoord(l, r, 0, 1)
    lockIcon:GetHighlightTexture():SetTexCoord(l, r, 0, 1)
    lockIcon:GetPushedTexture():SetTexCoord(l, r, 0, 1)
end

function BuffMe_ResetPosition()
    container:ClearAllPoints()
    container:SetPoint("BOTTOM", UIParent, "CENTER", 0, -215)
end

function BuffMe_ApplyScale(scale)
    container:SetScale(scale or 1.0)
end

function BuffMe_SetCombatState(combat)
    if combat then
        mainButton:Disable()
        mainButton:SetText("In Combat")
        targetIcon:Hide()
        spellIcon:Hide()
    else
        mainButton:Enable()
        mainButton:SetText("Buff Me!")
    end
end
